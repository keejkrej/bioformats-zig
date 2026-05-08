#!/usr/bin/env bash
set -euo pipefail

cache_dir="fixtures/cache"
binary="zig-out/bin/bioformats-zig.exe"
rpc_timeout_ms=120000
skip_pixels=0

for arg in "$@"; do :; done
while (( $# > 0 )); do
  case "$1" in
    -CacheDir)
      cache_dir="$2"
      shift 2
      ;;
    -CacheDir=*)
      cache_dir="${1#*=}"
      shift
      ;;
    -Binary)
      binary="$2"
      shift 2
      ;;
    -Binary=*)
      binary="${1#*=}"
      shift
      ;;
    -RpcTimeoutMs)
      rpc_timeout_ms="$2"
      shift 2
      ;;
    -RpcTimeoutMs=*)
      rpc_timeout_ms="${1#*=}"
      shift
      ;;
    -SkipPixels)
      skip_pixels=1
      shift
      ;;
    -h|--help)
      echo "Usage: smoke.sh [-CacheDir fixtures/cache] [-Binary zig-out/bin/bioformats-zig.exe] [-RpcTimeoutMs 120000] [-SkipPixels]"
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

rpc_timeout_s="$(awk -v ms="$rpc_timeout_ms" 'BEGIN {printf "%.3f", ms/1000}')"
rpc_error=""

