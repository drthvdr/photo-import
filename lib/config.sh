#!/usr/bin/env bash
# =============================================================================
# config.sh — Camera profile storage and interactive setup.
#
# What lives here:
#   • The location of the config file (~/.config/photo-import/cameras.conf)
#   • Loading the file into memory (as the PROFILES[] array)
#   • Accessors for each of the 5 fields in a profile line
#   • Interactive setup flows for first-run, update, dry-run and reset
#
# One line in cameras.conf = one profile. Fields are separated by "|":
#
#   Name | raw_exts | jpeg_exts | split_folders | output_base_dir
#
# Blank ext fields are allowed:
#   • raw + jpg blank     -> profile is a catch-all (all files kept)
#   • only one blank      -> single-file-type source (scanner, phone, etc.)
# =============================================================================

# Where the config lives. Overridable via env for testing.
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/photo-import}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/cameras.conf}"

# Loaded profile lines in order. Populated by config_load.
PROFILES=()

# ------------------------------------------------------------------
# config_load
# ------------------------------------------------------------------
# Read cameras.conf into PROFILES[]. Blank lines and comments starting
# with # are ignored. If no config file exists, the first-run interactive
# setup is launched (via _config_create_default). Exits non-zero if the
# file exists but ends up empty (no valid profile lines).
config_load() {
  [[ ! -f "$CONFIG_FILE" ]] && _config_create_default
  PROFILES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue    # skip comments
    [[ -z "${line// }" ]] && continue              # skip blank lines
    PROFILES+=("$line")
  done < "$CONFIG_FILE"
  [[ ${#PROFILES[@]} -gt 0 ]] || { echo "No camera profiles found in $CONFIG_FILE" >&2; return 1; }
}

# ------------------------------------------------------------------
# Profile field accessors
# ------------------------------------------------------------------
# Each takes a full profile line ("Name|raw|jpg|split|dir") and prints
# one of the fields. Uses `read` with "|" as the delimiter to split.
config_profile_name()     { IFS='|' read -r v _ _ _ _ <<< "$1"; echo "$v"; }
config_profile_raw_exts() { IFS='|' read -r _ v _ _ _ <<< "$1"; echo "$v"; }
config_profile_jpg_exts() { IFS='|' read -r _ _ v _ _ <<< "$1"; echo "$v"; }
config_profile_split()    { IFS='|' read -r _ _ _ v _ <<< "$1"; echo "$v"; }
config_profile_outdir()   { IFS='|' read -r _ _ _ _ v <<< "$1"; echo "$v"; }

# Interactive first-run / update setup. Walks the user through adding camera
# profiles and writes them to CONFIG_FILE. Behavior modes:
#
#   config_interactive_setup            → write to CONFIG_FILE (creates dir)
#   config_interactive_setup dry-run    → print the file we WOULD write to
#                                         stdout; touch nothing on disk
#   config_interactive_setup update     → seed the setup with the existing
#                                         profiles (each shown as a chance
#                                         to keep, edit, or delete) and
#                                         write the result to CONFIG_FILE
#
# Requires `gum` on PATH (same as the rest of the TUI).
config_interactive_setup() {
  # Accepted modes:
  #   fresh              → interactive setup, write to CONFIG_FILE
  #   dry-run            → interactive setup, print result, no write
  #   update             → seed from existing config, write result
  #   update-dry-run     → seed from existing, print result, no write
  local mode="${1:-fresh}"
  local is_update=false is_dry_run=false
  case "$mode" in
    update)         is_update=true  ;;
    update-dry-run) is_update=true; is_dry_run=true ;;
    dry-run)        is_dry_run=true ;;
    fresh|"")       : ;;
    *) echo "Unknown setup mode: $mode" >&2; return 1 ;;
  esac

  local -a new_profiles=()

  # In update mode, seed from the existing file so the user can revise it.
  if $is_update && [[ -f "$CONFIG_FILE" ]]; then
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// }" ]] && continue
      new_profiles+=("$line")
    done < "$CONFIG_FILE"
  fi

  # Splash — themed section header so config mode looks like part of the
  # main UI, not a separate flow. Config sections use GREEN cursor + items
  # with BLUE checkmarks so you can tell at a glance you're in setup mode.
  _tui_section_header "Photo Import — Setup" green
  if $is_dry_run; then
    gum log --level warn "Dry run — nothing will be written to disk"
  fi
  if $is_update; then
    gum log --level info "Updating $CONFIG_FILE (${#new_profiles[@]} existing profile(s))"
  fi

  # Snapshot the on-disk config so we can detect "nothing changed" at
  # the end and skip the save prompt in that case.
  local -a original_profiles=("${new_profiles[@]+"${new_profiles[@]}"}")

  local ADD_LABEL="+ Add a new profile"

  # Note any orphan profiles (dir missing on disk) once so the user knows
  # why some rows are tagged "(missing)" in the picker.
  local -a orphan_names=()
  local q _out
  for q in "${new_profiles[@]+"${new_profiles[@]}"}"; do
    _out=$(config_profile_outdir "$q")
    [[ -d "$_out" ]] || orphan_names+=("$(config_profile_name "$q")")
  done
  if (( ${#orphan_names[@]} > 0 )); then
    echo
    gum log --level warn "${#orphan_names[@]} profile(s) have a missing output dir: ${orphan_names[*]}"
    gum log --level warn "(shown as '(missing)' in the picker — select one to fix its path or delete it)"
  fi

  # In fresh mode, jump straight into the add prompt so the user isn't
  # staring at a picker with only "Add a new profile" on it.
  if ! $is_update; then
    local new
    new=$(_config_prompt_profile "")
    [[ -n "$new" ]] && new_profiles+=("$new")
  fi

  # ── Multi-select picker (old style) ─────────────────────────────────
  # User checks every profile they want to edit + optionally
  # "+ Add a new profile", hits Enter, and the loop below queues each
  # picked action in order. Orphan (missing-dir) profiles ARE shown,
  # tagged "(missing)", so the user can pick them to fix or delete.
  # Skipped only when we're in update mode AND there's something to touch.
  if $is_update; then
    local -a labels=()
    local -a profile_idx=()
    local p _lbl _nm _rex _jex _o _tag i
    for i in "${!new_profiles[@]}"; do
      p="${new_profiles[$i]}"
      _nm=$(config_profile_name "$p")
      _rex=$(config_profile_raw_exts "$p"); _rex="${_rex:--}"
      _jex=$(config_profile_jpg_exts "$p"); _jex="${_jex:--}"
      _o=$(config_profile_outdir "$p")
      if [[ -d "$_o" ]]; then _tag=""; else _tag=" (missing)"; fi
      printf -v _lbl '%-30s  raw=%-14s  jpg=%-14s  split=%-6s  %s%s' \
        "$_nm" "$_rex" "$_jex" "$(config_profile_split "$p")" "$_o" "$_tag"
      labels+=("$_lbl")
      profile_idx+=("$i")
    done
    labels+=("$ADD_LABEL")

    echo
    _tui_section_header "Update / Add Profiles  ·  x to toggle  ·  enter to confirm" green
    local chosen
    if ! chosen=$(printf '%s\n' "${labels[@]}" \
      | gum choose --no-limit --header "" \
          --cursor "▶ " \
          --selected-prefix "✓ " \
          --unselected-prefix "  " \
          --cursor-prefix "  " \
          --cursor.foreground 82 \
          --selected.foreground 39 \
          --item.foreground 82)
    then
      chosen=""
    fi

    # Walk each picked line in the order the user gave. For a profile
    # label, edit that profile in place. For ADD_LABEL, prompt for one
    # new profile and append it.
    if [[ -n "$chosen" ]]; then
      local line li
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

        if [[ "$trimmed" == "$ADD_LABEL" ]]; then
          local new
          new=$(_config_prompt_profile "")
          if [[ -n "$new" ]]; then
            new_profiles+=("$new")
          else
            gum log --level warn "Skipped — no name entered"
          fi
          continue
        fi

        # Match the label back to a profile index.
        local idx=""
        for li in "${!labels[@]}"; do
          if [[ "${labels[$li]}" == "$line" ]]; then
            # Skip the ADD_LABEL row (no profile_idx entry for it).
            (( li >= ${#profile_idx[@]} )) && break
            idx="${profile_idx[$li]}"
            break
          fi
        done
        [[ -z "$idx" ]] && continue

        local original="${new_profiles[$idx]}"
        local nm; nm=$(config_profile_name "$original")
        echo
        gum style --faint "── editing profile ──────────────────────────────"
        _config_print_profile "$original"
        local edited
        edited=$(_config_prompt_profile_partial "$original")
        if [[ "$edited" == "DELETE" ]]; then
          gum log --level warn "Removing $nm"
          local -a filtered=()
          local k
          for k in "${!new_profiles[@]}"; do
            (( k == idx )) && continue
            filtered+=("${new_profiles[$k]}")
          done
          new_profiles=("${filtered[@]+"${filtered[@]}"}")
        elif [[ -n "$edited" ]]; then
          new_profiles[$idx]="$edited"
        fi
        # empty return → keep as-is
      done <<< "$chosen"
    fi
  fi

  # Have the profiles actually changed vs. what was on disk? If not,
  # we'll skip the "Save these profile(s)?" prompt entirely.
  local changed=false
  if (( ${#original_profiles[@]} != ${#new_profiles[@]} )); then
    changed=true
  else
    local k
    for k in "${!new_profiles[@]}"; do
      if [[ "${new_profiles[$k]}" != "${original_profiles[$k]:-}" ]]; then
        changed=true; break
      fi
    done
  fi

  if (( ${#new_profiles[@]} == 0 )); then
    gum log --level error "At least one camera profile is required"
    return 1
  fi

  # ── Result view (what will be saved) ─────────────────────────────────
  # We show TWO things: a human-friendly table for reading, and separately
  # build the raw pipe-delimited file text that actually gets written.

  # Build the raw file body (pipe-delimited, with header comments).
  local raw_file
  raw_file=$(
    cat << 'HDR'
# Photo Import — Camera Profiles
# ─────────────────────────────────────────────────────────────────────────────
# Name | raw_exts | jpeg_exts | split_folders | output_base_dir
#
#   raw_exts/jpeg_exts  comma-separated extensions (e.g. ARW,RAF)
#   split_folders       true  → raws/ and jpgs/ inside the event folder
#                       false → all files dumped at event root
# ─────────────────────────────────────────────────────────────────────────────

HDR
    printf '%s\n' "${new_profiles[@]}"
  )

  # Build the pretty table for the on-screen "Result" box. Column widths
  # are generous so long camera names and paths breathe on wide terminals.
  # Rows whose output_dir doesn't exist on disk get a "(missing)" marker
  # so the user knows why a profile they didn't touch is still listed.
  local table_header
  printf -v table_header '  %-30s  %-14s  %-14s  %-6s  %s' \
    "NAME" "RAW EXTS" "JPEG EXTS" "SPLIT" "OUTPUT DIRECTORY"
  local table_rule='  ────────────────────────────  ──────────────  ──────────────  ──────  ──────────────────────────────────'
  local table_body=""
  local q _n _r _j _s _o _row _marker
  for q in "${new_profiles[@]}"; do
    _n=$(config_profile_name "$q")
    _r=$(config_profile_raw_exts "$q"); _r="${_r:--}"
    _j=$(config_profile_jpg_exts "$q"); _j="${_j:--}"
    _s=$(config_profile_split "$q")
    _o=$(config_profile_outdir "$q")
    if [[ -d "$_o" ]]; then
      _marker=""
    else
      _marker=" ${THEME_MUTED}(missing)${THEME_RST}"
    fi
    printf -v _row '  %-30s  %-14s  %-14s  %-6s  %s%s' "$_n" "$_r" "$_j" "$_s" "$_o" "$_marker"
    table_body+="$_row"$'\n'
  done

  echo
  _tui_section_header "Result  ·  ${#new_profiles[@]} profile(s)" green
  printf '%s\n' "$table_header"
  printf '%s\n' "$table_rule"
  printf '%s' "$table_body"

  if $is_dry_run; then
    echo
    gum log --level warn "Dry run — not writing. Path would be: $CONFIG_FILE"
    return 0
  fi

  # If nothing actually changed vs. what's on disk, skip the save prompt
  # entirely — no reason to ask the user about a no-op write.
  if ! $changed; then
    echo
    gum log --level info "No changes — nothing to save"
    return 0
  fi

  # Final confirm — nothing on disk changes until the user approves.
  # This gives them one last chance to bail out after seeing the full
  # rendered result, without partial writes if they cancel mid-flow.
  echo
  if ! gum confirm --default=Yes --affirmative="✓ Yes" --negative="✗ No" "Save these ${#new_profiles[@]} profile(s) to $CONFIG_FILE?"; then
    gum log --level warn "Not saved — changes discarded"
    return 0
  fi

  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$raw_file" > "$CONFIG_FILE"
  echo
  gum log --level info "Wrote $CONFIG_FILE (${#new_profiles[@]} profile(s))"
}

# Prompt for one profile in "partial edit" mode: the user picks a subset of
# fields via multi-select, and only those fields are re-prompted. Every
# other field keeps its existing value from $1 (the seed profile).
_config_prompt_profile_partial() {
  local seed="$1"
  local d_name d_raw d_jpg d_split d_out
  d_name=$(config_profile_name "$seed")
  d_raw=$(config_profile_raw_exts "$seed")
  d_jpg=$(config_profile_jpg_exts "$seed")
  d_split=$(config_profile_split "$seed")
  d_out=$(config_profile_outdir "$seed")

  # Decorative output goes straight to the terminal, NOT stdout — this
  # function is called via edited=$(...) so anything on stdout would be
  # captured into the returned profile string.
  echo > /dev/tty
  gum style --faint "── select fields to update for: $d_name ──" > /dev/tty
  local chosen
  chosen=$(printf '%s\n' \
    "Name" \
    "RAW extensions" \
    "JPEG extensions" \
    "Split RAW/JPG folders" \
    "Output directory" \
    "Delete this profile" \
    | gum choose --no-limit --header "" \
        --cursor "▶ " \
        --selected-prefix "✓ " \
        --unselected-prefix "  " \
        --cursor-prefix "  " \
        --cursor.foreground 82 \
        --selected.foreground 39 \
        --item.foreground 82)

  if [[ -z "$chosen" ]]; then
    gum log --level info "Nothing selected — keeping profile as-is"
    printf '%s' "$seed"
    return 0
  fi

  # "Delete this profile" short-circuits everything else — the outer
  # loop watches for the DELETE sentinel and drops the profile.
  if grep -qxF "Delete this profile" <<< "$chosen"; then
    gum confirm --default=No --affirmative="✓ Yes" --negative="✗ No" "Really delete $d_name?" || {
      gum log --level info "Delete cancelled — keeping profile as-is"
      printf '%s' "$seed"
      return 0
    }
    printf 'DELETE'
    return 0
  fi

  local name="$d_name" raw="$d_raw" jpg="$d_jpg" split="$d_split" out="$d_out"

  # Iterate the chosen fields and re-prompt for each.
  local line
  while IFS= read -r line; do
    case "$line" in
      "Name")
        local nv
        nv=$(gum input --header "Camera name" --value "$d_name" --width 60)
        [[ -n "$nv" ]] && name="$nv"
        ;;
      "RAW extensions")
        raw=$(gum input --header "RAW extensions (comma-separated, or blank if none)" \
          --value "$d_raw" --placeholder "ARW  ·  RAF  ·  NEF  ·  CR3  ·  TIF,TIFF" --width 60)
        ;;
      "JPEG extensions")
        jpg=$(gum input --header "JPEG extensions (comma-separated, or blank if none)" \
          --value "$d_jpg" --placeholder "JPG,JPEG  (blank = no JPEG output)" --width 60)
        ;;
      "Split RAW/JPG folders")
        if [[ -z "$raw" || -z "$jpg" ]]; then
          split="false"
          gum log --level info "Only one file type — split forced to false"
        else
          local sc
          sc=$(gum choose --header "Split RAW / JPG into subfolders?" \
            --cursor "▶ " --cursor.foreground 82 --item.foreground 82 \
            "Yes — files land in <event>/raws/ and <event>/jpgs/" \
            "No — all files at <event>/ root")
          case "$sc" in
            Yes*) split="true"  ;;
            No*)  split="false" ;;
          esac
        fi
        ;;
      "Output directory")
        local out_action
        out_action=$(gum choose --header "How would you like to set the output directory?" \
          --cursor "▶ " --cursor.foreground 82 --item.foreground 82 \
          "Type the path" \
          "Pick a folder in Finder")
        case "$out_action" in
          "Pick a folder in Finder")
            local ov
            ov=$(osascript -e "POSIX path of (choose folder with prompt \"Output directory for $name\" default location POSIX file \"$d_out\")" 2>/dev/null)
            ov="${ov%/}"
            if [[ -n "$ov" ]]; then
              out="$ov"
            else
              gum log --level warn "No folder selected — keeping $d_out"
            fi
            ;;
          *)
            local ov
            ov=$(gum input --header "Output directory (event folders created inside)" \
              --value "$d_out" --width 60)
            [[ -n "$ov" ]] && out="$ov"
            ;;
        esac
        ;;
    esac
  done <<< "$chosen"

  # If the caller cleared BOTH ext lists, split must be false (no subdirs).
  [[ -z "$raw" && -z "$jpg" ]] && split="false"
  [[ -z "$raw" ||  -z "$jpg" ]] && split="false"

  printf '%s|%s|%s|%s|%s' "$name" "$raw" "$jpg" "$split" "$out"
}

# Pretty-print an existing profile line for confirmation prompts.
_config_print_profile() {
  local p="$1"
  printf "  Name:      %s\n" "$(config_profile_name "$p")"
  printf "  RAW:       %s\n" "$(config_profile_raw_exts "$p")"
  printf "  JPEG:      %s\n" "$(config_profile_jpg_exts "$p")"
  printf "  Split:     %s\n" "$(config_profile_split "$p")"
  printf "  Output:    %s\n" "$(config_profile_outdir "$p")"
}

# Prompt for one profile. If $1 is a profile string, its fields are used as
# defaults (for edit-mode). Prints the assembled "Name|raw|jpg|split|dir"
# line on stdout, or nothing if the user gives an empty name.
_config_prompt_profile() {
  local seed="$1"
  local d_name d_raw d_jpg d_split d_out
  if [[ -n "$seed" ]]; then
    d_name=$(config_profile_name "$seed")
    d_raw=$(config_profile_raw_exts "$seed")
    d_jpg=$(config_profile_jpg_exts "$seed")
    d_split=$(config_profile_split "$seed")
    d_out=$(config_profile_outdir "$seed")
  else
    d_name=""
    d_raw="ARW"
    d_jpg="JPG,JPEG"
    d_split="true"
    d_out=""
  fi

  # Decorative output goes straight to the terminal, NOT stdout — this
  # function is called via new=$(...) so anything on stdout would be
  # captured into the returned profile string (and non-empty stdout on
  # cancel would leak a garbage row into new_profiles).
  echo > /dev/tty
  gum style --faint "── new / edit profile ───────────────────────────" > /dev/tty

  local name raw jpg split out
  # Loop the name prompt so accidentally hitting Enter with an empty
  # field doesn't silently cancel — only Esc/Ctrl-C should bail out.
  while true; do
    name=$(gum input --header "Camera name" --value "$d_name" \
      --placeholder "e.g. Sony A7RII, Fuji X-T5, Scanner" --width 60) || return 0
    [[ -n "$name" ]] && break
    gum log --level warn "Camera name is required — try again (or Esc to cancel)"
  done

  # Both extension lists may be blank. Semantics:
  #   raw + jpg  : file routes by extension into RAWS / JPEGS
  #   raw only   : only that extension collected (source-type only)
  #   jpg only   : same, the other side
  #   blank/blank: no filtering — every file in the source folder is
  #                copied to the event root (importer bins them as OTHERS).
  raw=$(gum input --header "RAW extensions (comma-separated, or blank if none)" \
    --value "$d_raw" --placeholder "ARW  ·  RAF  ·  NEF  ·  CR3  ·  TIF,TIFF" --width 60)

  jpg=$(gum input --header "JPEG extensions (comma-separated, or blank if none)" \
    --value "$d_jpg" --placeholder "JPG,JPEG  (blank = no JPEG output)" --width 60)

  # Splitting into raws/ and jpgs/ only makes sense when BOTH extension
  # lists are defined. Otherwise force split=false and skip the prompt:
  #   • single-type profile  → nothing to separate
  #   • blank/blank profile  → catch-all, everything drops at <event>/ root
  if [[ -z "$raw" || -z "$jpg" ]]; then
    split="false"
    if [[ -z "$raw" && -z "$jpg" ]]; then
      gum log --level info "No extensions set — every file will land at <event>/ root"
    else
      gum log --level info "Only one file type — files will land at <event>/ root"
    fi
  else
    local split_choice
    split_choice=$(gum choose --header "Split RAW / JPG into subfolders?" \
      --cursor "▶ " --cursor.foreground 82 --item.foreground 82 \
      "Yes — files land in <event>/raws/ and <event>/jpgs/" \
      "No — all files at <event>/ root")
    case "$split_choice" in
      Yes*) split="true"  ;;
      No*)  split="false" ;;
      *)    split="$d_split" ;;
    esac
  fi

  [[ -z "$d_out" ]] && d_out="$HOME/Pictures/$name"
  local out_action
  out_action=$(gum choose --header "How would you like to set the output directory?" \
    --cursor "▶ " --cursor.foreground 82 --item.foreground 82 \
    "Type the path" \
    "Pick a folder in Finder")
  case "$out_action" in
    "Pick a folder in Finder")
      # Native macOS folder picker via osascript. Falls back to typing on failure.
      out=$(osascript -e "POSIX path of (choose folder with prompt \"Output directory for $name\" default location POSIX file \"$d_out\")" 2>/dev/null)
      # Trim trailing slash for neatness.
      out="${out%/}"
      if [[ -z "$out" ]]; then
        gum log --level warn "No folder selected — falling back to typing"
        out=$(gum input --header "Output directory (event folders created inside)" \
          --value "$d_out" --width 60)
      fi
      ;;
    *)
      out=$(gum input --header "Output directory (event folders created inside)" \
        --value "$d_out" --width 60)
      ;;
  esac
  [[ -z "$out" ]] && out="$d_out"

  printf '%s|%s|%s|%s|%s' "$name" "$raw" "$jpg" "$split" "$out"
}

