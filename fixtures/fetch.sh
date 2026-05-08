#!/usr/bin/env bash
set -euo pipefail

format=""
out_dir="fixtures/cache"
max_depth=2
max_bytes=209715200
name_pattern='\.(tif|tiff|ome\.tiff|png|gif|bmp|jpg|jpeg|jp2|jpx|am|amiramesh|grey|hx|labels|dm2|dm3|dm4|obf|c01|dib|flex|mea|res|oif|oib|pty|lut|dng|lsm|oir|vsi|ets|nd2|ndpi|ndpis|czi|lif|lof|htd|ics|ids|dv|dcimg|r3d|frm|mrc|map|nii|nrrd|nhdr|v|xv|dcm|dicom|ima|vms|ims|mng|ch5|h5|set|spc|sdt|jdce|xlef|xlif|xdce|xml)$'
list=0

for arg in "$@"; do :; done
while (( $# > 0 )); do
  case "$1" in
    -Format)
      format="$2"
      shift 2
      ;;
    -Format=*)
      format="${1#*=}"
      shift
      ;;
    -OutDir)
      out_dir="$2"
      shift 2
      ;;
    -OutDir=*)
      out_dir="${1#*=}"
      shift
      ;;
    -MaxDepth)
      max_depth="$2"
      shift 2
      ;;
    -MaxDepth=*)
      max_depth="${1#*=}"
      shift
      ;;
    -MaxBytes)
      max_bytes="$2"
      shift 2
      ;;
    -MaxBytes=*)
      max_bytes="${1#*=}"
      shift
      ;;
    -NamePattern)
      name_pattern="$2"
      shift 2
      ;;
    -NamePattern=*)
      name_pattern="${1#*=}"
      shift
      ;;
    -List)
      list=1
      shift
      ;;
    -h|--help)
      echo "Usage: fetch.sh -Format id [-OutDir dir] [-MaxDepth N] [-MaxBytes N] [-NamePattern 'regex'] [-List]"
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sources_path="$script_dir/sources.json"
sources="$(cat "$sources_path")"

if (( list == 1 )); then
  jq -r '.implemented_format_sources | to_entries | sort_by(.key)[] | "\(.key)\t\(.value|if type=="array" then join(", ") else tostring end)"' "$sources_path"
  exit 0
fi

if [[ -z "$format" ]]; then
  echo "Pass -Format <id>, or use -List to inspect available fixture sources." >&2
  exit 1
fi

entry="$(jq -r --arg format "$format" '.implemented_format_sources[$format] // empty' "$sources_path")"
if [[ -z "$entry" || "$entry" == null ]]; then
  echo "No fixture source entry exists for format '$format'." >&2
  exit 1
fi

entry_type="$(jq -r 'type' <<<"$entry")"
entries=()
if [[ "$entry_type" == "array" ]]; then
  mapfile -t entries < <(jq -r '.[]' <<<"$entry")
else
  entries=("$entry")
fi

