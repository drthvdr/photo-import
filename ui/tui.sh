#!/usr/bin/env bash
# =============================================================================
# tui.sh — The interactive terminal UI, powered by gum.
#
# What this file does, top to bottom:
#   1. Small helpers:  exit-confirm, graceful shutdown on SIGHUP/TERM,
#                      auto-close of the Terminal.app window on clean exit,
#                      the "✓ chose:" persistent line, section header rule,
#                      OSC 0 terminal-title setter
#   2. Dashboard render (SD Card + Library widgets with a percent loader
#      while the slow library scan runs in the background)
#   3. Interactive pickers (SD card / camera / DCIM folders / event name)
#   4. Import plan preview and copy loop
#   5. Cull scanner (finds RAW/JPG count mismatches) + per-event cull
#   6. Entry point (run_tui): argument parsing, trap install, the main
#      "pick mode -> run mode -> ask again?" loop
#
# Requires: gum installed, and every file under lib/ already sourced.
# =============================================================================

# ── Internal helpers ──────────────────────────────────────────────────────────

# Exit-confirm prompt. Called from any cancel path (picker Esc/Ctrl-C, empty
# input, SIGINT). If the user confirms, the app exits; otherwise control
# returns to the caller so it can retry.
# Positive-confirm wrapper: all non-destructive Yes/No dialogs get ✓ / ✗
# button labels so the intent is immediately readable at a glance. Every
# `gum confirm` in the app funnels through this except the cull delete
# prompt, which uses save/trash icons (see _tui_cull_one_event).
_tui_confirm() {
  # Darker purple (60) for the selected-button background instead of gum's
  # default pink-purple (212), so it matches the rest of the app's palette.
  gum confirm --affirmative="✓ Yes" --negative="✗ No" \
    --selected.background=60 \
    --selected.foreground=231 \
    "$@"
}

_tui_confirm_exit() {
  echo
  if _tui_confirm --default=No "Exit Photo Import?"; then
    exit 0
  fi
}

# Silent graceful shutdown. Called on SIGHUP (terminal window closed) and
# SIGTERM (killed by another process). Suppress every other trap first so
# we don't recurse, silence stdout/stderr so half-buffered writes don't
# splash errors after the tty is gone, and only kill actual jobs we own
# (not the whole process group, which would signal ourselves).
_tui_graceful_shutdown() {
  trap '' HUP TERM INT EXIT
  set +e
  local pid
  for pid in $(jobs -p 2>/dev/null); do
    kill -TERM "$pid" 2>/dev/null
  done
  stty sane 2>/dev/null
  tput cnorm 2>/dev/null
  exec >/dev/null 2>&1
  exit 0
}

# EXIT trap: on any clean exit, close the Terminal.app window we're
# running in. Only fires when Terminal.app is the current terminal —
# other emulators (iTerm, VSCode, ssh) are left alone. All errors are
# swallowed since the terminal may already be gone (e.g. user clicked
# the red X and this fires after SIGHUP cleanup).
_tui_on_exit() {
  local rc=$?
  if (( rc == 0 )) && [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]]; then
    ( osascript -e 'tell application "Terminal" to close front window saving no' \
        >/dev/null 2>&1 & ) 2>/dev/null
  fi
  return "$rc"
}

# Persistent "chosen" line — stays in scrollback so previous selections
# remain visible as the flow progresses.
_tui_chose() {
  local label="$1" value="$2"
  printf "  ${THEME_GREEN}✓${THEME_RST}  ${THEME_LABEL}%s${THEME_RST}  ${THEME_VALUE}%s${THEME_RST}\n" \
    "$label" "$value"
}

# Section title bar — a themed horizontal rule with a title on the left.
# Because gum choose / gum input can't be wrapped in a real box (they own
# their own rendering), a horizontal rule "opens" the section and the
# green ✓ chose-line below visually closes it.
#
#   ── Select Camera ──────────────────────────────────
#
# Optional 2nd arg picks a color palette:
#   ""     (default) — purple (main app theme)
#   green            — green rule + green title  (config mode)
#   red              — red rule + yellow title   (cull mode, if wanted)
_tui_section_header() {
  local title="$1" mode="${2:-}"
  local tw; tw=$(dash_term_width)
  (( tw > 100 )) && tw=100
  local w=$(( tw - 4 ))
  local tlen=${#title}
  local right=$(( w - 4 - tlen ))
  (( right < 2 )) && right=2
  local rs; rs=$(_dash_hline "$right")
  local border label
  case "$mode" in
    green) border=$'\033[38;5;82m';  label=$'\033[38;5;82m'  ;;
    red)   border=$'\033[38;5;196m'; label=$'\033[38;5;220m' ;;
    *)     border="$THEME_BORDER";   label="$THEME_LABEL"    ;;
  esac
  echo
  printf "  %s──%s %s%s%s%s %s%s%s\n" \
    "$border" "$THEME_RST" \
    "$label" "$THEME_BOLD" "$title" "$THEME_RST" \
    "$border" "$rs" "$THEME_RST"
}