_config_create_default() {
  # First-boot fallback when config_load is called without a config file.
  # Route through the interactive setup instead of writing hard-coded
  # profiles; the caller (run_tui) is expected to have gum available.
  config_interactive_setup fresh
}

# Reset the config: back up the current file with a timestamp, then run
# the interactive setup fresh. Confirms before touching anything so a
# stray flag doesn't wipe someone's config.
config_reset() {
  # Optional first arg "dry-run" simulates the reset:
  #   • no backup file is created
  #   • the existing config is NOT deleted
  #   • the interactive setup runs in dry-run mode (no final write)
  local dry_run=false
  [[ "${1:-}" == "dry-run" ]] && dry_run=true

  local backup=""
  if [[ -f "$CONFIG_FILE" ]]; then
    local ts; ts=$(date '+%Y-%m-%d_%H-%M-%S')
    backup="${CONFIG_FILE}.${ts}.bak"
  fi

  echo
  gum style --border rounded --border-foreground 196 --padding "0 2" \
    "$(gum style --foreground 220 --bold "  ⚠  Config Reset  ")" \
    "" \
    "$(gum style --faint "This will:")" \
    "$(gum style --foreground 220 "  •")  Back up your current config to a timestamped .bak file" \
    "$(gum style --foreground 220 "  •")  Walk you through the first-run setup to build a new one" \
    "$(gum style --foreground 220 "  •")  Replace cameras.conf only after you confirm the result" \
    ""
  if [[ -n "$backup" ]]; then
    printf "  %s %s\n" "$(gum style --faint "Backup path:")" "$backup"
  else
    printf "  %s\n" "$(gum style --faint "No existing config — nothing to back up.")"
  fi
  printf "  %s %s\n\n" "$(gum style --faint "New config path:")" "$CONFIG_FILE"

  gum confirm --default=No --affirmative="✓ Yes" --negative="✗ No" "Proceed with reset?" || {
    gum log --level warn "Cancelled — config untouched"
    return 0
  }

  if $dry_run; then
    gum log --level warn "Dry run — no backup created, existing config left alone"
    config_interactive_setup dry-run
    return 0
  fi

  if [[ -n "$backup" ]]; then
    cp "$CONFIG_FILE" "$backup"
    gum log --level info "Backed up existing config → $backup"
    # The live file is intentionally left in place: the wizard overwrites it
    # only after the user confirms the final summary. Quitting mid-wizard
    # therefore leaves the current config untouched.
  fi

  # Blank slate → run the same interactive setup as first-run.
  config_interactive_setup fresh
}