resolve_source_url() {
  local entry_list=("$@")
  local root_path
  root_path="$(jq -r '.public_roots.ome_images' "$sources_path")"
  for e in "${entry_list[@]}"; do
    if [[ "$e" == ome_images/* ]]; then
      printf '%s\n' "${root_path%/}/$e"
      return 0
    fi
    if [[ "$e" == http://* || "$e" == https://* ]]; then
      printf '%s\n' "$e"
      return 0
    fi
  done
  return 1
}

resolve_zenodo_record() {
  local entry_list=("$@")
  for e in "${entry_list[@]}"; do
    if [[ "$e" =~ ^zenodo/10\.5281/zenodo\.([0-9]+)$ ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done
  return 1
}

url_join() {
  python3 - "$1" "$2" <<'PY'
from urllib.parse import urljoin
import sys
print(urljoin(sys.argv[1], sys.argv[2]))
PY
}

url_parent() {
  python3 - "$1" <<'PY'
from urllib.parse import urlsplit, urlunsplit
u = urlsplit(sys.argv[1])
path = u.path
if not path.endswith('/'):
    path = path.rsplit('/', 1)[0] + '/'
if path == '':
    path = '/'
print(urlunsplit((u.scheme, u.netloc, path, '', '')))
PY
}

url_leaf() {
  python3 - "$1" <<'PY'
from urllib.parse import unquote, urlsplit
u = urlsplit(sys.argv[1])
path = u.path
print(unquote(path.rsplit('/', 1)[-1]))
PY
}

get_directory_links() {
  local url="$1"
  curl -fsL --compressed "$url" -o - \
    | grep -Eio 'href="[^"]+"' \
    | sed -E 's/href="([^"]+)"/\1/'
}

get_remote_length() {
  local url="$1"
  local length
  length="$(curl -fsI --compressed "$url" | tr -d '\r' | awk 'BEGIN {IGNORECASE=1} /^Content-Length:/ { print $2; exit }' || true)"
  echo "$length"
}

preferred_pattern() {
  local format_name="$1"
  case "$format_name" in
    amira) echo '\.(am|amiramesh|grey|hx|labels)$' ;;
    cellsens) echo '\.vsi$' ;;
    cellomics) echo '\.(c01|dib)$' ;;
    columbus) echo '^MeasurementIndex\.ColumbusIDX\.xml$' ;;
    dcimg) echo '\.dcimg$' ;;
    ecat7) echo '\.v$' ;;
    flex) echo '\.(flex|mea|res)$' ;;
    fluoview) echo '\.(tif|tiff)$' ;;
    fv1000) echo '\.(oif|oib)$' ;;
    gatan) echo '\.dm[34]$' ;;
    gatandm2) echo '\.dm2$' ;;
    hamamatsuvms) echo '\.vms$' ;;
    imaristiff) echo '_IMS3\.ims$' ;;
    incell) echo '\.xdce$' ;;
    incell3000) echo '\.frm$' ;;
    jdce) echo '\.jdce$' ;;
    khoros) echo '^airport\.xv$' ;;
    lof) echo '^mono 8bit\.lof$' ;;
    metaxpress) echo '\.htd$' ;;
    micromanager) echo '^metadata\.txt$' ;;
    mrc) echo '\.(mrc|map)$' ;;
    ndpi) echo '\.ndpi$' ;;
    ndpis) echo '\.ndpis$' ;;
    nifti) echo '\.nii$' ;;
    nrrd) echo '\.(nrrd|nhdr)$' ;;
    obf) echo 'uncompressed\.obf$' ;;
    oir) echo '^1202-interval_10sec_sequence_frame\.oir$' ;;
    omexml) echo '^single-image\.ome\.xml$' ;;
    operetta) echo '^r01c02f01p01-ch1sk1fk1fl1\.tiff$' ;;
    scanr) echo '^--W00002--P00001--Z00000--T00000--nucleus-dapi\.tif$' ;;
    sdt) echo '\.sdt$' ;;
    spc) echo '\.set$' ;;
    xlef) echo '\.xlef$' ;;
    *) echo "" ;;
  esac
}

find_candidate() {
  local url="$1"
  local depth="$2"
  local preferred="$3"
  local link
  local resolved
  local leaf
  local length
  local candidate

  local has_preferred=0
  if [[ -n "$preferred" ]]; then
    has_preferred=1
  fi

  local fallback=""

  while IFS= read -r link; do
    [[ -z "$link" ]] && continue
    if [[ "$link" == "?"* || "$link" == "#"* || "$link" == "../" ]]; then
      continue
    fi

    resolved="$(url_join "$url" "$link")"
    leaf="$(url_leaf "$resolved")"

    if [[ "$resolved" == */ ]]; then
      if (( depth > 0 )); then
        if candidate="$(find_candidate "$resolved" $((depth - 1)) "$preferred")"; then
          echo "$candidate"
          return 0
        fi
      fi
      continue
    fi

    if ! [[ "$leaf" =~ $name_pattern ]]; then
      if (( has_preferred == 1 )) && [[ "$leaf" =~ $preferred ]]; then
        :
      else
        continue
      fi
    fi

    length="$(get_remote_length "$resolved" || true)"
    if [[ -n "$length" ]] && (( length > max_bytes )); then
      continue
    fi

    if (( has_preferred == 1 )); then
      if [[ "$leaf" =~ $preferred ]]; then
        echo "$resolved"
        return 0
      fi
      continue
    fi

    if [[ -z "$fallback" ]]; then
      fallback="$resolved"
    fi
  done < <(get_directory_links "$url")

  if [[ -n "$fallback" ]]; then
    echo "$fallback"
    return 0
  fi
  return 1
}

