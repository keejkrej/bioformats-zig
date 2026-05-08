#!/usr/bin/env bash
set -euo pipefail

bioformats_dir="../bioformats"
binary="zig-out/bin/bioformats-zig.exe"

for arg in "$@"; do :; done
while (( $# > 0 )); do
  case "$1" in
    -BioformatsDir)
      bioformats_dir="$2"
      shift 2
      ;;
    -BioformatsDir=*)
      bioformats_dir="${1#*=}"
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
    -h|--help)
      echo "Usage: smoke-upstream-samples.sh [-BioformatsDir ../bioformats] [-Binary zig-out/bin/bioformats-zig.exe]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
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

bioformats_path="$(resolve_path "$bioformats_dir")"
if [[ ! -d "$bioformats_path" ]]; then
  echo "Bio-Formats checkout not found: $bioformats_path" >&2
  exit 1
fi

binary_path="$(resolve_path "$binary")"
if [[ ! -f "$binary_path" ]]; then
  echo "Binary not found: $binary_path. Run 'zig build' first or pass -Binary." >&2
  exit 1
fi

coproc BIOJSON { "$binary_path"; }
BF_IN="${BIOJSON[1]}"
BF_OUT="${BIOJSON[0]}"
rpc_error=""

invoke_rpc() {
  local id="$1"
  local method="$2"
  local params="$3"
  local request
  request="$(jq -cn --arg id "$id" --arg method "$method" --argjson params "$params" '{jsonrpc:"2.0",id:($id|tonumber),method:$method,params:$params}')"
  printf '%s\n' "$request" >&"$BF_IN"
  if ! read -r line <&"$BF_OUT"; then
    rpc_error="No JSON-RPC response for method '$method'."
    return 1
  fi
  if jq -e '.error' >/dev/null <<<"$line"; then
    rpc_error="$method failed: $(jq -r '.error.message' <<<"$line")"
    return 1
  fi
  rpc_error=""
  echo "$line"
}

cases='[
  {
    "relative": "components/formats-bsd/test/spec/schema/samples/2011-06/6x4y1z1t1c8b-swatch.ome",
    "width": 6,
    "height": 4,
    "planeCount": 1,
    "planeIndex": 0,
    "pixel": "/w=="
  },
  {
    "relative": "components/formats-bsd/test/spec/schema/samples/2011-06/6x4y1z1t3c8b-swatch-upgrade.ome",
    "width": 6,
    "height": 4,
    "planeCount": 3,
    "planeIndex": 2,
    "pixel": "AA=="
  },
  {
    "relative": "components/formats-gpl/test/loci/formats/utests/xml/2010-04.ome",
    "width": 1024,
    "height": 1024,
    "planeCount": 48,
    "planeIndex": 0,
    "pixel": "AAA="
  }
]'

next_id=1
failures=0

while IFS= read -r case_json; do
  relative="$(jq -r '.relative' <<<"$case_json")"
  expected_w="$(jq -r '.width' <<<"$case_json")"
  expected_h="$(jq -r '.height' <<<"$case_json")"
  expected_pc="$(jq -r '.planeCount' <<<"$case_json")"
  plane_index="$(jq -r '.planeIndex' <<<"$case_json")"
  expected_pixel="$(jq -r '.pixel' <<<"$case_json")"
  path="$bioformats_path/$relative"
  if [[ ! -f "$path" ]]; then
    echo "Upstream sample not found: $path" >&2
    kill "$BIOJSON_PID" 2>/dev/null || true
    exit 1
  fi

  status="ok"

  metadata_params="$(jq -nc --arg path "$path" '{path:$path}')"
  if ! metadata="$(invoke_rpc "$next_id" metadata "$metadata_params")"; then
    status="$rpc_error"
    failures=$((failures + 1))
    next_id=$((next_id + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "omexml" "$expected_w" "$expected_h" "$expected_pc" "$plane_index" "$path"
    continue
  fi
  next_id=$((next_id + 1))
  fmt="$(jq -r '.result.format' <<<"$metadata")"
  w="$(jq -r '.result.width' <<<"$metadata")"
  h="$(jq -r '.result.height' <<<"$metadata")"
  pc="$(jq -r '.result.planeCount' <<<"$metadata")"
  if [[ "$fmt" != "omexml" || "$w" -ne "$expected_w" || "$h" -ne "$expected_h" || "$pc" -ne "$expected_pc" ]]; then
    status="Unexpected metadata for $relative."
    failures=$((failures+1))
  fi

  if [[ "$status" == "ok" ]]; then
    plane_params="$(jq -nc --arg path "$path" --argjson planeIndex "$plane_index" --argjson x 0 --argjson y 0 --argjson width 1 --argjson height 1 '{path:$path, planeIndex:$planeIndex, x:$x, y:$y, width:$width, height:$height}')"
    if ! plane="$(invoke_rpc "$next_id" readPlane "$plane_params")"; then
      status="$rpc_error"
      failures=$((failures+1))
      next_id=$((next_id + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "omexml" "$expected_w" "$expected_h" "$expected_pc" "$plane_index" "$path"
      continue
    fi
    next_id=$((next_id+1))
    pixel="$(jq -r '.result.encoding' <<<"$plane" | awk '{print $1}')"
    data="$(jq -r '.result.data // ""' <<<"$plane")"
    if [[ "$pixel" != "base64" || "$data" != "$expected_pixel" ]]; then
      status="Unexpected pixel payload '$data' for $relative."
      failures=$((failures+1))
    fi
  else
    next_id=$((next_id+1))
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "omexml" "$expected_w" "$expected_h" "$expected_pc" "$plane_index" "$path"
done < <(jq -c '.[]' <<<"$cases")

printf '%s\n' '{"jsonrpc":"2.0","method":"shutdown"}' >&"$BF_IN" || true
kill "$BIOJSON_PID" 2>/dev/null || true
wait "$BIOJSON_PID" 2>/dev/null || true

if (( failures > 0 )); then
  echo "$failures upstream sample smoke check(s) failed." >&2
  exit 1
fi
