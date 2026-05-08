#!/usr/bin/env bash
set -euo pipefail

bioformats_path="../bioformats"
binary="zig-out/bin/bioformats-zig.exe"
strict=0

for arg in "$@"; do :; done
while (( $# > 0 )); do
  case "$1" in
    -BioformatsPath)
      bioformats_path="${2:-}"
      shift 2
      ;;
    -BioformatsPath=*)
      bioformats_path="${1#*=}"
      shift
      ;;
    -Binary)
      binary="${2:-}"
      shift 2
      ;;
    -Binary=*)
      binary="${1#*=}"
      shift
      ;;
    -Strict)
      strict=1
      shift
      ;;
    -h|--help)
      echo "Usage: audit-readers.sh [-BioformatsPath path] [-Binary path] [-Strict]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

resolve_path() {
  local input="$1"
  if [[ "$input" = /* ]] || [[ "$input" =~ ^[A-Za-z]:[\\/].* ]]; then
    echo "$input"
  else
    echo "$PWD/$input"
  fi
}

declare -A skip_readers=(
  [BaseTiff]=1
  [BaseZeiss]=1
  [BIFormat]=1
  [BufferedImage]=1
  [Delegate]=1
  [Format]=1
  [ICompressedTile]=1
  [IFormat]=1
  [Image]=1
  [ImageIO]=1
  [ImagePlus]=1
  [ImageProcessor]=1
  [LMSFile]=1
  [MinimalTiff]=1
  [MultipleImages]=1
  [SubResolutionFormat]=1
  [TiffDelegate]=1
  [TiffJAI]=1
  [Virtual]=1
  [Wrapped]=1
)

declare -A reader_id_overrides=(
  [BioRad]=biorad
  [BioRadGel]=bioradgel
  [BioRadSCN]=bioradscn
  [CanonRaw]=canonraw
  [CellH5]=cellh5
  [CellSens]=cellsens
  [CellVoyager]=cellvoyager
  [CellWorx]=cellworx
  [CV7000]=cv7000
  [DCIMG]=dcimg
  [DNG]=dng
  [Ecat7]=ecat7
  [EPS]=eps
  [FEI]=fei
  [FEITiff]=feitiff
  [FV1000]=fv1000
  [GatanDM2]=gatandm2
  [GIF]=gif
  [HamamatsuVMS]=hamamatsuvms
  [HIS]=his
  [HRDGDF]=hrdgdf
  [I2I]=i2i
  [ICS]=ics
  [IM3]=im3
  [IMOD]=imod
  [INR]=inr
  [IPLab]=iplab
  [IPW]=ipw
  [JDCE]=jdce
  [JPEG]=jpeg
  [JPEG2000]=jpeg2000
  [JPX]=jpx
  [KLB]=klb
  [L2D]=l2d
  [LEO]=leo
  [LIF]=lif
  [LIM]=lim
  [LiFlim]=liflim
  [MIAS]=mias
  [MINC]=minc
  [MNG]=mng
  [MRW]=mrw
  [NAF]=naf
  [ND2]=nd2
  [NDPI]=ndpi
  [NDPIS]=ndpis
  [NRRD]=nrrd
  [Nifti]=nifti
  [OBF]=obf
  [OIR]=oir
  [OMETiff]=ometiff
  [OMEXML]=omexml
  [OpenlabRaw]=openlabraw
  [PCORAW]=pcoraw
  [PCX]=pcx
  [PDS]=pds
  [PGM]=pgm
  [PSD]=psd
  [QT]=qt
  [RCPNL]=rcpnl
  [RHK]=rhk
  [SBIG]=sbig
  [SDT]=sdt
  [SEQ]=seq
  [SIF]=sif
  [SIS]=sis
  [SMCamera]=smcamera
  [SPC]=spc
  [SPE]=spe
  [SVS]=svs
  [TCS]=tcs
  [UBM]=ubm
  [VGSAM]=vgsam
  [WATOP]=watop
  [XLEF]=xlef
  [ZeissCZI]=zeissczi
  [ZeissLMS]=zeisslms
  [ZeissLSM]=zeisslsm
  [ZeissTIFF]=zeisstiff
  [ZeissXRM]=zeissxrm
  [ZeissZVI]=zeisszvi
)

reader_to_id() {
  local name="$1"
  if [[ -n "${reader_id_overrides[$name]+_}" ]]; then
    printf '%s\n' "${reader_id_overrides[$name]}"
  else
    printf '%s\n' "${name,,}"
  fi
}

runtime_formats() {
  local binary_path="$1"
  local fmt response line

  if [[ ! -f "$binary_path" ]]; then
    return 1
  fi

  coproc BIOFMT { "$binary_path"; }
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"formats"}' >&"${BIOFMT[1]}"
  if ! read -r -t 5 line <&"${BIOFMT[0]}"; then
    kill "${BIOFMT_PID}" 2>/dev/null || true
    wait "${BIOFMT_PID}" 2>/dev/null || true
    return 1
  fi

  if [[ -z "$line" ]]; then
    kill "${BIOFMT_PID}" 2>/dev/null || true
    wait "${BIOFMT_PID}" 2>/dev/null || true
    return 1
  fi

  if jq -e '.error' >/dev/null <<<"$line"; then
    kill "${BIOFMT_PID}" 2>/dev/null || true
    wait "${BIOFMT_PID}" 2>/dev/null || true
    return 1
  fi

  printf '%s\n' "$line" | jq -r '.result[]? | "\(.id)=\(.canReadPixels|if . then 1 else 0 end)"'
  printf '%s\n' '{"jsonrpc":"2.0","method":"shutdown"}' >&"${BIOFMT[1]}" || true
  kill "${BIOFMT_PID}" 2>/dev/null || true
  wait "${BIOFMT_PID}" 2>/dev/null || true
}

bioformats_path="$(resolve_path "$bioformats_path")"
if [[ ! -d "$bioformats_path" ]]; then
  echo "Bio-Formats checkout not found: $bioformats_path" >&2
  exit 1
fi

root_file="$PWD/src/root.zig"
declare -A zig_formats=()
while IFS=$'\t' read -r id read_pixels; do
  if [[ -z "$id" ]]; then
    continue
  fi
  case "${read_pixels,,}" in
    true) zig_formats["$id"]=1 ;;
    false) zig_formats["$id"]=0 ;;
    *) zig_formats["$id"]=1 ;;
  esac
done < <(awk '
  /^\s*\.id[[:space:]]*=/ {
    if (match($0, /"([^"]+)"/, id)) {
      current_id = id[1]
    } else {
      current_id = ""
    }
    next
  }
  /^\s*\.can_read_pixels[[:space:]]*=/ {
    if (current_id == "") {
      next
    }
    if (match($0, /=[[:space:]]*([^,[:space:]]+)/, value)) {
      printf "%s\t%s\n", current_id, value[1]
      current_id = ""
    }
    next
  }
' "$root_file")

binary_path="$(resolve_path "$binary")"
runtime_output="$(runtime_formats "$binary_path" || true)"
if [[ -n "$runtime_output" ]]; then
  mapfile -t runtime_pairs <<<"$runtime_output"
  declare -A runtime_map=()
  for entry in "${runtime_pairs[@]:-}"; do
    [[ -z "$entry" ]] && continue
    key="${entry%%=*}"
    value="${entry#*=}"
    zig_formats["$key"]="$value"
  done
  runtime_used=true
else
  runtime_used=false
fi

reader_files=()
while IFS= read -r -d '' file; do
  reader_files+=("$file")
done < <(find "$bioformats_path" -type f -name "*Reader.java" -print0)

missing=()
concrete_count=0
for file in "${reader_files[@]}"; do
  base="$(basename "$file")"
  reader="${base%Reader.java}"
  if [[ -n "${skip_readers[$reader]+_}" ]]; then
    continue
  fi
  ((concrete_count += 1))
  expected="$(reader_to_id "$reader")"
  if [[ -z "${zig_formats[$expected]+x}" ]]; then
    missing+=("${reader}|${expected}|${file}")
  fi
done

pixel_disabled=()
mapfile -t format_keys < <(printf '%s\n' "${!zig_formats[@]}" | sort)
for key in "${format_keys[@]}"; do
  [[ -z "$key" ]] && continue
  if [[ "${zig_formats[$key]}" == "0" ]]; then
    pixel_disabled+=("$key")
  fi
done

printf 'JavaReaderFiles:\t%s\n' "${#reader_files[@]}"
printf 'ConcreteJavaReaders:\t%s\n' "$concrete_count"
printf 'ZigFormats:\t%s\n' "${#zig_formats[@]}"
printf 'MissingConcreteReaders:\t%s\n' "${#missing[@]}"
printf 'PixelDisabledFormats:\t%s\n' "${#pixel_disabled[@]}"
printf 'RuntimeFormats:\t%s\n' "$runtime_used"

if (( ${#missing[@]} > 0 )); then
  echo
  echo "Missing concrete Java readers:"
  printf '%-28s %-22s %s\n' "Reader" "ExpectedId" "Path"
  mapfile -t sorted_missing < <(printf '%s\n' "${missing[@]}" | sort)
  for item in "${sorted_missing[@]}"; do
    IFS='|' read -r reader expected path <<<"$item"
    printf '%-28s %-22s %s\n' "$reader" "$expected" "$path"
  done
fi

if (( ${#pixel_disabled[@]} > 0 )); then
  echo
  echo "Zig formats still advertised as metadata-only:"
  printf '%s\n' "Format"
  for key in "${pixel_disabled[@]}"; do
    printf '%s\n' "$key"
  done
fi

if (( strict == 1 )) && (( ${#missing[@]} > 0 || ${#pixel_disabled[@]} > 0 )); then
  echo "Reader audit failed strict mode." >&2
  exit 1
fi