find_zenodo_candidate() {
  local record_id="$1"
  local preferred="$2"
  local record
  record="$(curl -fsSL "https://zenodo.org/api/records/$record_id")"
  local fallback=""
  local has_preferred=0
  if [[ -n "$preferred" ]]; then has_preferred=1; fi
  while IFS= read -r file_json; do
    name="$(jq -r '.key' <<<"$file_json")"
    if ! [[ "$name" =~ $name_pattern ]]; then
      if (( has_preferred == 1 )) && [[ "$name" =~ $preferred ]]; then
        :
      else
        continue
      fi
    fi
    length="$(jq -r '.size' <<<"$file_json")"
    if [[ -n "$length" ]] && (( length > max_bytes )); then
      continue
    fi
    source="$(jq -r '.links.self' <<<"$file_json")"
    if (( has_preferred == 1 )) && [[ "$name" =~ $preferred ]]; then
      printf '%s\t%s\n' "$source" "$name"
      return 0
    fi
    if (( has_preferred == 0 )) && [[ -z "$fallback" ]]; then
      fallback="$source\t$name"
    fi
  done < <(jq -c '.files[]' <<<"$record")

  if [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  return 1
}

download_file_if_missing() {
  local source="$1"
  local target="$2"
  if [[ ! -f "$target" ]]; then
    curl -fsL --compressed "$source" -o "$target"
  fi
}

download_companion() {
  local base_url="$1"
  local name="$2"
  local target_dir="$3"
  if [[ -z "$name" ]]; then
    return
  fi
  local source_url
  source_url="$(url_join "$base_url" "$name")"
  local length
  length="$(get_remote_length "$source_url" || true)"
  if [[ -n "$length" ]] && (( length > max_bytes )); then
    echo "Companion '$name' is $length bytes, above MaxBytes $max_bytes." >&2
    exit 1
  fi
  local target_path="$target_dir/$(url_leaf "$source_url")"
  mkdir -p "$target_dir"
  download_file_if_missing "$source_url" "$target_path"
}

download_relative_companion() {
  local base_url="$1"
  local name="$2"
  local target_dir="$3"
  if [[ -z "$name" ]]; then
    return
  fi
  local normalized="${name//\\\\//}"
  normalized="${normalized/#.\//}"
  local source_url
  source_url="$(url_join "$base_url" "$normalized")"
  local length
  length="$(get_remote_length "$source_url" || true)"
  if [[ -n "$length" ]] && (( length > max_bytes )); then
    echo "Companion '$name' is $length bytes, above MaxBytes $max_bytes." >&2
    exit 1
  fi
  local rel_path="${normalized//\//\/}"
  local target_path="$target_dir/$rel_path"
  mkdir -p "$(dirname "$target_path")"
  download_file_if_missing "$source_url" "$target_path"
}

ini_value() {
  local file="$1"
  local key="$2"
  python3 - "$file" "$key" <<'PY'
import re
import sys

path, key = sys.argv[1], sys.argv[2]
pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=\s*(.*?)\s*$", re.IGNORECASE)
for line in open(path, encoding="utf-8", errors="ignore"):
    match = pattern.match(line)
    if match:
        value = match.group(1).strip()
        if value:
            print(value)
            break
PY
}

download_hamamatsu_vms_companions() {
  local vms_source="$1"
  local vms_path="$2"
  local target_dir="$3"
  local rows cols name
  rows="$(ini_value "$vms_path" "NoJpegRows")"
  cols="$(ini_value "$vms_path" "NoJpegColumns")"
  if ! [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ ]]; then
    return
  fi
  (( rows == 0 || cols == 0 )) && return
  local base
  base="$(url_parent "$vms_source")"
  mapfile -t names < <(printf '%s\n%s\n' "$(ini_value "$vms_path" "ImageFile")" "$(ini_value "$vms_path" "ImageFile(($((cols - 1)),$((rows - 1)))")")
  declare -a seen=()
  declare -a unique_names=()
  for name in "${names[@]}"; do
    [[ -z "$name" ]] && continue
    duplicate=0
    for s in "${seen[@]:-}"; do
      if [[ "$s" == "$name" ]]; then
        duplicate=1
      fi
    done
    [[ $duplicate -eq 1 ]] && continue
    seen+=("$name")
    download_companion "$base" "$name" "$target_dir"
  done
}

download_nrrd_companions() {
  local header_source="$1"
  local header_path="$2"
  local target_dir="$3"
  local name
  name="$(python3 - "$header_path" <<'PY'
import re, sys
text=open(sys.argv[1]).read()
m=re.search(r'(?im)^\\s*data\\s*file\\s*:\\s*(.+?)\\s*$', text)
if m:
    print(m.group(1).strip())
    raise SystemExit
m=re.search(r'(?im)^\\s*datafile\\s*:\\s*(.+?)\\s*$', text)
if m:
    print(m.group(1).strip())
PY
)"
  [[ -z "$name" || "$name" == *" "* ]] && return
  local base
  base="$(url_parent "$header_source")"
  download_companion "$base" "$name" "$target_dir"
}

