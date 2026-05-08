#!/usr/bin/env bash
set -euo pipefail

binary="zig-out/bin/bioformats-zig.exe"
no_runtime=0
list=0

for arg in "$@"; do :; done
while (( $# > 0 )); do
  case "$1" in
    -Binary)
      binary="${2:-}"
      shift 2
      ;;
    -Binary=*)
      binary="${1#*=}"
      shift
      ;;
    -NoRuntime)
      no_runtime=1
      shift
      ;;
    -List)
      list=1
      shift
      ;;
    -h|--help)
      echo "Usage: audit.sh [-Binary path] [-NoRuntime] [-List]"
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

get_status() {
  local entries=("$@")
  if (( ${#entries[@]} == 0 )); then
    echo "missing"
    return
  fi

  for entry in "${entries[@]}"; do
    if [[ "$entry" == ome_images/* || "$entry" == https://* || "$entry" == http://* || "$entry" == zenodo/* || "$entry" == figshare/* || "$entry" == openslide* || "$entry" == external/* ]]; then
      echo "public-lead"
      return
    fi
  done

  for entry in "${entries[@]}"; do
    if [[ "$entry" == generated-fixture ]]; then
      echo "generated"
      return
    fi
  done

  for entry in "${entries[@]}"; do
    if [[ "$entry" == alias-of-* ]]; then
      echo "alias"
      return
    fi
  done

  for entry in "${entries[@]}"; do
    if [[ "$entry" == needs-public-download-url ]]; then
      echo "needs-public-download-url"
      return
    fi
  done

  for entry in "${entries[@]}"; do
    if [[ "$entry" == needs-public-sample ]]; then
      echo "needs-public-sample"
      return
    fi
  done

  for entry in "${entries[@]}"; do
    if [[ "$entry" == vendor-* || "$entry" == synthetic-or-vendor-needed ]]; then
      echo "vendor-or-synthetic"
      return
    fi
  done

  for entry in "${entries[@]}"; do
    if [[ "$entry" == bioformats-docs/* ]]; then
      echo "documentation-only"
      return
    fi
  done

  echo "other"
}

runtime_formats() {
  local binary_path="$1"
  local line response
  if [[ ! -x "$binary_path" ]]; then
    return 1
  fi
  coproc BIOFORMATS { "$binary_path"; }
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"formats"}' >&"${BIOFORMATS[1]}"
  if ! read -r -t 5 line <&"${BIOFORMATS[0]}"; then
    kill "${BIOFORMATS_PID}" 2>/dev/null || true
    wait "${BIOFORMATS_PID}" 2>/dev/null || true
    return 1
  fi
  response="$line"
  if jq -e '.error' >/dev/null <<<"$response"; then
    kill "${BIOFORMATS_PID}" 2>/dev/null || true
    wait "${BIOFORMATS_PID}" 2>/dev/null || true
    return 1
  fi
  jq -r '.result[]?.id' <<<"$response"
  printf '%s\n' '{"jsonrpc":"2.0","method":"shutdown"}' >&"${BIOFORMATS[1]}" || true
  kill "${BIOFORMATS_PID}" 2>/dev/null || true
  wait "${BIOFORMATS_PID}" 2>/dev/null || true
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sources_path="$script_dir/sources.json"
if [[ ! -f "$sources_path" ]]; then
  echo "Unable to read fixtures sources: $sources_path" >&2
  exit 1
fi

rows="$(mktemp)"
trap 'rm -f "$rows"' EXIT

mapfile -t catalog_formats < <(jq -r '.implemented_format_sources | to_entries | sort_by(.key) | .[] | .key' "$sources_path")

while IFS= read -r format; do
  entries_json="$(jq -r --arg format "$format" '.implemented_format_sources[$format]' "$sources_path")"
  entries_type="$(jq -r 'type' <<<"$entries_json")"
  entries=()
  if [[ "$entries_type" == "array" ]]; then
    mapfile -t entries < <(jq -r '.[]' <<<"$entries_json")
  else
    entries=("$entries_json")
  fi
  status="$(get_status "${entries[@]:-}")"
  sources="$(printf '%s, ' "${entries[@]:-}" | sed 's/, $//')"
  printf '%s\t%s\t%s\n' "$format" "$status" "$sources" >>"$rows"
done < <(printf '%s\n' "${catalog_formats[@]}")

if (( no_runtime == 0 )); then
  binary_path="$(resolve_path "$binary")"
  if mapfile -t runtime_ids < <(runtime_formats "$binary_path"); then
    mapfile -t catalog_format_ids < <(cut -f1 "$rows")
    declare -A catalog_map=()
    for f in "${catalog_format_ids[@]}"; do
      catalog_map["$f"]=1
    done
    for id in "${runtime_ids[@]}"; do
      if [[ -n "${catalog_map[$id]+x}" ]]; then
        continue
      fi
      printf '%s\tmissing\t\n' "$id" >>"$rows"
    done
  fi
fi

if (( list == 1 )); then
  printf 'Format\tStatus\tSources\n'
  sort -t$'\t' -k2,2 -k1,1 "$rows" | while IFS=$'\t' read -r format status sources; do
    printf '%s\t%s\t%s\n' "$format" "$status" "$sources"
  done
  exit 0
fi

printf 'Status\tCount\n'
sort -t$'\t' -k2,2 "$rows" | awk -F'\t' '{count[$2]++} END {for (k in count) print k "\t" count[k]}' | sort

mapfile -t needs < <(awk -F'\t' '$2 ~ /^(needs-|missing$|vendor-or-synthetic|documentation-only|other)$/ {print $2 "\t" $1}' "$rows" | sort)
if (( ${#needs[@]} > 0 )); then
  echo
  echo "Formats needing fixture follow-up: ${#needs[@]}"
  printf '%s\t%s\n' "Status" "Format"
  for item in "${needs[@]}"; do
    IFS=$'\t' read -r status format <<<"$item"
    printf '%s\t%s\n' "$status" "$format"
  done
fi
