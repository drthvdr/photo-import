#!/usr/bin/env bash
# Plain terminal UI — arrow-key menus, no gum required
# Requires: all lib/*.sh sourced

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m' CYAN=$'\033[0;36m' BOLD=$'\033[1m'
  DIM=$'\033[2m' RESET=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
fi

_cli_info()  { printf "${BLUE}→${RESET} %s\n" "$*"; }
_cli_ok()    { printf "${GREEN}✓${RESET} %s\n" "$*"; }
_cli_warn()  { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }
_cli_die()   { printf "${RED}✗${RESET} %s\n" "$*" >&2; exit 1; }
_cli_hdr()   { printf "\n${BOLD}%s${RESET}\n" "$*"; }

# ── Arrow-key single-select ───────────────────────────────────────────────────
# Sets MENU_RESULT (0-based index). Pre-set MENU_RESULT to control initial selection.
MENU_RESULT=0
_cli_pick_menu() {
  local -a opts=("$@")
  local n=${#opts[@]} sel=$MENU_RESULT
  (( sel >= n )) && sel=0

  trap 'tput cnorm 2>/dev/null; echo; exit 130' INT
  tput civis 2>/dev/null || true

  __draw() {
    local i; for i in "${!opts[@]}"; do
      if (( i == sel )); then printf "  ${CYAN}${BOLD}›${RESET} ${BOLD}%s${RESET}\n" "${opts[$i]}"
      else                    printf "    ${DIM}%s${RESET}\n" "${opts[$i]}"
      fi
    done
  }
  __draw

  while true; do
    local k; IFS= read -rsn1 k 2>/dev/null || true
    if [[ "$k" == $'\033' ]]; then
      IFS= read -rsn2 k 2>/dev/null || true
      case "$k" in
        '[A') (( sel > 0 ))   && (( sel-- )) || true ;;
        '[B') (( sel < n-1 )) && (( sel++ )) || true ;;
      esac
      printf "\033[%dA" "$n"; __draw
    elif [[ "$k" == "" ]]; then break; fi
  done

  tput cnorm 2>/dev/null || true; trap - INT
  printf "\033[%dA" "$n"
  local i; for i in $(seq 1 "$n"); do printf "\033[2K\n"; done
  printf "\033[%dA" "$n"
  MENU_RESULT=$sel
}

# ── Arrow-key multi-select ────────────────────────────────────────────────────
# Sets MENU_MULTI_RESULT[] (array of selected 0-based indices).
# Pre-set MENU_MULTI_RESULT to control initial selections.
MENU_MULTI_RESULT=()
_cli_pick_menu_multi() {
  local -a opts=("$@")
  local n=${#opts[@]} cur=0
  local -a sel_state=()
  local i; for i in $(seq 0 $((n-1))); do sel_state[$i]=0; done
  for i in "${MENU_MULTI_RESULT[@]+"${MENU_MULTI_RESULT[@]}"}"; do
    (( i < n )) && sel_state[$i]=1 || true
  done

  trap 'tput cnorm 2>/dev/null; echo; exit 130' INT
  tput civis 2>/dev/null || true

  __draw_multi() {
    local i
    for i in "${!opts[@]}"; do
      local box=" "; (( ${sel_state[$i]:-0} )) && box="${GREEN}✓${RESET}"
      if (( i == cur )); then printf "  ${CYAN}${BOLD}›${RESET} [%b] ${BOLD}%s${RESET}\n" "$box" "${opts[$i]}"
      else                    printf "    [%b] ${DIM}%s${RESET}\n" "$box" "${opts[$i]}"
      fi
    done
    printf "  ${DIM}↑↓ move · space toggle · enter confirm${RESET}\n"
  }
  __draw_multi

  while true; do
    local k; IFS= read -rsn1 k 2>/dev/null || true
    if [[ "$k" == $'\033' ]]; then
      IFS= read -rsn2 k 2>/dev/null || true
      case "$k" in
        '[A') (( cur > 0 ))   && (( cur-- )) || true ;;
        '[B') (( cur < n-1 )) && (( cur++ )) || true ;;
      esac
    elif [[ "$k" == " " ]]; then
      if (( ${sel_state[$cur]:-0} )); then sel_state[$cur]=0
      else sel_state[$cur]=1; fi
    elif [[ "$k" == "" ]]; then
      local any=0
      for i in "${!sel_state[@]}"; do (( ${sel_state[$i]:-0} )) && any=1 || true; done
      (( any )) && break
      _cli_warn "Select at least one folder"
    fi
    printf "\033[%dA" "$((n+1))"; __draw_multi
  done

  tput cnorm 2>/dev/null || true; trap - INT
  printf "\033[%dA" "$((n+1))"
  for i in $(seq 1 $((n+1))); do printf "\033[2K\n"; done
  printf "\033[%dA" "$((n+1))"

  MENU_MULTI_RESULT=()
  for i in "${!sel_state[@]}"; do
    (( ${sel_state[$i]:-0} )) && MENU_MULTI_RESULT+=("$i") || true
  done
}