download_ics_companions() {
  local ics_source="$1"
  local ics_path="$2"
  local target_dir="$3"
  local name
  name="$(python3 - "$ics_path" <<'PY'
import re, os, sys
text=open(sys.argv[1]).read()
m=re.search(r'(?im)^\\s*filename\\s+(.+?)\\s*$', text)
if not m:
    print('')
    raise SystemExit
name=m.group(1).strip()
if not re.search(r'\\.[A-Za-z0-9]+$', name):
    name += '.ids'
print(name)
PY
)"
  if [[ -z "$name" ]]; then
    leaf="$(basename "$ics_path")"
    name="$(python3 - <<'PY'
import sys, os
print(os.path.splitext(sys.argv[1])[0] + '.ids')
PY
"$leaf")"
  fi
  local base="$(url_parent "$ics_source")"
  download_companion "$base" "$name" "$target_dir"
}

download_spc_companions() {
  local source="$1"
  local target_dir="$2"
  local leaf
  leaf="$(url_leaf "$source")"
  local companion
  if [[ "$leaf" == *.set ]]; then
    companion="${leaf%.*}.spc"
  else
    companion="${leaf%.*}.set"
  fi
  local base="$(url_parent "$source")"
  download_companion "$base" "$companion" "$target_dir"
}

download_jdce_companions() {
  local jdce_source="$1"
  local jdce_path="$2"
  local target_dir="$3"
  local csv_name
  csv_name="$(python3 - "$jdce_path" <<'PY'
import re, sys
text=open(sys.argv[1]).read()
m=re.search(r'"ImageMetadataFiles"\\s*:\\s*\\[\\s*"([^"]+)"', text)
print(m.group(1) if m else '')
PY
)"
  [[ -z "$csv_name" ]] && return
  local base="$(url_parent "$jdce_source")"
  download_relative_companion "$base" "$csv_name" "$target_dir"
  local csv_path="$target_dir/$csv_name"
  local row
  row="$(python3 - "$csv_path" <<'PY'
import csv
import sys
with open(sys.argv[1], newline='') as f:
    reader = csv.DictReader(f)
    first = next(reader, None)
    if not first:
        raise SystemExit
    print(first.get("ImageSubFolderPath", ""), first.get("ImageFileName", ""), sep="\t")
PY
)"
  if [[ -z "$row" ]]; then
    return
  fi
  folder="$(echo "$row" | cut -f1)"
  file="$(echo "$row" | cut -f2)"
  [[ -z "$file" ]] && return
  local relative="${folder:+$folder/}$file"
  download_relative_companion "$base" "$relative" "$target_dir"
}

