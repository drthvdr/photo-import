#!/usr/bin/env bash
# =============================================================================
# sdcard.sh — Everything that reads the SD card.
#
# Finds mounted SD cards, lists their DCIM folders, parses the Sony date
# encoding to show a friendly date next to each folder, and guesses which
# camera profile the card belongs to based on the RAW files it holds.
#
# Requires: config.sh already sourced (uses PROFILES[] and config_profile_*).
# =============================================================================

# ------------------------------------------------------------------
# sdcard_find
# ------------------------------------------------------------------
# Print the full path of every mounted volume under /Volumes that
# contains a DCIM folder. One path per line. Non-camera drives (e.g.
# a plain USB stick) are ignored because they don't have DCIM.
sdcard_find() {
  local vol
  for vol in /Volumes/*/; do
    [[ -d "${vol}DCIM" ]] && printf '%s\n' "${vol%/}"
  done
}

# ------------------------------------------------------------------
# sdcard_dcim_folders <card_path>
# ------------------------------------------------------------------
# List every subfolder inside <card_path>/DCIM (one path per line),
# sorted alphabetically. Sony's naming means alphabetical also happens
# to be oldest-to-newest.
sdcard_dcim_folders() {
  find "$1/DCIM" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null \
    | sort -z | tr '\0' '\n'
}

# ------------------------------------------------------------------
# sdcard_folder_date_label <folder_path>
# ------------------------------------------------------------------
# Sony encodes the shoot date into the folder name. Format is 8 digits:
#   [NNN][Y][MM][DD]
# where NNN is a running counter, Y is the LAST DIGIT of the year,
# MM is month, DD is day. So "10860905" = counter 108, year ends in 6,
# September 5th. This function turns that into "(Sat Sep 6, 2026)".
#
# Prints nothing if the folder name doesn't match the format so the
# caller can safely skip the label.
sdcard_folder_date_label() {
  local ymd; ymd=$(sdcard_folder_ymd "$1")
  [[ -z "$ymd" ]] && return 0

  # Format the date via macOS `date -j -f` (parse, then reformat).
  local label
  label=$(date -j -f "%Y%m%d" "$ymd" "+%a %b %e, %Y" 2>/dev/null | sed 's/  / /') || return 0
  [[ -n "$label" ]] && printf "(%s)" "$label"
}

# ------------------------------------------------------------------
# sdcard_folder_ymd <folder_path>
# ------------------------------------------------------------------
# Decode a Sony date folder name into a plain YYYYMMDD string
# (e.g. ".../10860905" -> "20260905"). Prints nothing when the name
# isn't a valid Sony date folder. This is the one place the Sony
# [NNN][Y][MM][DD] format is parsed; everything else builds on it.
sdcard_folder_ymd() {
  local name; name=$(basename "$1")
  # Must be exactly 8 digits, otherwise it isn't a Sony date folder.
  [[ "$name" =~ ^[0-9]{8}$ ]] || return 0

  # Slice out the year-digit, month, and day.
  local y_digit="${name:3:1}"
  local mm="${name:4:2}"
  local dd="${name:6:2}"

  # Reject bogus dates like month 15 or day 00.
  # (10#$mm forces base-10; without it "08" is treated as octal.)
  (( 10#$mm >= 1 && 10#$mm <= 12 && 10#$dd >= 1 && 10#$dd <= 31 )) || return 0

  # Expand the single year-digit to a 4-digit year based on the current
  # decade. E.g. in 2026 the digit "6" means 2026, "5" means 2025.
  # If that math produces a year MORE than one year in the future,
  # roll back a decade (so "9" in 2020 means 2019, not 2029).
  local current_year; current_year=$(date +%Y)
  local decade=$(( (current_year / 10) * 10 ))
  local full_year=$(( decade + y_digit ))
  (( full_year > current_year + 1 )) && full_year=$(( full_year - 10 ))

  printf '%s%s%s' "$full_year" "$mm" "$dd"
}

# ------------------------------------------------------------------
# sdcard_event_name_from_folders <folder>...
# ------------------------------------------------------------------
# Given one or more DCIM folder paths, print the default album-name
# PREFIX built from their embedded dates, in ISO "YYYY-MM-DD " form
# (note the trailing space) so albums sort chronologically in Finder:
#   1 folder       -> "2026-09-05 "
#   several folders-> the EARLIEST date, e.g. "2026-08-27 "
# The user types the description after it, giving album names like
# "2026-08-15 Antelope Canyon - Vermillion Cliffs". Prints nothing if
# none of the folders have a decodable date.
sdcard_event_name_from_folders() {
  local f ymd earliest=""

  # Decode each folder and keep the smallest YYYYMMDD
  # (the string compare works because the format is fixed-width).
  for f in "$@"; do
    ymd=$(sdcard_folder_ymd "$f")
    [[ -z "$ymd" ]] && continue
    if [[ -z "$earliest" || "$ymd" < "$earliest" ]]; then
      earliest="$ymd"
    fi
  done
  [[ -z "$earliest" ]] && return 0

  printf '%s-%s-%s ' "${earliest:0:4}" "${earliest:4:2}" "${earliest:6:2}"
}

# ------------------------------------------------------------------
# sdcard_matching_profile_indices <dcim_path>
# ------------------------------------------------------------------
# For each camera profile in PROFILES[], check whether any file matching
# that profile's RAW extension exists on the card. Print the index of
# every matching profile, one per line.
#
# Called by the TUI: 1 match -> auto-select silently; multiple matches
# or 0 matches -> show a picker.
sdcard_matching_profile_indices() {
  local dcim="$1" i profile check_exts found ext count
  for i in "${!PROFILES[@]}"; do
    profile="${PROFILES[$i]}"
    # Prefer matching by RAW extension; fall back to JPEG for profiles
    # that don't set one (e.g. JPG-only sources). Blank/blank profiles
    # match nothing and are skipped by the empty-string guard.
    check_exts=$(config_profile_raw_exts "$profile")
    [[ -z "$check_exts" ]] && check_exts=$(config_profile_jpg_exts "$profile")
    [[ -z "$check_exts" ]] && continue

    # As soon as we find ONE matching file, mark this profile as a match.
    found=false
    IFS=',' read -ra exts <<< "$check_exts"
    for ext in "${exts[@]}"; do
      count=$(find "$dcim" -iname "*.${ext}" 2>/dev/null | wc -l | tr -d ' ')
      (( count > 0 )) && { found=true; break; }
    done
    $found && echo "$i"
  done
}