# Set the terminal window + tab title via OSC 0/1/2. We always want the
# session name to read exactly "Photo Import" — the caller's argument is
# ignored on purpose so mode/subflow suffixes ("— Culling", "— Setup") no
# longer bleed into the title bar. If Terminal.app's window title still
# shows extra stuff (user, size, active process) that's the user's
# Profile settings under Preferences → Profiles → Window → Title.
_tui_set_title() {
  # OSC 2 = window title only; keeping OSC 0 as well for tab strip.
  printf '\033]0;Photo Import\007\033]2;Photo Import\007'
}


_tui_header() {
  _tui_set_title "Photo Import"
  echo
}

# Renders the top dashboard row: SD Card | Library.
# The widget row is 4 chars narrower than the header and indented 2 chars
# so the header visually contains the widgets.
_tui_dashboard() {
  local tw; tw=$(dash_term_width)
  (( tw > 100 )) && tw=100
  local gap=2
  local inner_w=$(( tw - 4 ))
  local avail=$(( inner_w - gap ))
  local w1=$(( avail / 2 ))
  local w2=$(( avail - w1 ))
  (( w1 < 28 )) && w1=28
  (( w2 < 28 )) && w2=28

  local spec_sd; spec_sd=$(dash_widget_sdcard "$SD_PATH" "$w1")

  # The library widget is the slow one — it walks every camera outdir with
  # `du -sk` and `find`. Run it in the background while a fake progress
  # counter ticks upward for visual feedback. Clear the loader once done.
  local tmp; tmp=$(mktemp)
  ( dash_widget_library "$w2" > "$tmp" ) &
  local pid=$!

  local pct=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${THEME_MUTED}Reading library${THEME_RST}  ${THEME_GREEN}%3d%%${THEME_RST}" "$pct"
    sleep 0.1
    pct=$(( pct + 4 ))
    (( pct > 95 )) && pct=90    # asymptote until the background job finishes
  done
  wait "$pid" 2>/dev/null || true
  printf "\r\033[K"             # clear the loader line so it disappears cleanly

  local spec_lib; spec_lib=$(< "$tmp")
  rm -f "$tmp"

  dash_render_row "$gap" "$spec_sd" "$spec_lib" | sed 's/^/  /'
  echo
}

_tui_pick_card() {
  local -a cards=()
  while IFS= read -r c; do cards+=("$c"); done < <(sdcard_find)
  case ${#cards[@]} in
    0) _tui_pick_card_manual ;;   # nothing auto-detected → prompt for a path
    1) SD_PATH="${cards[0]}" ;;
    *)
      while true; do
        SD_PATH=$(printf '%s\n' "${cards[@]}" | gum choose --header "Select SD card:")
        [[ -n "$SD_PATH" ]] && break
        _tui_confirm_exit
      done
      ;;
  esac
}

# Fallback when sdcard_find returns no /Volumes/*/DCIM matches — the user
# might have unmounted the card, dropped a folder onto their disk, or be
# importing from a backup. Offer them the native macOS folder picker
# (like a browser's "choose file" dialog) with a typed-path fallback.
_tui_pick_card_manual() {
  echo
  gum log --level warn "No SD card auto-detected (no /Volumes/*/DCIM found)"

  while true; do
    local action
    action=$(gum choose --header "Where should photo-import look?" \
      --cursor "▶ " --cursor.foreground 177 \
      "Pick a folder in Finder" \
      "Type a path" \
      "Cancel") || action="Cancel"

    case "$action" in
      "Pick a folder in Finder")
        # Native macOS folder chooser via osascript. Empty on cancel.
        local picked
        picked=$(osascript -e 'POSIX path of (choose folder with prompt "Select SD card or folder containing DCIM")' 2>/dev/null)
        picked="${picked%/}"
        _tui_accept_card_path "$picked" && break
        ;;
      "Type a path")
        local typed
        typed=$(gum input --header "Path to the SD card or a folder containing DCIM" \
          --placeholder "/Volumes/UNTITLED  or  /Users/you/Backups/2026-09-06" \
          --width 60)
        typed="${typed%/}"
        _tui_accept_card_path "$typed" && break
        ;;
      *)
        _tui_confirm_exit
        ;;
    esac
  done
}