download_incell_companions() {
  local source="$1"
  local xdce_path="$2"
  local target_dir="$3"
  local filename
  filename="$(python3 - "$xdce_path" <<'PY'
import re, sys
text=open(sys.argv[1]).read()
m=re.search(r'filename\\s*=\\s*"([^"]+\\.(?:tif|tiff))"', text, re.I)
print(m.group(1) if m else '')
PY
)"
  [[ -z "$filename" ]] && return
  download_relative_companion "$(url_parent "$source")" "$filename" "$target_dir"
}

download_zenodo_companions() {
  local record_id="$1"
  local target_dir="$2"
  local pattern="$3"
  local record
  local has_preferred=1
  record="$(curl -fsSL "https://zenodo.org/api/records/$record_id")"
  while IFS= read -r file_json; do
    name="$(jq -r '.key' <<<"$file_json")"
    [[ -n "$pattern" ]] && [[ ! "$name" =~ $pattern ]] && continue
    size="$(jq -r '.size' <<<"$file_json")"
    if [[ -n "$size" ]] && (( size > max_bytes )); then
      echo "Companion '$name' is $size bytes, above MaxBytes $max_bytes." >&2
      exit 1
    fi
    url="$(jq -r '.links.self' <<<"$file_json")"
    download_file_if_missing "$url" "$target_dir/$(basename "$name")"
  done < <(jq -c '.files[]' <<<"$record")
}

download_cellsens_companions() {
  local source="$1"
  local record_id="$2"
  local target_dir="$3"
  if [[ "$source" == *"zenodo.org/api/records/"* ]]; then
    download_zenodo_companions "$record_id" "$target_dir" '^frame_.*\.ets$'
    return
  fi
  local base
  base="$(url_parent "$source")"
  stem="$(url_leaf "$source")"
  stem="${stem%.*}"
  local pixels_url="${base}_$stem/_/"
  local escaped_stem="${stem}"
  while IFS= read -r stack_rel; do
    stack_url="$(url_join "$pixels_url" "$stack_rel")"
    if [[ "$stack_url" != */ ]]; then
      continue
    fi
    while IFS= read -r ets_rel; do
      ets_url="$(url_join "$stack_url" "$ets_rel")"
      leaf="$(url_leaf "$ets_url")"
      if [[ "$leaf" =~ ^frame_.*\.ets$ ]]; then
        local stack_name
        stack_name="$(url_leaf "$stack_url")"
        stack_name="${stack_name%/}"
        download_relative_companion "$base" "_${escaped_stem}_/${stack_name}/$leaf" "$target_dir"
        return
      fi
    done < <(get_directory_links "$stack_url")
  done < <(get_directory_links "$pixels_url")
}

get_xml_attr() {
  local content="$1"
  local element="$2"
  local attr="$3"
  local result
  result="$(python3 - <<'PY'
import re, sys
content = sys.argv[1]
elem = sys.argv[2]
attr = sys.argv[3]
m = re.search(rf"<[^>]*\\b{re.escape(elem)}\\b[^>]*\\b{re.escape(attr)}\\s*=\\s*['\"]([^'\"]+)['\"]", content, re.I)
if m:
    import html
    print(html.unescape(m.group(1)))
PY
 "$content" "$element" "$attr")"
  echo "$result"
}

download_xlef_companions() {
  local xlef_source="$1"
  local xlef_path="$2"
  local target_dir="$3"
  local xlef_content
  xlef_content="$(cat "$xlef_path")"
  local xlif_name
  xlif_name="$(get_xml_attr "$xlef_content" Reference File | sed 's#^./metadata/#./Metadata/#; s#\\\\#/#g')"
  [[ -z "$xlif_name" ]] && return
  local base="$(url_parent "$xlef_source")"
  local xlif_url
  xlif_url="$(url_join "$base" "$xlif_name")"
  local normalized_name="${xlif_name//\\\\//}"
  normalized_name="${normalized_name/#.\//}"
  download_relative_companion "$base" "$normalized_name" "$target_dir"
  local xlif_path="$target_dir/$normalized_name"
  local xlif_content
  xlif_content="$(cat "$xlif_path")"
  local frame_name
  frame_name="$(get_xml_attr "$xlif_content" Frame File)"
  [[ -z "$frame_name" ]] && return
  local xlif_base="$(url_parent "$xlif_url")"
  download_relative_companion "$xlif_base" "$frame_name" "$(dirname "$xlif_path")"
}

