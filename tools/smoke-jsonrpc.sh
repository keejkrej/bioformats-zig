#!/usr/bin/env bash
set -euo pipefail

binary="zig-out/bin/bioformats-zig.exe"

for arg in "$@"; do :; done
while (( $# > 0 )); do
  case "$1" in
    -Binary)
      binary="$2"
      shift 2
      ;;
    -Binary=*)
      binary="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: smoke-jsonrpc.sh [-Binary zig-out/bin/bioformats-zig.exe]"
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

start_process() {
  local binary_path="$1"
  if [[ ! -f "$binary_path" ]]; then
    echo "Binary not found: $binary_path. Run 'zig build' first or pass -Binary." >&2
    exit 1
  fi
  coproc BF { "$binary_path"; }
  BF_STDIN="${BF[1]}"
  BF_STDOUT="${BF[0]}"
  BF_PID="$!"
}

write_bytes() {
  printf '%s' "$1" >&"$BF_STDIN"
}

read_line() {
  local line
  if ! read -r line <&"$BF_STDOUT"; then
    return 1
  fi
  printf '%s\n' "$line"
}

line_request() {
  local id="$1"
  local method="$2"
  local params_json="${3-}"
  local request

  if [[ -n "$params_json" ]]; then
    request="$(jq -cn --arg id "$id" --arg method "$method" --argjson params "$params_json" '{jsonrpc:"2.0", id:($id|tonumber), method:$method, params:$params}')"
  else
    request="$(jq -cn --arg id "$id" --arg method "$method" '{jsonrpc:"2.0", id:($id|tonumber), method:$method}')"
  fi

  write_bytes "$request"
  write_bytes $'\n'
  read_line
}

line_message() {
  local request="$1"
  write_bytes "$request"
  write_bytes $'\n'
  read_line
}

line_has_error() {
  local response="$1"
  if jq -e '.error' >/dev/null <<<"$response"; then
    return 0
  fi
  return 1
}

read_ascii_line() {
  local fd="$1"
  local line
  if ! IFS= read -r -u "$fd" line; then
    return 1
  fi
  line="${line%$'\r'}"
  printf '%s\n' "$line"
}