has_match_glob() {
  local dir="$1"
  local pattern="$2"
  shopt -s nullglob
  local files=("$dir"/$pattern)
  shopt -u nullglob
  if (( ${#files[@]} > 0 )); then
    return 0
  fi
  return 1
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

send_request() {
  local id="$1"
  local method="$2"
  local params_json="${3-}"
  local request
  if [[ -n "$params_json" ]]; then
    request="$(jq -cn --arg id "$id" --arg method "$method" --argjson params "$params_json" '{jsonrpc:"2.0", id:($id|tonumber), method:$method, params:$params}')"
  else
    request="$(jq -cn --arg id "$id" --arg method "$method" '{jsonrpc:"2.0", id:($id|tonumber), method:$method}')"
  fi
  printf '%s\n' "$request" >&"$BF_STDIN"

  local line
  if ! read -r -t "$rpc_timeout_s" line <&"$BF_STDOUT"; then
    return 1
  fi
  echo "$line"
}

invoke_rpc() {
  local id="$1"
  local method="$2"
  local params_json="${3-}"
  local line
  if ! line="$(send_request "$id" "$method" "$params_json")"; then
    rpc_error="No JSON-RPC response for method '$method'."
    return 1
  fi
  if jq -e '.error' >/dev/null <<<"$line"; then
    rpc_error="$method failed: $(jq -r '.error.message // ""' <<<"$line")"
    return 1
  fi
  rpc_error=""
  echo "$line"
}

cache_path="$(resolve_path "$cache_dir")"
if [[ ! -d "$cache_path" ]]; then
  echo "Fixture cache not found: $cache_path. Use fixtures/fetch.sh first." >&2
  exit 1
fi

start_process "$(resolve_path "$binary")"

has_vsi_in_cache=0
if find "$cache_path" -type f -name '*.vsi' | read -r _; then
  has_vsi_in_cache=1
fi

mapfile -t files < <(find "$cache_path" -type f)
if (( ${#files[@]} == 0 )); then
  echo "No cached fixture files found under $cache_path." >&2
  exit 1
fi

if ! formats_response="$(invoke_rpc 1 formats)"; then
  echo "$rpc_error" >&2
  kill "$BF_PID" 2>/dev/null || true
  exit 1
fi
formats="$(jq -r '.result[] | "\(.id)=\(.canReadPixels|if . then 1 else 0 end)"' <<<"$formats_response")"
declare -A can_read
while IFS='=' read -r id can; do
  can_read["$id"]="$can"
done <<<"$formats"

next_id=2
failures=0

printf '%s\t%s\t%s\t%s\t%s\t%s\n' "Status" "Format" "Width" "Height" "PixelRead" "Path"

for file in "${files[@]}"; do
  status="ok"
  format_found=""
  width=0
  height=0
  pixel_read=false

  # Skip known companion/secondary files.
  has_vms_sibling=0
  has_vsi_sibling=0
  has_nhdr_sibling=0
  has_ics_sibling=0
  has_columbus_sibling=0
  has_ndpis_sibling=0
  directory="$(dirname "$file")"
  if has_match_glob "$directory" "*.vms"; then has_vms_sibling=1; fi
  if has_match_glob "$directory" "*.vsi"; then has_vsi_sibling=1; fi
  if has_match_glob "$directory" "*.nhdr"; then has_nhdr_sibling=1; fi
  if has_match_glob "$directory" "*.ics"; then has_ics_sibling=1; fi
  if has_match_glob "$directory" "MeasurementIndex.ColumbusIDX.xml"; then has_columbus_sibling=1; fi
  if has_match_glob "$directory" "*.ndpis"; then has_ndpis_sibling=1; fi

  name="$(basename "$file")"
  lower="${name,,}"
  ext="${lower##*.}"
  if (( has_vms_sibling == 1 )) && [[ "$ext" == "jpg" || "$ext" == "jpeg" || "$ext" == "opt" ]]; then
    continue
  fi
  if (( has_vsi_sibling == 1 || has_vsi_in_cache == 1 )) && [[ "$ext" == "ets" ]]; then
    continue
  fi
  if (( has_nhdr_sibling == 1 )) && [[ "$ext" == "raw" ]]; then
    continue
  fi
  if (( has_ics_sibling == 1 )) && [[ "$ext" == "ids" ]]; then
    continue
  fi
  if (( has_ndpis_sibling == 1 )) && [[ "$ext" == "ndpi" ]]; then
    continue
  fi
  if (( has_columbus_sibling == 1 )) && { [[ "$ext" == "tif" || "$ext" == "tiff" ]] || [[ "$lower" == "measurementindex.columbusidx.xml" || "$lower" == "measurementindex.columbusidx.csv" ]]; }; then
    continue
  fi

  path_json="$(jq -nc --arg path "$file" '{path:$path}')"
  if ! probe="$(invoke_rpc "$next_id" probe "$path_json")"; then
    status="$rpc_error"
    failures=$((failures + 1))
    next_id=$((next_id + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "$format_found" "$width" "$height" "$pixel_read" "$file"
    continue
  fi
  next_id=$((next_id+1))
  width="$(jq -r '.result.width // 0' <<<"$probe")"
  height="$(jq -r '.result.height // 0' <<<"$probe")"
  format_found="$(jq -r '.result.format // ""' <<<"$probe")"

  if ! metadata="$(invoke_rpc "$next_id" metadata "$path_json")"; then
    status="$rpc_error"
    failures=$((failures + 1))
    next_id=$((next_id + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "$format_found" "$width" "$height" "$pixel_read" "$file"
    continue
  fi
  next_id=$((next_id+1))
  width="$(jq -r '.result.width // 0' <<<"$metadata")"
  height="$(jq -r '.result.height // 0' <<<"$metadata")"
  plane_count="$(jq -r '.result.planeCount // 0' <<<"$metadata")"
  metadata_format="$(jq -r '.result.format // ""' <<<"$metadata")"
  if (( width <= 0 || height <= 0 || plane_count <= 0 )); then
    status="Invalid metadata dimensions or plane count."
    failures=$((failures + 1))
  else
    can_read_pixels="${can_read[$metadata_format]-0}"
    if (( skip_pixels == 0 )) && [[ "$can_read_pixels" == 1 ]]; then
      region_w=$(( width < 16 ? width : 16 ))
      region_h=$(( height < 16 ? height : 16 ))
      plane_request="$(jq -nc --arg path "$file" --argjson planeIndex 0 --argjson x 0 --argjson y 0 --argjson width "$region_w" --argjson height "$region_h" '{path:$path, planeIndex:$planeIndex, x:$x, y:$y, width:$width, height:$height}')"
      if ! plane="$(invoke_rpc "$next_id" readPlane "$plane_request")"; then
        status="$rpc_error"
        failures=$((failures + 1))
        next_id=$((next_id + 1))
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "$format_found" "$width" "$height" "$pixel_read" "$file"
        continue
      fi
      next_id=$((next_id+1))
      encoding="$(jq -r '.result.encoding // ""' <<<"$plane")"
      data="$(jq -r '.result.data // ""' <<<"$plane")"
      if [[ "$encoding" != "base64" || -z "$data" ]]; then
        status="readPlane returned no base64 pixel payload."
        failures=$((failures + 1))
      else
        pixel_read=true
      fi
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "$format_found" "$width" "$height" "$pixel_read" "$file"
done

if (( failures > 0 )); then
  printf '%s\n' "$((failures)) fixture smoke check(s) failed." >&2
  exit 1
fi

printf '%s\n' '{"jsonrpc":"2.0","method":"shutdown"}' >&"$BF_STDIN"
kill "$BF_PID" 2>/dev/null || true
wait "$BF_PID" 2>/dev/null || true