download_micromanager_companions() {
  local source="$1"
  local metadata_path="$2"
  local target_dir="$3"
  local filename
  filename="$(python3 - "$metadata_path" <<'PY'
import re, sys
text=open(sys.argv[1]).read()
m=re.search(r'"FileName"\\s*:\\s*"([^"]+\\.(?:tif|tiff))"', text, re.I)
print(m.group(1) if m else '')
PY
)"
  [[ -z "$filename" ]] && return
  download_relative_companion "$(url_parent "$source")" "$filename" "$target_dir"
}

get_htd_first_well() {
  local content="$1"
  python3 - "$content" <<'PY'
import re, sys
for line in open(sys.argv[1]):
    m = re.match(r'^\\s*"WellsSelection(\\d+)"\\s*,\\s*(.+?)\\s*$', line)
    if not m:
        continue
    row = int(m.group(1))
    cols = [c.strip(' \t"') for c in m.group(2).split(',')]
    for i, c in enumerate(cols, 1):
        if c.lower() == "true":
            print(f"{chr(ord('A') + row - 1)}{i:02d}")
            raise SystemExit
PY
}

download_metaxpress_companions() {
  local htd_source="$1"
  local htd_path="$2"
  local target_dir="$3"
  local well
  well="$(get_htd_first_well "$htd_path")"
  [[ -z "$well" ]] && return
  local plate
  plate="$(url_leaf "$htd_source" | sed 's/\\.htd$//')"
  local base="$(url_parent "$htd_source")"
  while IFS= read -r name; do
    if [[ ! "$name" =~ \.(tif|tiff)$ ]]; then
      continue
    fi
    if [[ "$name" =~ (?i)_thumb ]]; then
      continue
    fi
    if [[ "$name" == "$plate"_"$well"* ]]; then
      download_companion "$base" "$name" "$target_dir"
      return
    fi
  done < <(get_directory_links "$base")
}

download_columbus_companions() {
  local index_source="$1"
  local target_dir="$2"
  local base="$(url_parent "$index_source")"
  download_companion "$base" "ImageIndex.ColumbusIDX.xml" "$target_dir"
  download_companion "$base" "001001-1.tif" "$target_dir"
}

download_ndpis_companions() {
  local sidecar_source="$1"
  local sidecar_path="$2"
  local target_dir="$3"
  image_file="$(python3 - "$sidecar_path" <<'PY'
import re, sys
text=open(sys.argv[1]).read()
m=re.match(r'(?im)^\\s*Image0\\s*=\\s*(.+?)\\s*$', text)
print(m.group(1).strip() if m else '')
PY
)"
  [[ -z "$image_file" ]] && return
  local base="$(url_parent "$sidecar_source")"
  download_companion "$base" "$image_file" "$target_dir"
}

download_cv7000_known_fixture() {
  local target_dir="$1"
  local base="https://downloads.openmicroscopy.org/images/CV7000/idr0088/110000251230/"
  download_companion "$base" "110000251230.wpi" "$target_dir"
  download_companion "$base" "MeasurementData.mlf" "$target_dir"
  download_companion "$base" "110000251230_B02_T0001F001L01A01Z01C01.tif" "$target_dir"
}

download_mng_known_fixture() {
  local target_dir="$1"
  local source="https://sourceforge.net/projects/libmng/files/libmng-testsuites/MNGsuite-1.0/MNGsuite.zip/download"
  local scratch
  scratch="$(mktemp -d)"
  local zip="$scratch/MNGsuite.zip"
  local sample="$scratch/unzip/MNGsuite/images/button1.mng"
  local target="$target_dir/button1.mng"
  curl -fsL --max-redirs 10 "$source" -o "$zip"
  mkdir -p "$scratch/unzip"
  unzip -q "$zip" -d "$scratch/unzip"
  mkdir -p "$target_dir"
  cp "$sample" "$target"
  printf '%s\t%s\t%s\t%s\n' "$format" "$source" "$target" "$(stat -c%s "$target")"
  rm -rf "$scratch"
}

