#!/usr/bin/env bash
# =============================================================================
# importer.sh — Collect files from an SD-card folder and size them up.
#
# This module doesn't copy anything itself; it just SCANS a source folder,
# categorizes what it finds (RAW vs JPEG vs other), and can compute total
# byte size. The TUI/CLI decides where to actually copy the files.
# =============================================================================

# Globals filled in by importer_collect. Each array holds full file paths.
RAWS=()     # files matching the profile's raw_exts (e.g. .ARW)
JPEGS=()    # files matching the profile's jpeg_exts (e.g. .JPG, .JPEG)
OTHERS=()   # every other file — copied only when the profile isn't split

# ------------------------------------------------------------------
# importer_collect <folder> <raw_exts_csv> <jpeg_exts_csv>
# ------------------------------------------------------------------
# Walks one SD-card DCIM folder (non-recursive) and adds each file it
# finds to RAWS[], JPEGS[], or OTHERS[] depending on its extension.
# Extensions in the CSV lists are matched case-insensitively.
#
# Example:
#   importer_collect /Volumes/SD/DCIM/10860905 "ARW" "JPG,JPEG"
#   -> RAWS gets DSC00001.ARW, JPEGS gets DSC00001.JPG, OTHERS gets nothing
importer_collect() {
  local folder="$1" raw_exts="$2" jpeg_exts="$3"
  local f ext eu is_raw is_jpeg e eu2

  # Read every file in the folder (no subdirectories).
  while IFS= read -r -d '' f; do
    ext="${f##*.}"                              # extension without the dot
    eu=$(echo "$ext" | tr '[:lower:]' '[:upper:]')  # normalize to UPPERCASE
    is_raw=false; is_jpeg=false

    # Check whether this file's extension is in the raw list.
    if [[ -n "$raw_exts" ]]; then
      IFS=',' read -ra exts <<< "$raw_exts"
      for e in "${exts[@]}"; do
        eu2=$(echo "$e" | tr '[:lower:]' '[:upper:]')
        [[ "$eu2" == "$eu" ]] && { is_raw=true; break; }
      done
    fi
    # Check the jpeg list the same way.
    if [[ -n "$jpeg_exts" ]]; then
      IFS=',' read -ra exts <<< "$jpeg_exts"
      for e in "${exts[@]}"; do
        eu2=$(echo "$e" | tr '[:lower:]' '[:upper:]')
        [[ "$eu2" == "$eu" ]] && { is_jpeg=true; break; }
      done
    fi

    # Route the file to the right bucket. Files that match nothing land
    # in OTHERS, which the unsplit-profile copy path treats as "everything".
    if   $is_raw;  then RAWS+=("$f")
    elif $is_jpeg; then JPEGS+=("$f")
    else                OTHERS+=("$f")
    fi
  done < <(find "$folder" -maxdepth 1 -type f -print0 | sort -z)
}

# ------------------------------------------------------------------
# importer_count_by_ext_csv <dir> <csv_exts>
# ------------------------------------------------------------------
# Recursively count files under <dir> whose extension matches ANY entry
# in the comma-separated <csv_exts> list. Returns 0 if the list is blank
# so callers can safely pass a possibly-empty profile field.
#
# Example:
#   importer_count_by_ext_csv /Users/you/Pictures/Sony ARW
#   -> "1817"
importer_count_by_ext_csv() {
  local dir="$1" csv="$2"
  [[ -z "$csv" ]] && { printf '0'; return; }
  local total=0
  local -a arr
  IFS=',' read -ra arr <<< "$csv"
  local ext c
  for ext in "${arr[@]}"; do
    c=$(find "$dir" -type f -iname "*.${ext}" 2>/dev/null | wc -l | tr -d ' ')
    total=$(( total + c ))
  done
  printf '%d' "$total"
}

# ------------------------------------------------------------------
# importer_sum_size <file>...
# ------------------------------------------------------------------
# Sum up the byte sizes of every file passed in. Prints one integer.
# Uses `stat -f%z` (macOS syntax). Missing files count as 0.
importer_sum_size() {
  local total=0 f sz
  for f in "$@"; do
    sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
    (( total += sz )) || true
  done
  echo "$total"
}

# ------------------------------------------------------------------
# importer_human_size <bytes>
# ------------------------------------------------------------------
# Convert a raw byte count into "12.3 MB" / "1.4 GB" style.
importer_human_size() {
  local b=$1
  if   (( b < 1024 ));       then printf "%d B"   "$b"
  elif (( b < 1048576 ));    then awk "BEGIN{printf \"%.1f KB\", $b/1024}"
  elif (( b < 1073741824 )); then awk "BEGIN{printf \"%.1f MB\", $b/1048576}"
  else                            awk "BEGIN{printf \"%.1f GB\", $b/1073741824}"
  fi
}

# ------------------------------------------------------------------
# importer_copy_files <dest_dir> <file>...
# ------------------------------------------------------------------
# Copy each file into <dest_dir>. If a file with the same name is already
# there, skip it (never overwrite). Prints "<copied> <skipped>" so the
# caller can report both counts.
importer_copy_files() {
  local dest="$1"; shift
  local -a files=("$@")
  mkdir -p "$dest"
  local copied=0 skipped=0 fname f
  for f in "${files[@]}"; do
    fname=$(basename "$f")
    if [[ -f "$dest/$fname" ]]; then (( skipped++ )) || true
    else cp "$f" "$dest/$fname"; (( copied++ )) || true
    fi
  done
  echo "$copied $skipped"
}