read_exact_bytes() {
  local fd="$1"
  local size="$2"
  local chunk
  if ! IFS= read -r -N "$size" -u "$fd" chunk; then
    if (( ${#chunk} < size )); then
      return 1
    fi
  fi
  printf '%s' "$chunk"
}

framed_response() {
  local content_length=""
  local header
  while true; do
    header="$(read_ascii_line "$BF_STDOUT")"
    if [[ -z "$header" ]]; then
      break
    fi
    if [[ "$header" =~ ^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ll][Ee][Nn][Gg][Tt][Hh]:[[:space:]]*([0-9]+)$ ]]; then
      content_length="${BASH_REMATCH[1]}"
    fi
  done
  if [[ -z "$content_length" ]]; then
    return 1
  fi
  read_exact_bytes "$BF_STDOUT" "$content_length"
}

framed_request() {
  local id="$1"
  local method="$2"
  local params_json="${3-}"
  local body

  if [[ -n "$params_json" ]]; then
    body="$(jq -cn --arg id "$id" --arg method "$method" --argjson params "$params_json" '{jsonrpc:"2.0", id:($id|tonumber), method:$method, params:$params}')"
  else
    body="$(jq -cn --arg id "$id" --arg method "$method" '{jsonrpc:"2.0", id:($id|tonumber), method:$method}')"
  fi

  write_bytes "Content-Length: ${#body}"
  write_bytes $'\r\n\r\n'
  write_bytes "$body"
  framed_response
}

framed_raw_body() {
  local body="$1"
  write_bytes "Content-Length: ${#body}"
  write_bytes $'\r\n\r\n'
  write_bytes "$body"
  framed_response
}

stop_line() {
  if ! kill -0 "$BF_PID" 2>/dev/null; then
    return 0
  fi

  if ! line_request 99 shutdown >/dev/null; then
    kill "$BF_PID" 2>/dev/null || true
    wait "$BF_PID" 2>/dev/null || true
    return 0
  fi

  kill "$BF_PID" 2>/dev/null || true
  wait "$BF_PID" 2>/dev/null || true
}

stop_framed() {
  if ! kill -0 "$BF_PID" 2>/dev/null; then
    return 0
  fi

  if ! framed_request 99 shutdown >/dev/null; then
    kill "$BF_PID" 2>/dev/null || true
    wait "$BF_PID" 2>/dev/null || true
    return 0
  fi

  kill "$BF_PID" 2>/dev/null || true
  wait "$BF_PID" 2>/dev/null || true
}

decode_markers() {
  local data_b64="$1"
  python3 - "$data_b64" <<'PY'
import base64
import sys
payload = base64.b64decode(sys.argv[1] or '')
if len(payload) <= 30:
    print("invalid")
    raise SystemExit(1)
print(f"{payload[0]}/{payload[10]}/{payload[20]}/{payload[30]}")
PY
}

binary_path="$(resolve_path "$binary")"
fake_path="${TMPDIR:-/tmp}/bioformats-zig-smoke&sizeX=60&sizeY=1&sizeZ=2&sizeC=3&sizeT=4.fake"

# Line-delimited protocol checks
start_process "$binary_path"

line_initialize="$(line_request 1 initialize)"
if line_has_error "$line_initialize"; then
  echo "initialize failed." >&2
  stop_line
  exit 1
fi

if [[ "$(jq -r '.result.protocol' <<<"$line_initialize")" != "json-rpc-2.0-stdio" ]]; then
  echo "Unexpected initialize protocol." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.capabilities.metadata // false' <<<"$line_initialize")" != "true" ]]; then
  echo "Metadata reads were not advertised." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.capabilities.pixels // false' <<<"$line_initialize")" != "true" ]]; then
  echo "Pixel reads were not advertised." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.capabilities.contentLengthFraming // false' <<<"$line_initialize")" != "true" ]]; then
  echo "Content-Length framing was not advertised." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.capabilities.inlineData // false' <<<"$line_initialize")" != "true" ]]; then
  echo "Inline data was not advertised." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.capabilities.handles // false' <<<"$line_initialize")" != "true" ]]; then
  echo "Reader handles were not advertised." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.capabilities.regions // false' <<<"$line_initialize")" != "true" ]]; then
  echo "Region reads were not advertised." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.capabilities.zctCoordinates // false' <<<"$line_initialize")" != "true" ]]; then
  echo "Z/C/T coordinate reads were not advertised." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.capabilities.batch // false' <<<"$line_initialize")" != "true" ]]; then
  echo "Batch requests were not advertised." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.capabilities.notifications // false' <<<"$line_initialize")" != "true" ]]; then
  echo "Notifications were not advertised." >&2
  stop_line
  exit 1
fi

write_bytes $'\xEF\xBB\xBF'
write_bytes '{"jsonrpc":"2.0","id":14,"method":"initialize"}'
write_bytes $'\n'
bom_initialize="$(read_line)"
if [[ "$(jq -r '.id' <<<"$bom_initialize")" != "14" ]] || [[ "$(jq -r '.result.server' <<<"$bom_initialize")" != "bioformats-zig" ]]; then
  echo "Line-delimited UTF-8 BOM request failed." >&2
  stop_line
  exit 1
fi

formats="$(line_request 2 formats)"
if line_has_error "$formats"; then
  echo "formats request failed." >&2
  stop_line
  exit 1
fi
formats_count="$(jq -r '.result | length' <<<"$formats")"
if [[ "$formats_count" -le 0 ]]; then
  echo "formats returned no readers." >&2
  stop_line
  exit 1
fi
if ! jq -e '.result[] | select(.id=="netpbm")' <<<"$formats" >/dev/null; then
  echo "formats did not include netpbm." >&2
  stop_line
  exit 1
fi

ppm_base64="$(python3 - <<'PY'
import base64
payload = b"P6\n1 1\n255\n" + bytes([10, 20, 30])
print(base64.b64encode(payload).decode())
PY
)"

probe="$(line_request 11 probe "$(jq -cn --arg data "$ppm_base64" '{data:$data}')")"
if line_has_error "$probe" || [[ "$(jq -r '.result.matched' <<<"$probe")" != "true" ]]; then
  echo "Probe did not match inline netpbm data." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.format' <<<"$probe")" != "netpbm" ]]; then
  echo "Probe returned unexpected format." >&2
  stop_line
  exit 1
fi

metadata="$(line_request 12 metadata "$(jq -cn --arg data "$ppm_base64" '{data:$data}')")"
if line_has_error "$metadata" || [[ "$(jq -r '.result.format' <<<"$metadata")" != "netpbm" ]]; then
  echo "Metadata returned unexpected format." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.pixelType' <<<"$metadata")" != "rgb8" ]]; then
  echo "Metadata returned unexpected pixel type." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.width' <<<"$metadata")" -ne 1 || "$(jq -r '.result.height' <<<"$metadata")" -ne 1 ]]; then
  echo "Metadata returned unexpected dimensions." >&2
  stop_line
  exit 1
fi

plane="$(line_request 3 readPlane "$(jq -cn --arg data "$ppm_base64" '{data:$data}')")"
if [[ "$(jq -r '.result.metadata.format' <<<"$plane")" != "netpbm" ]]; then
  echo "Inline readPlane did not return netpbm metadata." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.metadata.width' <<<"$plane")" -ne 1 || "$(jq -r '.result.metadata.height' <<<"$plane")" -ne 1 ]]; then
  echo "Inline readPlane returned unexpected dimensions." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.data' <<<"$plane")" != "ChQe" ]]; then
  echo "Inline readPlane returned unexpected pixel payload." >&2
  stop_line
  exit 1
fi
plane_data="$(jq -r '.result.data' <<<"$plane")"

open="$(line_request 6 open "$(jq -cn --arg data "$ppm_base64" '{data:$data}')")"
if [[ "$(jq -r '.result.handle' <<<"$open")" -le 0 ]]; then
  echo "Open did not return a positive reader handle." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.metadata.format' <<<"$open")" != "netpbm" ]]; then
  echo "Open did not return netpbm metadata." >&2
  stop_line
  exit 1
fi
handle="$(jq -r '.result.handle' <<<"$open")"

handle_plane="$(line_request 7 readPlane "$(jq -nc --argjson handle "$handle" '{handle:$handle}')")"
if [[ "$(jq -r '.result.data' <<<"$handle_plane")" != "ChQe" ]]; then
  echo "Handle readPlane returned unexpected pixel payload." >&2
  stop_line
  exit 1
fi
handle_plane_data="$(jq -r '.result.data' <<<"$handle_plane")"

pgm_base64="$(python3 - <<'PY'
import base64
payload = b"P5\n2 2\n255\n" + bytes([1, 2, 3, 4])
print(base64.b64encode(payload).decode())
PY
)"
region_plane="$(line_request 9 readPlane "$(jq -cn --arg data "$pgm_base64" --argjson x 1 --argjson y 0 --argjson width 1 --argjson height 2 '{data:$data,x:$x,y:$y,width:$width,height:$height}')")"
if [[ "$(jq -r '.result.data' <<<"$region_plane")" != "AgQ=" ]]; then
  echo "Region readPlane returned unexpected cropped pixel payload." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.region.x' <<<"$region_plane")" -ne 1 || "$(jq -r '.result.region.y' <<<"$region_plane")" -ne 0 ]]; then
  echo "Region readPlane returned unexpected region origin." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.result.region.width' <<<"$region_plane")" -ne 1 || "$(jq -r '.result.region.height' <<<"$region_plane")" -ne 2 ]]; then
  echo "Region readPlane returned unexpected region size." >&2
  stop_line
  exit 1