source_url="$(resolve_source_url "${entries[@]:-}")"
zenodo_record="$(resolve_zenodo_record "${entries[@]:-}")"
if [[ -z "$source_url" && -z "$zenodo_record" ]]; then
  echo "Format '$format' has no direct public URL or Zenodo record in sources.json: ${entries[*]:-}" >&2
  exit 1
fi

target_root="$(resolve_path "$out_dir")"
target_dir="$target_root/$format"
mkdir -p "$target_dir"

if [[ "$format" == "cv7000" ]]; then
  download_cv7000_known_fixture "$target_dir"
  exit 0
fi
if [[ "$format" == "mng" ]]; then
  download_mng_known_fixture "$target_dir"
  exit 0
fi

candidate_url=""
candidate_name=""
if [[ -n "$source_url" ]]; then
  source_url="${source_url%/}/"
  preferred="$(preferred_pattern "$format")"
  if candidate="$(find_candidate "$source_url" "$max_depth" "$preferred")"; then
    candidate_url="$candidate"
    candidate_name="$(url_leaf "$candidate_url")"
  fi
fi

if [[ -z "$candidate_url" && -n "$zenodo_record" ]]; then
  preferred="$(preferred_pattern "$format")"
  if result="$(find_zenodo_candidate "$zenodo_record" "$preferred")"; then
    candidate_url="${result%%$'\t'*}"
    candidate_name="${result#*$'\t'}"
  fi
fi

if [[ -z "$candidate_url" ]]; then
  echo "No downloadable candidate for '$format' matched pattern '$name_pattern' within depth $max_depth and size cap $max_bytes bytes." >&2
  exit 1
fi

if [[ -z "$candidate_name" ]]; then
  candidate_name="$(url_leaf "$candidate_url")"
fi

target_path="$target_dir/$candidate_name"
download_file_if_missing "$candidate_url" "$target_path"
printf '%s\t%s\t%s\t%s\n' "$format" "$candidate_url" "$target_path" "$(stat -c%s "$target_path")"

if [[ "$format" == "hamamatsuvms" ]]; then
  download_hamamatsu_vms_companions "$candidate_url" "$target_path" "$target_dir"
fi
if [[ "$format" == "nrrd" ]]; then
  download_nrrd_companions "$candidate_url" "$target_path" "$target_dir"
fi
if [[ "$format" == "ics" ]]; then
  download_ics_companions "$candidate_url" "$target_path" "$target_dir"
fi
if [[ "$format" == "spc" ]]; then
  download_spc_companions "$candidate_url" "$target_dir"
fi
if [[ "$format" == "jdce" ]]; then
  download_jdce_companions "$candidate_url" "$target_path" "$target_dir"
fi
if [[ "$format" == "incell" ]]; then
  download_incell_companions "$candidate_url" "$target_path" "$target_dir"
fi
if [[ "$format" == "cellsens" ]]; then
  download_cellsens_companions "$candidate_url" "$zenodo_record" "$target_dir"
fi
if [[ "$format" == "xlef" ]]; then
  download_xlef_companions "$candidate_url" "$target_path" "$target_dir"
fi
if [[ "$format" == "micromanager" ]]; then
  download_micromanager_companions "$candidate_url" "$target_path" "$target_dir"
fi
if [[ "$format" == "metaxpress" ]]; then
  download_metaxpress_companions "$candidate_url" "$target_path" "$target_dir"
fi
if [[ "$format" == "columbus" ]]; then
  download_columbus_companions "$candidate_url" "$target_dir"
fi
if [[ "$format" == "ndpis" ]]; then
  download_ndpis_companions "$candidate_url" "$target_path" "$target_dir"
fi
