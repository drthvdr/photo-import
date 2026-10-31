#!/usr/bin/env bash
# =============================================================================
# dashboard_ui.sh — The specific widgets you see on screen.
#
# What lives here:
#   • dash_widget_sdcard — the "SD Card" box (Used / Free / capacity bar)
#   • dash_widget_library — the "Library" box (Size / Events / RAW+JPG counts)
#   • dash_widget_cameras — a "Cameras" box (currently unused; kept for future)
#   • dash_widget_stats  — a "RAW / JPG" summary row
#   • dash_folder_card   — a card representing one DCIM folder (name + date + count)
#
# Each widget function returns a "spec" string that dash_render_row (from
# dashboard_box.sh) turns into a rendered row of side-by-side boxes.
# =============================================================================

# dash_widget_sdcard <sd_path> <width>
# Emits a "title|width|line1||line2||..." spec for dash_render_row.
dash_widget_sdcard() {
  local sd="$1" w="$2"
  local size_b used_b avail_b pct
  read -r size_b used_b avail_b pct < <(df -k "$sd" 2>/dev/null \
    | awk 'NR==2 { gsub("%","",$5); printf "%d %d %d %d", $2*1024, $3*1024, $4*1024, $5 }')
  size_b=${size_b:-0}; used_b=${used_b:-0}; avail_b=${avail_b:-0}; pct=${pct:-0}

  local s_size s_used s_avail
  s_size=$(dash_bytes_human "$size_b")
  s_used=$(dash_bytes_human "$used_b")
  s_avail=$(dash_bytes_human "$avail_b")

  local inner=$(( w - 4 ))
  local bar; bar=$(dash_bar "$pct" "$inner")
  local title="SD Card"
  # Right-align numeric values into a 9-char field so borders stay stable
  # even as sizes grow (e.g. "58.3 GB" vs "460.4 GB" vs "1.2 TB").
  local u_pad; printf -v u_pad '%9s' "$s_used"
  local s_pad; printf -v s_pad '%9s' "$s_size"
  local f_pad; printf -v f_pad '%9s' "$s_avail"
  local p_pad; printf -v p_pad '%4s' "${pct}%"
  local l1="${THEME_LABEL}Used${THEME_RST} ${THEME_VALUE}${u_pad}${THEME_RST} / ${THEME_MUTED}${s_pad}${THEME_RST}"
  local l2="${THEME_LABEL}Free${THEME_RST} ${THEME_VALUE}${f_pad}${THEME_RST}     ${THEME_GREEN}${p_pad}${THEME_RST}"
  printf '%s|%s|%s||%s||%s' "$title" "$w" "$l1" "$l2" "$bar"
}

# dash_widget_library <width>
# Sums size of every configured camera outdir (from PROFILES[]).
dash_widget_library() {
  local w="$1"
  local total=0 events=0 raw_count=0 jpg_count=0
  local p
  for p in "${PROFILES[@]}"; do
    local d; d=$(config_profile_outdir "$p")
    [[ -d "$d" ]] || continue
    local sz; sz=$(dash_dir_size_bytes "$d")
    total=$(( total + sz ))
    local n; n=$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    events=$(( events + n ))

    # Count RAW and JPG files across this camera's library
    raw_count=$(( raw_count + $(importer_count_by_ext_csv "$d" "$(config_profile_raw_exts "$p")") ))
    jpg_count=$(( jpg_count + $(importer_count_by_ext_csv "$d" "$(config_profile_jpg_exts "$p")") ))
  done
  local human; human=$(dash_bytes_human "$total")
  local h_pad; printf -v h_pad '%9s' "$human"
  local e_pad; printf -v e_pad '%9d' "$events"
  local r_pad; printf -v r_pad "%'d" "$raw_count"
  local j_pad; printf -v j_pad "%'d" "$jpg_count"
  local title="Library"
  local l1="${THEME_LABEL}Size${THEME_RST}   ${THEME_VALUE}${THEME_BOLD}${h_pad}${THEME_RST}"
  local l2="${THEME_LABEL}Events${THEME_RST} ${THEME_VALUE}${e_pad}${THEME_RST}"
  local l3="${THEME_LABEL}RAW${THEME_RST} ${THEME_VALUE}${r_pad}${THEME_RST}   ${THEME_LABEL}JPG${THEME_RST} ${THEME_VALUE}${j_pad}${THEME_RST}"
  printf '%s|%s|%s||%s||%s' "$title" "$w" "$l1" "$l2" "$l3"
}