fi
region_plane_data="$(jq -r '.result.data' <<<"$region_plane")"

: > "$fake_path"
zct_plane="$(line_request 10 readPlane "$(jq -cn --arg path "$fake_path" --argjson z 1 --argjson c 2 --argjson t 3 --argjson x 10 --argjson y 0 --argjson width 31 --argjson height 1 '{path:$path,z:$z,c:$c,t:$t,x:$x,y:$y,width:$width,height:$height}')")"
if [[ "$(jq -r '.result.metadata.format' <<<"$zct_plane")" != "fake" ]]; then
  echo "Z/C/T readPlane did not return fake metadata." >&2
  stop_line
  exit 1
fi
zct_data="$(jq -r '.result.data // empty' <<<"$zct_plane")"
zct_markers="$(decode_markers "$zct_data")"
if [[ "$zct_markers" != "23/1/2/3" ]]; then
  echo "Z/C/T readPlane returned unexpected marker pixels." >&2
  stop_line
  exit 1
fi

close="$(line_request 8 close "$(jq -nc --argjson handle "$handle" '{handle:$handle}')")"
if [[ "$(jq -r '.result' <<<"$close")" != "true" ]]; then
  echo "Close did not return true." >&2
  stop_line
  exit 1
fi

batch="$(line_message '[{"jsonrpc":"2.0","method":"formats"},{"jsonrpc":"2.0","id":4,"method":"initialize"},{"jsonrpc":"2.0","id":5,"method":"formats"}]')"
if [[ "$(jq -r 'length' <<<"$batch")" -ne 2 ]]; then
  echo "Batch response did not return both request responses." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.[] | select(.id==4).result.server' <<<"$batch")" != "bioformats-zig" ]]; then
  echo "Batch initialize response was unexpected." >&2
  stop_line
  exit 1
fi
if [[ "$(jq -r '.[] | select(.id==5).result | length' <<<"$batch")" -le 0 ]]; then
  echo "Batch formats response was unexpected." >&2
  stop_line
  exit 1
fi
batch_responses="$(jq -r 'length' <<<"$batch")"

