#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <openjpeg.h>

typedef struct {
    const uint8_t *data;
    size_t len;
    size_t pos;
} bio_j2k_stream;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t components;
    uint8_t bits_per_sample;
    uint8_t is_signed;
    uint8_t *data;
    size_t data_len;
} bio_j2k_image;

static OPJ_SIZE_T bio_j2k_read(void *buffer, OPJ_SIZE_T byte_count, void *user_data) {
    bio_j2k_stream *stream = (bio_j2k_stream *)user_data;
    size_t remaining = stream->len - stream->pos;
    size_t count = byte_count < remaining ? byte_count : remaining;
    if (count == 0) return (OPJ_SIZE_T)-1;
    memcpy(buffer, stream->data + stream->pos, count);
    stream->pos += count;
    return count;
}

static OPJ_OFF_T bio_j2k_skip(OPJ_OFF_T byte_count, void *user_data) {
    bio_j2k_stream *stream = (bio_j2k_stream *)user_data;
    if (byte_count < 0) return -1;
    size_t count = (size_t)byte_count;
    size_t remaining = stream->len - stream->pos;
    if (count > remaining) count = remaining;
    stream->pos += count;
    return (OPJ_OFF_T)count;
}

static OPJ_BOOL bio_j2k_seek(OPJ_OFF_T byte_count, void *user_data) {
    bio_j2k_stream *stream = (bio_j2k_stream *)user_data;
    if (byte_count < 0 || (uint64_t)byte_count > stream->len) return OPJ_FALSE;
    stream->pos = (size_t)byte_count;
    return OPJ_TRUE;
}

static void bio_j2k_message(const char *message, void *user_data) {
    (void)message;
    (void)user_data;
}

static uint8_t clamp_u8(int32_t value) {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return (uint8_t)value;
}

static uint16_t clamp_u16(int32_t value) {
    if (value < 0) return 0;
    if (value > 65535) return 65535;
    return (uint16_t)value;
}

static int validate_components(const opj_image_t *image) {
    if (image->numcomps == 0 || image->numcomps > 4) return 0;
    const opj_image_comp_t *first = &image->comps[0];
    if (first->w == 0 || first->h == 0 || first->prec == 0 || first->prec > 16) return 0;
    for (uint32_t c = 0; c < image->numcomps; c++) {
        const opj_image_comp_t *comp = &image->comps[c];
        if (comp->w != first->w || comp->h != first->h) return 0;
        if (comp->dx != first->dx || comp->dy != first->dy) return 0;
        if (comp->prec != first->prec || comp->sgnd != first->sgnd) return 0;
        if (comp->data == NULL) return 0;
    }
    return 1;
}

static int copy_components(const opj_image_t *image, bio_j2k_image *out) {
    const opj_image_comp_t *first = &image->comps[0];
    size_t bytes_per_sample = first->prec <= 8 ? 1 : 2;
    size_t pixels = (size_t)first->w * (size_t)first->h;
    size_t len = pixels * (size_t)image->numcomps * bytes_per_sample;
    uint8_t *data = (uint8_t *)malloc(len);
    if (data == NULL) return 0;

    for (size_t i = 0; i < pixels; i++) {
        for (uint32_t c = 0; c < image->numcomps; c++) {
            int32_t sample = image->comps[c].data[i];
            size_t dst = (i * (size_t)image->numcomps + c) * bytes_per_sample;
            if (bytes_per_sample == 1) {
                data[dst] = first->sgnd ? (uint8_t)(int8_t)sample : clamp_u8(sample);
            } else if (first->sgnd) {
                int16_t signed_sample = (int16_t)sample;
                data[dst] = (uint8_t)((uint16_t)signed_sample >> 8);
                data[dst + 1] = (uint8_t)((uint16_t)signed_sample & 0xff);
            } else {
                uint16_t unsigned_sample = clamp_u16(sample);
                data[dst] = (uint8_t)(unsigned_sample >> 8);
                data[dst + 1] = (uint8_t)(unsigned_sample & 0xff);
            }
        }
    }

    out->width = first->w;
    out->height = first->h;
    out->components = image->numcomps;
    out->bits_per_sample = (uint8_t)first->prec;
    out->is_signed = first->sgnd ? 1 : 0;
    out->data = data;
    out->data_len = len;
    return 1;
}

int bio_j2k_decode(const uint8_t *data, size_t len, bio_j2k_image *out) {
    memset(out, 0, sizeof(*out));
    if (data == NULL || len < 2) return 1;

    OPJ_CODEC_FORMAT format = OPJ_CODEC_J2K;
    if (len >= 12 && memcmp(data + 4, "jP  ", 4) == 0) {
        format = OPJ_CODEC_JP2;
    }

    bio_j2k_stream state = { data, len, 0 };
    opj_stream_t *stream = opj_stream_create(1024 * 1024, OPJ_TRUE);
    if (stream == NULL) return 2;
    opj_stream_set_user_data(stream, &state, NULL);
    opj_stream_set_user_data_length(stream, (OPJ_UINT64)len);
    opj_stream_set_read_function(stream, bio_j2k_read);
    opj_stream_set_skip_function(stream, bio_j2k_skip);
    opj_stream_set_seek_function(stream, bio_j2k_seek);

    opj_codec_t *codec = opj_create_decompress(format);
    if (codec == NULL) {
        opj_stream_destroy(stream);
        return 3;
    }
    opj_set_info_handler(codec, bio_j2k_message, NULL);
    opj_set_warning_handler(codec, bio_j2k_message, NULL);
    opj_set_error_handler(codec, bio_j2k_message, NULL);

    opj_dparameters_t params;
    opj_set_default_decoder_parameters(&params);
    if (!opj_setup_decoder(codec, &params)) {
        opj_destroy_codec(codec);
        opj_stream_destroy(stream);
        return 4;
    }

    opj_image_t *image = NULL;
    if (!opj_read_header(stream, codec, &image)) {
        opj_destroy_codec(codec);
        opj_stream_destroy(stream);
        return 5;
    }
    if (!opj_decode(codec, stream, image) || !opj_end_decompress(codec, stream)) {
        opj_image_destroy(image);
        opj_destroy_codec(codec);
        opj_stream_destroy(stream);
        return 6;
    }

    int ok = validate_components(image) && copy_components(image, out);
    opj_image_destroy(image);
    opj_destroy_codec(codec);
    opj_stream_destroy(stream);
    return ok ? 0 : 7;
}

void bio_j2k_free(void *ptr) {
    free(ptr);
}