# Validate that <path> looks like an SD-card root or a DCIM folder and,
# if so, set SD_PATH. Returns 0 on success, 1 to re-prompt. If the user
# picked the DCIM folder itself we walk up to its parent so downstream
# code (which expects <root>/DCIM) works unchanged.
_tui_accept_card_path() {
  local p="$1"
  [[ -z "$p" ]] && return 1
  if [[ ! -d "$p" ]]; then
    gum log --level warn "Not a directory: $p"
    return 1
  fi
  # If they picked the DCIM folder itself, back up one level.
  if [[ "$(basename "$p")" == "DCIM" ]]; then
    p="$(dirname "$p")"
  fi
  if [[ ! -d "$p/DCIM" ]]; then
    gum log --level warn "$p has no DCIM subdirectory — try another folder"
    return 1
  fi
  SD_PATH="$p"
  return 0
}

_tui_pick_camera() {
  local -a match_idxs=()
  while IFS= read -r idx; do match_idxs+=("$idx"); done \
    < <(sdcard_matching_profile_indices "$SD_PATH/DCIM")

  # Unambiguous match — auto-select silently.
  if (( ${#match_idxs[@]} == 1 )); then
    CAMERA_PROFILE="${PROFILES[${match_idxs[0]}]}"
    _tui_chose "Camera:" "$(config_profile_name "$CAMERA_PROFILE")"
    return
  fi

  # Build candidate list (matching profiles, or all if none matched)
  local -a candidates=()
  if (( ${#match_idxs[@]} > 1 )); then
    local idx; for idx in "${match_idxs[@]}"; do candidates+=("${PROFILES[$idx]}"); done
  else
    candidates=("${PROFILES[@]}")
  fi

  local -a labels=()
  local p
  for p in "${candidates[@]}"; do
    labels+=("$(printf '%-22s  %s' "$(config_profile_name "$p")" "$(config_profile_outdir "$p")")")
  done

  _tui_section_header "Select Camera"
  local chosen
  while true; do
    chosen=$(printf '%s\n' "${labels[@]}" \
      | gum choose --header "" \
          --cursor "▶ " \
          --cursor.foreground 177)
    [[ -n "$chosen" ]] && break
    _tui_confirm_exit
  done

  local i
  for i in "${!labels[@]}"; do
    [[ "${labels[$i]}" == "$chosen" ]] && { CAMERA_PROFILE="${candidates[$i]}"; break; }
  done
  _tui_chose "Camera:" "$(config_profile_name "$CAMERA_PROFILE")"
}

_tui_pick_folders() {
  local -a all_folders=()
  while IFS= read -r d; do [[ -n "$d" ]] && all_folders+=("$d"); done \
    < <(sdcard_dcim_folders "$SD_PATH")
  [[ ${#all_folders[@]} -eq 0 ]] && { gum log --level error "No folders in $SD_PATH/DCIM"; exit 1; }

  SELECTED_FOLDERS=()

  # --all or --folder bypass the picker
  if $IMPORT_ALL; then
    SELECTED_FOLDERS=("${all_folders[@]}")
    _tui_chose "Folders:" "all ${#all_folders[@]}"
    return
  fi
  if [[ -n "$DCIM_FOLDER" ]]; then
    local target="$SD_PATH/DCIM/$DCIM_FOLDER"
    [[ -d "$target" ]] || { gum log --level error "Folder '$DCIM_FOLDER' not found in $SD_PATH/DCIM"; exit 1; }
    SELECTED_FOLDERS=("$target")
    _tui_chose "Folder: " "$DCIM_FOLDER"
    return
  fi
  if (( ${#all_folders[@]} == 1 )); then
    SELECTED_FOLDERS=("${all_folders[0]}")
    _tui_chose "Folder: " "$(basename "${all_folders[0]}")"
    return
  fi

  echo
  _tui_pick_folders_grid "${all_folders[@]}"

  local count=${#SELECTED_FOLDERS[@]}
  if (( count == 1 )); then
    _tui_chose "Folder: " "$(basename "${SELECTED_FOLDERS[0]}")"
  else
    local names=""
    local f
    for f in "${SELECTED_FOLDERS[@]}"; do
      [[ -n "$names" ]] && names+=", "
      names+="$(basename "$f")"
    done
    _tui_chose "Folders:" "$count  ($names)"
  fi
}

_tui_get_event_name() {
  # Album names follow the "YYYY-MM-DD Description" convention. The date
  # prefix comes from the selected DCIM folders; the user types the rest.
  #   • no CLI name     -> pre-fill just the date prefix ("2026-09-05 ")
  #   • CLI name given  -> use it, adding the date prefix unless it
  #                        already starts with an ISO date
  local prefix="" default="$EVENT_NAME"
  (( ${#SELECTED_FOLDERS[@]} > 0 )) && \
    prefix=$(sdcard_event_name_from_folders "${SELECTED_FOLDERS[@]}")

  if [[ -z "$default" ]]; then
    default="$prefix"
  elif [[ ! "$default" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    default="${prefix}${default}"
  fi

  _tui_section_header "Album Name"
  while true; do
    EVENT_NAME=$(gum input \
      --value "$default" \
      --placeholder "e.g. 2026-09-05 Cougar Crest Trail" \
      --cursor.foreground 177 \
      --width 60)
    # Trim stray leading/trailing spaces (the pre-filled date ends in one).
    EVENT_NAME="${EVENT_NAME#"${EVENT_NAME%%[![:space:]]*}"}"
    EVENT_NAME="${EVENT_NAME%"${EVENT_NAME##*[![:space:]]}"}"
    [[ -n "$EVENT_NAME" ]] && break
    _tui_confirm_exit
  done
  _tui_chose "Album:  " "$EVENT_NAME"
}

# ── Folder picker ─────────────────────────────────────────────────────────────
# Uses gum choose --no-limit. Newest folder first, pre-selected. No custom
# terminal handling — gum owns the input.
_tui_pick_folders_grid() {
  # Reverse input so newest folders come first in the picker.
  local -a in=("$@")
  local -a all=()
  local i
  for (( i = ${#in[@]} - 1; i >= 0; i-- )); do all+=("${in[$i]}"); done

  local -a labels=()
  for i in "${!all[@]}"; do
    local name; name=$(basename "${all[$i]}")
    local d; d=$(sdcard_folder_date_label "${all[$i]}")
    d="${d#(}"; d="${d%)}"
    [[ "$d" =~ ^[A-Za-z]{3}[[:space:]](.+)$ ]] && d="${BASH_REMATCH[1]}"
    local cnt; cnt=$(ls -1 "${all[$i]}" 2>/dev/null | wc -l | tr -d ' ')
    local _lbl
    printf -v _lbl '%-10s  %-14s  %s images' "$name" "${d:- }" "$cnt"
    labels[$i]="$_lbl"
  done

  local newest="${labels[0]}"
  local chosen
  _tui_section_header "Select Folders  ·  x to toggle  ·  enter to confirm"

  # Loop until at least one folder is selected. Enter with nothing checked
  # simply re-opens the picker (the newest folder stays pre-selected).
  local pre_selected="$newest"
  while true; do
    if ! chosen=$(printf '%s\n' "${labels[@]}" \
      | gum choose --no-limit --header "" \
          --cursor "▶ " \
          --selected-prefix "✓ " \
          --unselected-prefix "  " \
          --cursor-prefix "  " \
          --selected.foreground 82 \
          --cursor.foreground 177 \
          --selected="$pre_selected")
    then
      _tui_confirm_exit
      continue
    fi

    SELECTED_FOLDERS=()
    if [[ -n "$chosen" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        for i in "${!labels[@]}"; do
          if [[ "${labels[$i]}" == "$line" ]]; then
            SELECTED_FOLDERS+=("${all[$i]}")
            break
          fi
        done
      done <<< "$chosen"
    fi

    (( ${#SELECTED_FOLDERS[@]} > 0 )) && break
    gum log --level warn "Select at least one folder (x toggles)"
  done
}

_tui_show_import_plan() {
  local dest_base="$1" raw_count="$2" raw_bytes="$3" jpg_count="$4" jpg_bytes="$5"
  local total_count="$6" total_bytes="$7"

  local append_note=""
  [[ -d "$dest_base" ]] && append_note="  $(gum style --faint "(appending)")"

  local body=""
  body+="  $(gum style --faint "Camera: ")$(config_profile_name "$CAMERA_PROFILE")\n"
  body+="  $(gum style --faint "Output: ")$dest_base/${append_note}\n"
  body+="\n"
  (( raw_count > 0 )) && body+="$(printf '  %-8s %d files   %s\n' "raws/" "$raw_count" "$(importer_human_size "$raw_bytes")")\n"
  (( jpg_count > 0 )) && body+="$(printf '  %-8s %d files   %s\n' "jpgs/" "$jpg_count" "$(importer_human_size "$jpg_bytes")")\n"
  body+="\n"
  body+="$(printf '  %-8s %d files   %s\n' "Total" "$total_count" "$(importer_human_size "$total_bytes")")"

  echo
  gum style \
    --border rounded --border-foreground 212 \
    --padding "0 1" \
    "  $(gum style --foreground 212 --bold "$EVENT_NAME")" \
    "$(printf '%b' "$body")"
  echo
}

_tui_copy_group() {
  local dest="$1" label="$2"; shift 2
  local -a files=("$@")
  (( ${#files[@]} == 0 )) && { LAST_COPIED=0; LAST_SKIPPED=0; return; }

  local tmp_list tmp_result
  tmp_list=$(mktemp); tmp_result=$(mktemp)
  printf '%s\0' "${files[@]}" > "$tmp_list"
  mkdir -p "$dest"

  DEST="$dest" TMP_LIST="$tmp_list" TMP_RESULT="$tmp_result" \
  gum spin --spinner dot \
    --title "Copying $label (${#files[@]} files)..." -- \
    bash -c '
      copied=0; skipped=0
      while IFS= read -r -d "" f; do
        fname=$(basename "$f")
        if [[ -f "$DEST/$fname" ]]; then (( skipped++ )) || true
        else cp "$f" "$DEST/$fname"; (( copied++ )) || true
        fi
      done < "$TMP_LIST"
      printf "%s %s" "$copied" "$skipped" > "$TMP_RESULT"
    '

  LAST_COPIED=0; LAST_SKIPPED=0
  [[ -f "$tmp_result" ]] && read -r LAST_COPIED LAST_SKIPPED < "$tmp_result" 2>/dev/null || true
  LAST_COPIED=${LAST_COPIED:-0}; LAST_SKIPPED=${LAST_SKIPPED:-0}
  rm -f "$tmp_list" "$tmp_result"
}

# ── Cull flow ─────────────────────────────────────────────────────────────────

# Walk every configured camera outdir and print a "count-mismatched" event
# spec per line: "<event_dir>|<raw_count>|<jpg_count>". Only events whose
# raw and jpg counts differ are emitted (that's the set worth culling).
_tui_scan_mismatches() {
  local p
  for p in "${PROFILES[@]}"; do
    local base; base=$(config_profile_outdir "$p")
    [[ -d "$base" ]] || continue
    local rex; rex=$(config_profile_raw_exts "$p")
    local jex; jex=$(config_profile_jpg_exts "$p")
    local ev
    while IFS= read -r ev; do
      [[ -n "$ev" ]] || continue
      local rc jc
      rc=$(importer_count_by_ext_csv "$ev" "$rex")
      jc=$(importer_count_by_ext_csv "$ev" "$jex")
      if (( rc != jc )); then
        printf '%s|%d|%d\n' "$ev" "$rc" "$jc"
      fi
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
  done
}

_tui_run_cull() {
  # Scan for events whose RAW and JPG counts differ. Show a loader — the
  # scan walks every camera library and can take a few seconds.
  local tmp; tmp=$(mktemp)
  ( _tui_scan_mismatches > "$tmp" ) &
  local pid=$!
  local pct=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${THEME_MUTED}Scanning libraries for mismatches${THEME_RST}  ${THEME_GREEN}%3d%%${THEME_RST}" "$pct"
    sleep 0.1
    pct=$(( pct + 4 ))
    (( pct > 95 )) && pct=90
  done
  wait "$pid" 2>/dev/null || true
  printf "\r\033[K"

  local -a event_dirs=() rcs=() jcs=() labels=()
  local line
  while IFS='|' read -r ev rc jc; do
    [[ -z "$ev" ]] && continue
    event_dirs+=("$ev")
    rcs+=("$rc"); jcs+=("$jc")
    local nm; nm=$(basename "$ev")
    local diff=$(( jc - rc ))
    local _lbl
    printf -v _lbl '%-40s  RAW %-5d  JPG %-5d  diff %+d' "$nm" "$rc" "$jc" "$diff"
    labels+=("$_lbl")
  done < "$tmp"
  rm -f "$tmp"

  if (( ${#event_dirs[@]} == 0 )); then
    gum log --level info "No folders with RAW/JPG mismatches — nothing to cull"
    return
  fi

  # Cull mode gets warning-tinted picker (red cursor, yellow items) so the
  # destructive nature of this section is obvious at a glance. Multi-select
  # so the user can cull several events in one pass.
  _tui_section_header "Select Events to Cull  ·  ${#event_dirs[@]} with mismatches  ·  x to toggle  ·  enter to confirm" red
  local chosen
  local pre_selected="${labels[0]}"
  while true; do
    if ! chosen=$(printf '%s\n' "${labels[@]}" \
      | gum choose --no-limit --header "" \
          --cursor "▶ " \
          --selected-prefix "✓ " \
          --unselected-prefix "  " \
          --cursor-prefix "  " \
          --selected.foreground 220 \
          --cursor.foreground 196 \
          --item.foreground 196 \
          --selected="$pre_selected")
    then
      _tui_confirm_exit
      continue
    fi

    local -a picked_dirs=()
    if [[ -n "$chosen" ]]; then
      local line i
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        for i in "${!labels[@]}"; do
          if [[ "${labels[$i]}" == "$line" ]]; then
            picked_dirs+=("${event_dirs[$i]}")
            break
          fi
        done
      done <<< "$chosen"
    fi

    (( ${#picked_dirs[@]} > 0 )) && break
    gum log --level warn "Select at least one event (x toggles)"
  done

  local n=${#picked_dirs[@]}
  _tui_chose "Events: " "$n selected"

  # Cull each selected event in turn. `|| true` on the per-event call so
  # `set -e` can't turn a skipped/errored single event into an early exit
  # from the whole batch — every picked event should get its own prompt.
  local idx=1 ev
  for ev in "${picked_dirs[@]}"; do
    echo
    gum style --faint "──  [$idx/$n]  $(basename "$ev")"
    _tui_cull_one_event "$ev" || true
    idx=$(( idx + 1 ))
  done
}

# Cull a single event directory: find orphaned JPGs, show plan, confirm,
# delete. Handles dry-run and skips cleanly if nothing to remove.
_tui_cull_one_event() {
  local event_dir="$1"
  local event_name; event_name=$(basename "$event_dir")

  # Find the profile whose outdir contains this event so we know which
  # extensions count as RAW vs JPEG. Falls back to legacy raws/+jpgs/
  # subdirs if no matching profile is found (shouldn't happen).
  local rex="" jex=""
  local prof outdir
  for prof in "${PROFILES[@]}"; do
    outdir=$(config_profile_outdir "$prof")
    if [[ "$event_dir" == "$outdir/"* ]]; then
      rex=$(config_profile_raw_exts "$prof")
      jex=$(config_profile_jpg_exts "$prof")
      break
    fi
  done

  culler_find_orphans "$event_dir" "$rex" "$jex"

  # Count files by extension using the same source-of-truth as the
  # mismatch scanner, so what the user saw in the picker matches what
  # gets reported here.
  local total_jpgs raw_count orphan_bytes
  raw_count=$(importer_count_by_ext_csv "$event_dir" "$rex")
  total_jpgs=$(importer_count_by_ext_csv "$event_dir" "$jex")
  orphan_bytes=0
  (( ${#ORPHAN_JPEGS[@]} > 0 )) && orphan_bytes=$(importer_sum_size "${ORPHAN_JPEGS[@]}") || true

  local body
  body="$(printf '  %-20s %s\n' "RAWs kept:"     "$raw_count")"
  body+=$'\n'"$(printf '  %-20s %s\n' "JPGs total:"    "$total_jpgs")"
  body+=$'\n'"$(printf '  %-20s %s\n' "Orphaned JPGs:" "${#ORPHAN_JPEGS[@]}")"
  (( ${#ORPHAN_JPEGS[@]} > 0 )) && \
    body+=$'\n'"$(printf '  %-20s %s\n' "Space to free:" "$(importer_human_size "$orphan_bytes")")"

  echo
  gum style --border rounded --border-foreground 220 --padding "0 1" \
    "  $(gum style --foreground 220 --bold "Cull — $event_name")" \
    "$body"
  echo

  if (( ${#ORPHAN_JPEGS[@]} == 0 )); then
    gum log --level info "Nothing to cull — all JPGs have a matching RAW"
    return
  fi

  if $DRY_RUN; then
    gum style --faint "Would delete:"
    printf '  %s\n' "${ORPHAN_JPEGS[@]##*/}"
    echo; gum log --level warn "Dry run — nothing deleted"
    return
  fi

  # Danger callout — summary line, then the confirm prompt with
  # icon-labelled buttons so the intent of each button is obvious:
  #
  #     DELETE 265 FILES (1.8 GB)
  #     Delete 265 orphaned JPGs from Cougar Crest Trail?
  #           [ 💾 No ]   [ 🗑️ Yes ]
  echo
  gum style --foreground 196 --bold --align center --width 60 \
    "DELETE ${#ORPHAN_JPEGS[@]} FILES ($(importer_human_size "$orphan_bytes"))"
  gum confirm --default=No \
    --prompt.foreground 220 \
    --selected.background 196 \
    --selected.foreground 230 \
    --unselected.foreground 254 \
    --affirmative="🗑️ Yes" \
    --negative="💾 No" \
    "Delete ${#ORPHAN_JPEGS[@]} orphaned JPGs from $event_name?" \
    || { gum log --level warn "Skipped $event_name"; return; }

  local tmp_list; tmp_list=$(mktemp)
  printf '%s\0' "${ORPHAN_JPEGS[@]}" > "$tmp_list"

  TMP_LIST="$tmp_list" \
  gum spin --spinner dot --title "Removing ${#ORPHAN_JPEGS[@]} files..." -- \
    bash -c 'while IFS= read -r -d "" f; do rm "$f"; done < "$TMP_LIST"'
  rm -f "$tmp_list"

  gum log --level info "Done!  ${#ORPHAN_JPEGS[@]} JPGs removed  •  $(importer_human_size "$orphan_bytes") freed"
  gum style --faint "  $event_dir/jpgs"
}

# ── Import flow ───────────────────────────────────────────────────────────────

_tui_run_import() {
  [[ -n "$FORCE_VOLUME" ]] && SD_PATH="$FORCE_VOLUME" || { SD_PATH=""; _tui_pick_card; }
  _tui_dashboard
  CAMERA_PROFILE=""; _tui_pick_camera
  SELECTED_FOLDERS=(); _tui_pick_folders
  _tui_get_event_name
  echo

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

  _tui_show_import_plan "$dest_base" \
    "${#RAWS[@]}" "$raw_bytes" "${#JPEGS[@]}" "$jpg_bytes" \
    "$total_count" "$total_bytes"

  if (( total_count == 0 )); then gum log --level warn "No files to import"; return; fi

  if $DRY_RUN; then gum log --level warn "Dry run — nothing copied"; return; fi

  local confirm_msg="Import $total_count files ($(importer_human_size "$total_bytes"))?"
  [[ -d "$dest_base" ]] && confirm_msg="Append to '$EVENT_NAME'  •  $total_count files ($(importer_human_size "$total_bytes"))?"
  _tui_confirm "$confirm_msg" || { gum log --level warn "Cancelled"; return; }
  echo

  local total_copied=0 total_skipped=0 LAST_COPIED=0 LAST_SKIPPED=0

  if [[ "$split" == "true" ]]; then
    _tui_copy_group "$dest_base/raws" "RAW"  "${RAWS[@]+"${RAWS[@]}"}"
    (( total_copied += LAST_COPIED, total_skipped += LAST_SKIPPED )) || true

    _tui_copy_group "$dest_base/jpgs" "JPEG" "${JPEGS[@]+"${JPEGS[@]}"}"
    (( total_copied += LAST_COPIED, total_skipped += LAST_SKIPPED )) || true
  else
    local -a all_files=()
    (( ${#RAWS[@]}   > 0 )) && all_files+=("${RAWS[@]}")
    (( ${#JPEGS[@]}  > 0 )) && all_files+=("${JPEGS[@]}")
    (( ${#OTHERS[@]} > 0 )) && all_files+=("${OTHERS[@]}")
    _tui_copy_group "$dest_base" "files" "${all_files[@]+"${all_files[@]}"}"
    (( total_copied += LAST_COPIED, total_skipped += LAST_SKIPPED )) || true
  fi

  echo
  gum log --level info "Done!  $total_copied copied  •  $total_skipped already existed"
  gum style --faint "  $dest_base"
}

# Ask whether to import another event. Returns 0 = yes, 1 = no.
_tui_ask_another() {
  echo
  _tui_confirm "Do another action?"
}

# ── Entry point ───────────────────────────────────────────────────────────────

run_tui() {
  EVENT_NAME="" DRY_RUN=false IMPORT_ALL=false FORCE_VOLUME="" DCIM_FOLDER="" CULL_JPGS=false
  local CONFIG_DRY_RUN=false CONFIG_UPDATE=false CONFIG_UPDATE_DRY_RUN=false CONFIG_RESET=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)             DRY_RUN=true; shift ;;
      -a|--all)                 IMPORT_ALL=true; shift ;;
      --cull-jpgs)              CULL_JPGS=true; shift ;;
      -v|--volume)              FORCE_VOLUME="$2"; shift 2 ;;
      -f|--folder)              DCIM_FOLDER="$2"; shift 2 ;;
      --config-dry-run)         CONFIG_DRY_RUN=true; shift ;;
      --config-update)          CONFIG_UPDATE=true; shift ;;
      --config-update-dry-run)  CONFIG_UPDATE_DRY_RUN=true; shift ;;
      --config-reset)           CONFIG_RESET=true; shift ;;
      -h|--help)                shift ;;
      --terminal)               shift ;;
      -*)                       gum log --level warn "Unknown flag: $1"; shift ;;
      *)                        EVENT_NAME="$*"; break ;;
    esac
  done

  # Ctrl-C prompts for confirmation; closing the terminal window (SIGHUP)
  # or an external kill (SIGTERM) exits silently and cleanly. On any
  # clean exit (rc == 0) we also close the Terminal.app window we're in.
  trap '_tui_confirm_exit' INT
  trap '_tui_graceful_shutdown' HUP TERM
  trap '_tui_on_exit' EXIT

  _tui_header

  # Config setup routes — these run BEFORE config_load so they can create
  # the file it needs. All exit after the setup completes.
  #
  # The generic --dry-run / -n flag composes with each config command:
  #   --dry-run --config-update  ==  --config-update-dry-run
  #   --dry-run --config-reset   ==  simulate reset (no backup, no wipe, no write)
  #   --dry-run  (with no config flag but a config-triggering condition)
  #                              ==  simulate first-run fresh setup
  if $CONFIG_DRY_RUN || ( $DRY_RUN && ! $CONFIG_UPDATE && ! $CONFIG_UPDATE_DRY_RUN && ! $CONFIG_RESET && [[ ! -f "$CONFIG_FILE" ]] ); then
    _tui_set_title "Photo Import — Setup (dry-run)"
    config_interactive_setup dry-run
    return
  fi
  if $CONFIG_UPDATE_DRY_RUN || ( $CONFIG_UPDATE && $DRY_RUN ); then
    _tui_set_title "Photo Import — Setup (update dry-run)"
    config_interactive_setup update-dry-run
    return
  fi
  if $CONFIG_UPDATE; then
    _tui_set_title "Photo Import — Setup (update)"
    config_interactive_setup update
    return
  fi
  if $CONFIG_RESET && $DRY_RUN; then
    _tui_set_title "Photo Import — Setup (reset dry-run)"
    config_reset dry-run
    return
  fi
  if $CONFIG_RESET; then
    _tui_set_title "Photo Import — Setup (reset)"
    config_reset
    return
  fi

  # First-boot detection: no config file → run the interactive setup, then
  # continue into the main flow so the user goes straight from setup to import.
  if [[ ! -f "$CONFIG_FILE" ]]; then
    _tui_set_title "Photo Import — First-Run Setup"
    config_interactive_setup fresh || return 1
    _tui_set_title "Photo Import"
  fi

  config_load

  # Legacy CLI flag: --cull-jpgs jumps straight into cull mode.
  if $CULL_JPGS; then
    _tui_set_title "Photo Import — Culling"
    _tui_run_cull
    return
  fi

  # Main loop: pick mode (Import / Cull / Configure) → run it → ask
  # "another?" → repeat. Per-iteration state is reset each time so every
  # pass walks through the full interactive flow from scratch.
  #
  # Each mode row is wrapped in "button" padding. Colors intentionally
  # simple: gum choose's --selected.* styles the hovered row like a
  # filled button (purple bg, bright fg), same visual language as the
  # [ ✓ Yes ] / [ ✗ No ] confirm buttons. Non-hovered rows are muted so
  # the highlighted one really pops.
  local M_IMPORT='   📷   Import Photos from SD Card or File    '
  local M_CULL='   🗑️    Cull orphan JPGs       '
  local M_CONFIG='   ⚙️    Configure profiles     '

  while true; do
    local mode
    _tui_section_header "Mode"
    while true; do
      # gum choose returns:
      #   • non-zero  → user pressed Esc/Ctrl-C  → prompt exit
      #   • zero      → real selection            → break
      if ! mode=$(gum choose --header "" \
        --cursor "▶ " \
        --cursor.foreground 177 \
        --selected.foreground 231 \
        --selected.background 141 \
        --item.foreground 245 \
        "$M_IMPORT" "$M_CULL" "$M_CONFIG")
      then
        _tui_confirm_exit
        continue
      fi
      [[ -n "${mode// }" ]] && break
    done
    # Strip ANSI from the chose-line so the transcript is clean.
    local mode_plain
    mode_plain=$(printf '%s' "$mode" | sed $'s/\033\\[[0-9;]*m//g')
    _tui_chose "Mode:   " "$mode_plain"

    # `|| true` on each dispatch so a non-zero return from a mode function
    # (e.g. gum spin propagating a child rm's failure) doesn't get turned
    # into a script exit by `set -e`. The loop should always continue on
    # to the "Do another action?" prompt.
    case "$mode" in
      *"Cull orphan JPGs"*)
        _tui_set_title "Photo Import — Culling"
        _tui_run_cull || true
        ;;
      *"Configure profiles"*)
        _tui_set_title "Photo Import — Configure"
        config_interactive_setup update || true
        ;;
      *)
        _tui_set_title "Photo Import — Importing"
        _tui_run_import || true
        ;;
    esac
    # Return to the neutral title for the next iteration's mode picker.
    _tui_set_title "Photo Import"

    _tui_ask_another || break
    EVENT_NAME=""
    EVENT_DIR=""
    DCIM_FOLDER=""
    IMPORT_ALL=false
    CAMERA_PROFILE=""
    SELECTED_FOLDERS=()
    SD_PATH=""
  done
}