unknown_method="$(line_message '{"jsonrpc":"2.0","id":13,"method":"notARealMethod"}')"
if [[ "$(jq -r '.id' <<<"$unknown_method")" -ne 13 || "$(jq -r '.error.code' <<<"$unknown_method")" -ne -32601 ]]; then
  echo "Unknown method did not return Method not found." >&2
  stop_line
  exit 1
fi
unknown_code="$(jq -r '.error.code' <<<"$unknown_method")"

write_bytes '{'
write_bytes $'\n'
parse_error="$(read_line)"
if [[ "$(jq -r '.id' <<<"$parse_error")" != "null" || "$(jq -r '.error.code' <<<"$parse_error")" -ne -32700 ]]; then
  echo "Malformed JSON did not return Parse error." >&2
  stop_line
  exit 1
fi
parse_code="$(jq -r '.error.code' <<<"$parse_error")"

line_server="$(jq -r '.result.server // ""' <<<"$line_initialize")"
line_stop_status="ok"
stop_line

rm -f "$fake_path"

# Content-length framing checks
start_process "$binary_path"

framed_initialize="$(framed_request 4 initialize)"
if [[ "$(jq -r '.result.server' <<<"$framed_initialize")" != "bioformats-zig" ]]; then
  echo "Unexpected framed initialize server name." >&2
  stop_framed
  exit 1
fi
if [[ "$(jq -r '.result.capabilities.contentLengthFraming // false' <<<"$framed_initialize")" != "true" ]]; then
  echo "Framed initialize did not advertise Content-Length support." >&2
  stop_framed
  rm -f "$fake_path"
  exit 1
fi
framed_plane="$(framed_request 5 readPlane "$(jq -cn --arg data "$ppm_base64" '{data:$data}')")"
if [[ "$(jq -r '.result.metadata.format' <<<"$framed_plane")" != "netpbm" ]]; then
  echo "Framed readPlane did not return netpbm metadata." >&2
  stop_framed
  rm -f "$fake_path"
  exit 1
fi
if [[ "$(jq -r '.result.data' <<<"$framed_plane")" != "ChQe" ]]; then
  echo "Framed readPlane returned unexpected pixel payload." >&2
  stop_framed
  rm -f "$fake_path"
  exit 1
fi
framed_plane_data="$(jq -r '.result.data' <<<"$framed_plane")"

framed_unknown="$(framed_request 6 notARealMethod)"
if [[ "$(jq -r '.id' <<<"$framed_unknown")" -ne 6 || "$(jq -r '.error.code' <<<"$framed_unknown")" -ne -32601 ]]; then
  echo "Framed unknown method did not return Method not found." >&2
  stop_framed
  rm -f "$fake_path"
  exit 1
fi
framed_unknown_code="$(jq -r '.error.code' <<<"$framed_unknown")"

framed_parse="$(framed_raw_body "{")"
if [[ "$(jq -r '.id' <<<"$framed_parse")" != "null" || "$(jq -r '.error.code' <<<"$framed_parse")" -ne -32700 ]]; then
  echo "Framed malformed JSON did not return Parse error." >&2
  stop_framed
  rm -f "$fake_path"
  exit 1
fi
framed_parse_code="$(jq -r '.error.code' <<<"$framed_parse")"

lowercase_payload="$(jq -cn --argjson id 7 --arg method "initialize" '{jsonrpc:"2.0", id:$id, method:$method}')"
lowercase_frame=""
write_bytes $'Content-Type: application/vscode-jsonrpc; charset=utf-8'
write_bytes $'\r\n'
write_bytes "content-length: ${#lowercase_payload}"
write_bytes $'\r\n\r\n'
write_bytes "$lowercase_payload"
lowercase_frame="$(framed_response)"
if [[ "$(jq -r '.id' <<<"$lowercase_frame")" -ne 7 || "$(jq -r '.result.server' <<<"$lowercase_frame")" != "bioformats-zig" ]]; then
  echo "Framed lowercase Content-Length request failed." >&2
  stop_framed
  rm -f "$fake_path"
  exit 1
fi
framed_server="$(jq -r '.result.server' <<<"$lowercase_frame")"

stop_framed
rm -f "$fake_path"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "line-delimited" \
  "$line_stop_status" \
  "$formats_count" \
  "$(jq -r '.result.format' <<<"$probe")" \
  "$(jq -r '.result.pixelType' <<<"$metadata")" \
  "$plane_data" \
  "$handle_plane_data" \
  "$region_plane_data" \
  "$zct_markers" \
  "$batch_responses" \
  "$unknown_code/$parse_code"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "content-length" \
  "$line_stop_status" \
  "$framed_server" \
  "$framed_plane_data" \
  "$framed_unknown_code/$framed_parse_code" \
  "$line_stop_status" \
  "$framed_server"