# ── SD card selection ─────────────────────────────────────────────────────────
_cli_pick_card() {
  local -a cards=()
  while IFS= read -r c; do [[ -n "$c" ]] && cards+=("$c"); done < <(sdcard_find)
  case ${#cards[@]} in
    0) _cli_die "No SD card found — insert your card (needs a DCIM folder)" ;;
    1) SD_PATH="${cards[0]}"; _cli_info "SD card: ${BOLD}$SD_PATH${RESET}" ;;
    *)
      _cli_hdr "Multiple SD cards found"
      MENU_RESULT=0; _cli_pick_menu "${cards[@]}"
      SD_PATH="${cards[$MENU_RESULT]}"
      _cli_info "SD card: ${BOLD}$SD_PATH${RESET}"
      ;;
  esac
}

# ── Camera selection ──────────────────────────────────────────────────────────
_cli_pick_camera() {
  local -a match_idxs=()
  while IFS= read -r idx; do match_idxs+=("$idx"); done \
    < <(sdcard_matching_profile_indices "$SD_PATH/DCIM")

  if (( ${#match_idxs[@]} == 1 )); then
    CAMERA_PROFILE="${PROFILES[${match_idxs[0]}]}"
    _cli_info "Camera: ${BOLD}$(config_profile_name "$CAMERA_PROFILE")${RESET}"
    return
  fi

  local -a candidates=()
  if (( ${#match_idxs[@]} > 1 )); then
    _cli_warn "Multiple cameras match — select which body:"
    local idx; for idx in "${match_idxs[@]}"; do candidates+=("${PROFILES[$idx]}"); done
  else
    _cli_warn "Could not auto-detect camera — select a profile:"
    candidates=("${PROFILES[@]}")
  fi

  local -a labels=()
  local p
  for p in "${candidates[@]}"; do
    labels+=("$(printf '%-22s → %s/' "$(config_profile_name "$p")" "$(config_profile_outdir "$p")")")
  done

  echo; MENU_RESULT=0; _cli_pick_menu "${labels[@]}"
  CAMERA_PROFILE="${candidates[$MENU_RESULT]}"
  _cli_info "Camera: ${BOLD}$(config_profile_name "$CAMERA_PROFILE")${RESET}"
}

# ── DCIM folder selection ─────────────────────────────────────────────────────
_cli_pick_folders() {
  local -a all_folders=()
  while IFS= read -r d; do [[ -n "$d" ]] && all_folders+=("$d"); done \
    < <(sdcard_dcim_folders "$SD_PATH")
  [[ ${#all_folders[@]} -eq 0 ]] && _cli_die "No folders in $SD_PATH/DCIM"

  SELECTED_FOLDERS=()

  if $IMPORT_ALL; then
    SELECTED_FOLDERS=("${all_folders[@]}")
    _cli_info "Using all ${#all_folders[@]} DCIM folder(s)"; return
  fi
  if [[ -n "$DCIM_FOLDER" ]]; then
    local target="$SD_PATH/DCIM/$DCIM_FOLDER"
    [[ -d "$target" ]] || _cli_die "Folder '$DCIM_FOLDER' not found in $SD_PATH/DCIM"
    SELECTED_FOLDERS=("$target")
    _cli_info "Using folder: ${BOLD}$DCIM_FOLDER${RESET}"; return
  fi
  if (( ${#all_folders[@]} == 1 )); then
    SELECTED_FOLDERS=("${all_folders[0]}")
    _cli_info "Using folder: ${BOLD}$(basename "${all_folders[0]}")${RESET}"; return
  fi

  local -a labels=()
  local last_idx=$(( ${#all_folders[@]} - 1 ))
  local i
  for i in "${!all_folders[@]}"; do
    local name; name=$(basename "${all_folders[$i]}")
    local date_label; date_label=$(sdcard_folder_date_label "${all_folders[$i]}")
    local label="$name"
    [[ -n "$date_label" ]] && label="$label  $date_label"
    (( i == last_idx )) && label="$label  ← latest"
    labels+=("$label")
  done

  _cli_hdr "DCIM folders on card"
  echo
  MENU_MULTI_RESULT=( "$last_idx" )
  _cli_pick_menu_multi "${labels[@]}"

  for i in "${MENU_MULTI_RESULT[@]}"; do
    SELECTED_FOLDERS+=("${all_folders[$i]}")
  done

  local count=${#SELECTED_FOLDERS[@]}
  if (( count == 1 )); then _cli_info "Using folder: ${BOLD}$(basename "${SELECTED_FOLDERS[0]}")${RESET}"
  else _cli_info "Using ${BOLD}$count${RESET} folders"
  fi
}

# ── Cull flow ─────────────────────────────────────────────────────────────────
_cli_run_cull() {
  if [[ -z "$EVENT_NAME" ]]; then printf "Event name: "; read -r EVENT_NAME; fi
  [[ -z "$EVENT_NAME" ]] && _cli_die "Event name cannot be empty"

  local -a event_dirs=()
  while IFS= read -r p; do [[ -n "$p" ]] && event_dirs+=("$p"); done \
    < <(culler_find_event_dirs "$EVENT_NAME")

  case ${#event_dirs[@]} in
    0) _cli_die "Event '$EVENT_NAME' not found under any configured camera folder" ;;
    1) EVENT_DIR="${event_dirs[0]}" ;;
    *)
      _cli_hdr "Found in multiple locations"; echo
      MENU_RESULT=0; _cli_pick_menu "${event_dirs[@]}"
      EVENT_DIR="${event_dirs[$MENU_RESULT]}"
      ;;
  esac

  culler_find_orphans "$EVENT_DIR"

  local total_jpgs raw_count orphan_bytes=0
  total_jpgs=$(find "$EVENT_DIR/jpgs" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
  raw_count=$(find  "$EVENT_DIR/raws" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
  (( ${#ORPHAN_JPEGS[@]} > 0 )) && orphan_bytes=$(importer_sum_size "${ORPHAN_JPEGS[@]}") || true

  printf "\n${BOLD}${CYAN}Cull — %s${RESET}\n\n" "$EVENT_NAME"
  printf "  ${BOLD}%-20s${RESET} %s\n" "RAWs kept:"     "$raw_count"
  printf "  ${BOLD}%-20s${RESET} %s\n" "JPGs total:"    "$total_jpgs"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Orphaned JPGs:" "${#ORPHAN_JPEGS[@]}"
  (( orphan_bytes > 0 )) && \
    printf "  ${BOLD}%-20s${RESET} %s\n" "Space to free:" "$(importer_human_size "$orphan_bytes")"

  if (( ${#ORPHAN_JPEGS[@]} == 0 )); then
    echo; _cli_ok "Nothing to cull — all JPGs have a matching RAW"; return
  fi

  if $DRY_RUN; then
    _cli_hdr "Would delete"
    local o; for o in "${ORPHAN_JPEGS[@]}"; do printf "  ${DIM}%s${RESET}\n" "$(basename "$o")"; done
    echo; _cli_warn "Dry run — nothing deleted"; return
  fi

  echo
  printf "Delete ${BOLD}%d${RESET} orphaned JPGs? [y/N] " "${#ORPHAN_JPEGS[@]}"
  read -r confirm
  [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "y" ]] \
    || { _cli_info "Aborted"; return; }

  local o; for o in "${ORPHAN_JPEGS[@]}"; do rm "$o"; done

  echo; _cli_ok "${BOLD}Done!${RESET}  ${#ORPHAN_JPEGS[@]} JPGs removed  •  $(importer_human_size "$orphan_bytes") freed"
  printf "  ${DIM}%s${RESET}\n" "$EVENT_DIR/jpgs"
}

# ── Import flow ───────────────────────────────────────────────────────────────
_cli_run_import() {
  printf "\n${BOLD}${CYAN}Photo Import${RESET}  ${DIM}%s${RESET}\n\n" "$(date '+%a %b %d, %Y')"

  [[ -n "$FORCE_VOLUME" ]] && SD_PATH="$FORCE_VOLUME" || { SD_PATH=""; _cli_pick_card; }
  CAMERA_PROFILE=""; _cli_pick_camera
  SELECTED_FOLDERS=(); _cli_pick_folders

  # Album names follow "YYYY-MM-DD Description". The date prefix comes from
  # the selected folders; the user types only the description after it.
  local prefix=""
  (( ${#SELECTED_FOLDERS[@]:-0} > 0 )) && \
    prefix=$(sdcard_event_name_from_folders "${SELECTED_FOLDERS[@]}")

  if [[ -z "$EVENT_NAME" ]]; then
    local rest=""
    printf "Album name: ${BOLD}%s${RESET}" "$prefix"
    read -r rest
    EVENT_NAME="${prefix}${rest}"
  elif [[ ! "$EVENT_NAME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    # Name came from the command line without a date — add one.
    EVENT_NAME="${prefix}${EVENT_NAME}"
  fi
  # Trim leading/trailing whitespace (the date prefix ends in a space).
  EVENT_NAME="${EVENT_NAME#"${EVENT_NAME%%[![:space:]]*}"}"
  EVENT_NAME="${EVENT_NAME%"${EVENT_NAME##*[![:space:]]}"}"
  [[ -z "$EVENT_NAME" ]] && _cli_die "Album name cannot be empty"

  RAWS=(); JPEGS=(); OTHERS=()
  local folder
  for folder in "${SELECTED_FOLDERS[@]}"; do
    importer_collect "$folder" \
      "$(config_profile_raw_exts "$CAMERA_PROFILE")" \
      "$(config_profile_jpg_exts "$CAMERA_PROFILE")"
  done

  local raw_bytes=0 jpg_bytes=0 total_bytes total_count
  (( ${#RAWS[@]}  > 0 )) && raw_bytes=$(importer_sum_size  "${RAWS[@]}") || true
  (( ${#JPEGS[@]} > 0 )) && jpg_bytes=$(importer_sum_size "${JPEGS[@]}") || true
  (( total_bytes = raw_bytes + jpg_bytes )) || true
  (( total_count = ${#RAWS[@]} + ${#JPEGS[@]} + ${#OTHERS[@]} )) || true

  local split; split=$(config_profile_split "$CAMERA_PROFILE")
  local outdir; outdir=$(config_profile_outdir "$CAMERA_PROFILE")
  local dest_base="$outdir/$EVENT_NAME"

  _cli_hdr "Import Plan"
  printf "  ${BOLD}Event:${RESET}   %s\n" "$EVENT_NAME"
  printf "  ${BOLD}Camera:${RESET}  %s\n" "$(config_profile_name "$CAMERA_PROFILE")"
  printf "  ${BOLD}Output:${RESET}  %s/\n\n" "$dest_base"
  (( ${#RAWS[@]}  > 0 )) && printf "  ${BOLD}raws/${RESET}   %d files  %s\n" "${#RAWS[@]}"  "$(importer_human_size "$raw_bytes")"
  (( ${#JPEGS[@]} > 0 )) && printf "  ${BOLD}jpgs/${RESET}   %d files  %s\n" "${#JPEGS[@]}" "$(importer_human_size "$jpg_bytes")"
  printf "\n  ${BOLD}Total:${RESET}   %d files  %s\n" "$total_count" "$(importer_human_size "$total_bytes")"

  if (( total_count == 0 )); then _cli_warn "No files to import"; return; fi
  if $DRY_RUN; then echo; _cli_warn "Dry run — nothing copied"; return; fi

  echo
  [[ -d "$dest_base" ]] && _cli_info "Appending to existing event folder"
  printf "Proceed? [y/N] "; read -r confirm
  [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" == "y" ]] \
    || { _cli_info "Aborted"; return; }

  _cli_hdr "Copying"
  local total_copied=0 total_skipped=0 c s

  if [[ "$split" == "true" ]]; then
    if (( ${#RAWS[@]} > 0 )); then
      printf "  raws/  ..."; IFS=' ' read -r c s <<< "$(importer_copy_files "$dest_base/raws" "${RAWS[@]}")"
      (( total_copied += c, total_skipped += s )) || true
      printf "\r  raws/  ${GREEN}done${RESET}  (%d copied, %d skipped)\n" "$c" "$s"
    fi
    if (( ${#JPEGS[@]} > 0 )); then
      printf "  jpgs/  ..."; IFS=' ' read -r c s <<< "$(importer_copy_files "$dest_base/jpgs" "${JPEGS[@]}")"
      (( total_copied += c, total_skipped += s )) || true
      printf "\r  jpgs/  ${GREEN}done${RESET}  (%d copied, %d skipped)\n" "$c" "$s"
    fi
  else
    local -a all_files=()
    (( ${#RAWS[@]}   > 0 )) && all_files+=("${RAWS[@]}")
    (( ${#JPEGS[@]}  > 0 )) && all_files+=("${JPEGS[@]}")
    (( ${#OTHERS[@]} > 0 )) && all_files+=("${OTHERS[@]}")
    if (( ${#all_files[@]} > 0 )); then
      printf "  Copying ..."; IFS=' ' read -r c s <<< "$(importer_copy_files "$dest_base" "${all_files[@]}")"
      (( total_copied += c, total_skipped += s )) || true
      printf "\r  ${GREEN}done${RESET}  (%d copied, %d skipped)\n" "$c" "$s"
    fi
  fi

  echo
  _cli_ok "${BOLD}Complete!${RESET}  $total_copied copied  •  $total_skipped already existed"
  printf "  ${DIM}%s${RESET}\n" "$dest_base"
}

# ── Entry point ───────────────────────────────────────────────────────────────
run_cli() {
  EVENT_NAME="" DRY_RUN=false IMPORT_ALL=false FORCE_VOLUME="" DCIM_FOLDER="" CULL_JPGS=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)  DRY_RUN=true; shift ;;
      -a|--all)      IMPORT_ALL=true; shift ;;
      --cull-jpgs)   CULL_JPGS=true; shift ;;
      -v|--volume)   FORCE_VOLUME="$2"; shift 2 ;;
      -f|--folder)   DCIM_FOLDER="$2"; shift 2 ;;
      --terminal)    shift ;;
      -h|--help)     show_help; exit 0 ;;
      -*)            printf "Unknown option: %s\n" "$1" >&2; shift ;;
      *)             EVENT_NAME="$*"; break ;;
    esac
  done

  config_load
  if $CULL_JPGS; then _cli_run_cull
  else                _cli_run_import
  fi
}