# dash_widget_cameras <width> <selected_idx>
# Lists camera profile names with a checkbox next to the selected one.
dash_widget_cameras() {
  local w="$1" selected_idx="${2:-0}"
  local title="Cameras"
  local body=""
  local i
  for i in "${!PROFILES[@]}"; do
    local name; name=$(config_profile_name "${PROFILES[$i]}")
    local mark
    if (( i == selected_idx )); then
      mark="${THEME_SELECTED}[x]${THEME_RST}"
    else
      mark="${THEME_MUTED}[ ]${THEME_RST}"
    fi
    local line="${mark} ${THEME_VALUE}${name}${THEME_RST}"
    if [[ -z "$body" ]]; then body="$line"; else body="${body}||${line}"; fi
  done
  printf '%s|%s|%s' "$title" "$w" "$body"
}

# dash_widget_stats <width> <raw_count> <raw_bytes> <jpg_count> <jpg_bytes>
# The "Network"-row analog: JPG + RAW counts and sizes.
dash_widget_stats() {
  local w="$1" rc="$2" rb="$3" jc="$4" jb="$5"
  local title="Media"
  local rh; rh=$(dash_bytes_human "$rb")
  local jh; jh=$(dash_bytes_human "$jb")
  local l1
  printf -v l1 "${THEME_LABEL}RAW:${THEME_RST}  ${THEME_VALUE}%'d files${THEME_RST}   ${THEME_MUTED}%s${THEME_RST}" "$rc" "$rh"
  local l2
  printf -v l2 "${THEME_LABEL}JPG:${THEME_RST}  ${THEME_VALUE}%'d files${THEME_RST}   ${THEME_MUTED}%s${THEME_RST}" "$jc" "$jh"
  printf '%s|%s|%s||%s' "$title" "$w" "$l1" "$l2"
}

# dash_folder_card <name> <date> <count> <selected 0|1> <focused 0|1>
# Fills global _CARD[0..5] with a 20-wide solid-border rectangular card:
#
#   ┌── 10860905 ──────┐
#   │ Sep 5, 2026      │
#   │ 247 images       │
#   │            [ x ] │
#   └──────────────────┘
#
# Focus wins over selection for the border color.
dash_folder_card() {
  local nm="$1" dt="$2" cnt="$3" sel="$4" foc="$5"
  local W="${6:-20}"
  local BC="$THEME_BORDER"
  (( sel )) && BC="$THEME_SELECTED"
  (( foc )) && BC="$THEME_FOCUS"
  local RST="$THEME_RST" T="$THEME_VALUE" L="$THEME_LABEL"

  local inner=$(( W - 2 ))
  local title=" ${nm} "
  local left_seg=2
  local right_seg=$(( inner - left_seg - ${#title} ))
  (( right_seg < 1 )) && right_seg=1
  local ls; ls=$(_dash_hline "$left_seg")
  local rs; rs=$(_dash_hline "$right_seg")

  _CARD=()
  _CARD[0]="${BC}┌${ls}${L}${THEME_BOLD}${title}${RST}${BC}${rs}┐${RST}"

  local iw=$(( inner - 2 ))
  local dt_line cnt_line
  printf -v dt_line  '%-*s' "$iw" "${dt:0:$iw}"
  printf -v cnt_line '%-*s' "$iw" "${cnt} images"

  local mark
  if (( sel )); then mark="${THEME_SELECTED}x${RST}"; else mark=" "; fi
  local chk_pad=$(( iw - 5 ))
  (( chk_pad < 0 )) && chk_pad=0
  local lpad; lpad=$(printf '%*s' "$chk_pad" '')
  local chk_line="${lpad}[ ${mark} ]"

  _CARD[1]="${BC}│${RST} ${T}${dt_line}${RST} ${BC}│${RST}"
  _CARD[2]="${BC}│${RST} ${T}${cnt_line}${RST} ${BC}│${RST}"
  _CARD[3]="${BC}│${RST} ${chk_line} ${BC}│${RST}"
  local bot; bot=$(_dash_hline "$inner")
  _CARD[4]="${BC}└${bot}┘${RST}"
  _CARD[5]=$(printf '%*s' "$W" '')
}
