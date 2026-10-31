#!/usr/bin/env bash
# =============================================================================
# culler.sh — Find JPEGs that no longer have a matching RAW file.
#
# The workflow this supports:
#   1. You import RAW + JPEG for every shot into <event>/raws/ and <event>/jpgs/
#   2. You cull in Lightroom by deleting the RAWs you don't want
#   3. This module finds the JPEGs whose RAWs are now gone (orphans)
#      so you can delete them and reclaim disk space
#
# "Matching" means "same filename stem" — DSC00123.ARW matches DSC00123.JPG.
# Requires: config.sh, importer.sh already sourced.
# =============================================================================

# Global result: list of full paths to orphaned JPEG files.
ORPHAN_JPEGS=()

# ------------------------------------------------------------------
# culler_find_orphans <event_dir> [raw_exts_csv] [jpeg_exts_csv]
# ------------------------------------------------------------------
# Fill the global ORPHAN_JPEGS array with every JPEG in <event_dir>
# whose filename stem has NO matching RAW.
#
# Extension lists are optional. When provided, the search is done
# RECURSIVELY across the whole event directory — this handles both
# layouts:
#   • split      : <event>/raws/*.ARW + <event>/jpgs/*.JPG
#   • flat       : <event>/*.ARW + <event>/*.JPG (or any nesting)
# When exts aren't given, we fall back to the legacy behavior of
# looking in <event>/raws/ and <event>/jpgs/ subdirs only.
#
# Example (with split layout):
#   raws/DSC00001.ARW, DSC00002.ARW
#   jpgs/DSC00001.JPG, DSC00002.JPG, DSC00003.JPG
#   -> ORPHAN_JPEGS = ( ".../jpgs/DSC00003.JPG" )
culler_find_orphans() {
  local event_dir="$1"
  local raw_exts="${2:-}"
  local jpg_exts="${3:-}"

  ORPHAN_JPEGS=()
  local -a raw_stems=()   # list of RAW filenames without their extension
  local -a jpg_paths=()   # every JPEG we might have to consider

  # Build the find expression by extension. When exts are given, the
  # search covers the ENTIRE event dir; the split raws/ + jpgs/ pattern
  # is one valid layout that this naturally matches too.
  local f base ext
  if [[ -n "$raw_exts" ]]; then
    local -a rexts
    IFS=',' read -ra rexts <<< "$raw_exts"
    for ext in "${rexts[@]}"; do
      while IFS= read -r -d '' f; do
        base=$(basename "$f")
        raw_stems+=("${base%.*}")
      done < <(find "$event_dir" -type f -iname "*.${ext}" -print0 2>/dev/null)
    done
  else
    # Legacy fallback: split layout only.
    while IFS= read -r -d '' f; do
      base=$(basename "$f")
      raw_stems+=("${base%.*}")
    done < <(find "$event_dir/raws" -maxdepth 1 -type f -print0 2>/dev/null)
  fi

  if [[ -n "$jpg_exts" ]]; then
    local -a jexts
    IFS=',' read -ra jexts <<< "$jpg_exts"
    for ext in "${jexts[@]}"; do
      while IFS= read -r -d '' f; do
        jpg_paths+=("$f")
      done < <(find "$event_dir" -type f -iname "*.${ext}" -print0 2>/dev/null | sort -z)
    done
  else
    while IFS= read -r -d '' f; do
      jpg_paths+=("$f")
    done < <(find "$event_dir/jpgs" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
  fi

  # For each JPEG, look for a matching RAW stem. No match -> orphan.
  local stem matched rb
  for f in "${jpg_paths[@]+"${jpg_paths[@]}"}"; do
    base=$(basename "$f")
    stem="${base%.*}"
    matched=false
    for rb in "${raw_stems[@]+"${raw_stems[@]}"}"; do
      [[ "$rb" == "$stem" ]] && { matched=true; break; }
    done
    $matched || ORPHAN_JPEGS+=("$f")
  done
}

# ------------------------------------------------------------------
# culler_find_event_dirs <event_name>
# ------------------------------------------------------------------
# For a given event name, print the full path to every camera library
# that contains that event as a split (raws/ + jpgs/) folder. One path
# per line. Used when the same event name could exist under multiple
# cameras and the user needs to pick which one to cull.
culler_find_event_dirs() {
  local event_name="$1" profile candidate
  for profile in "${PROFILES[@]}"; do
    # Skip profiles that aren't set to split into raws/ and jpgs/ — the
    # culler only understands the split layout.
    [[ "$(config_profile_split "$profile")" != "true" ]] && continue
    candidate="$(config_profile_outdir "$profile")/$event_name"
    # Emit only if BOTH raws/ and jpgs/ actually exist under this event.
    [[ -d "$candidate/raws" && -d "$candidate/jpgs" ]] && echo "$candidate"
  done
}
