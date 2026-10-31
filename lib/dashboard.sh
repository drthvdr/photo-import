#!/usr/bin/env bash
# =============================================================================
# dashboard.sh — Primitives for the dashboard row (the "SD Card" and
#                "Library" widgets at the top of the screen).
#
# This file is the low-level toolkit — it draws boxes, formats sizes, reads
# disk stats and directory sizes. The higher-level "which widget shows what"
# lives in dashboard_ui.sh.
#
# Public helpers:
#   dash_term_width                    prints terminal columns (min 80)
#   dash_header <text> <w>             top banner with a "Photo Import"-style rule
#   dash_box  <title> <w> <h> <lines>  a titled box with a solid border
#   dash_bar  <pct> <inner_w>          a colored progress bar string
#   dash_bytes_human <bytes>           turn 1288490188 into "1.2 GB"
#   dash_disk_stats <path>             "total used free pct" from `df`
#   dash_dir_size_bytes <dir>          sum of every file size under <dir>
# =============================================================================

dash_term_width() {
  local w
  w=$(tput cols 2>/dev/null || echo 80)
  (( w < 80 )) && w=80
  printf '%s' "$w"
}

# Repeat a single char N times (visual/byte length assumed equal, so use with ASCII).
_dash_repeat() {
  local ch="$1" n="$2" out=""
  local i; for (( i=0; i<n; i++ )); do out+="$ch"; done
  printf '%s' "$out"
}

# Print a horizontal solid line of N cells using ─
_dash_hline() { _dash_repeat "─" "$1"; }

# dash_header <text> [width]
# ╭──── Photo Import ───────────────────╮  (heavy top rule, centered title)
dash_header() {
  local text="$1"
  local w="${2:-$(dash_term_width)}"
  local title=" ${text} "
  local tlen=${#title}
  local side=$(( (w - tlen - 2) / 2 ))
  (( side < 2 )) && side=2
  local left; left=$(_dash_hline "$side")
  local right; right=$(_dash_hline $(( w - tlen - side - 2 )))
  printf '%s╭%s%s%s%s%s%s╮%s\n' \
    "$THEME_BORDER" \
    "$left" \
    "$THEME_HEADER$THEME_BOLD" "$title" "$THEME_RST$THEME_BORDER" \
    "$right" \
    "$THEME_BORDER" \
    "$THEME_RST"
}

# Size on disk under a directory, in bytes. Uses du which is significantly
# faster than find+stat on large trees (photo libraries can be huge).
dash_dir_size_bytes() {
  local dir="$1"
  [[ -d "$dir" ]] || { printf '0'; return; }
  local kb
  kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
  kb=${kb:-0}
  printf '%d' $(( kb * 1024 ))
}

# Human-readable bytes → GB/MB/KB (1024-based).
dash_bytes_human() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB PB", u, " ");
    i=1;
    while (b >= 1024 && i < 6) { b/=1024; i++ }
    if (i == 1) printf "%d %s", b, u[i];
    else        printf "%.1f %s", b, u[i];
  }'
}

# dash_disk_stats <mount_path> → "size_h used_h avail_h pct_int"
dash_disk_stats() {
  local path="$1"
  [[ -d "$path" ]] || { printf '— — — 0'; return; }
  # df -k reports 1K blocks; portable enough on macOS
  local size used avail pct
  read -r size used avail pct < <(df -k "$path" 2>/dev/null \
    | awk 'NR==2 { gsub("%","",$5); printf "%s %s %s %s", $2*1024, $3*1024, $4*1024, $5 }')
  size=${size:-0}; used=${used:-0}; avail=${avail:-0}; pct=${pct:-0}
  printf '%s %s %s %s' \
    "$(dash_bytes_human "$size")" \
    "$(dash_bytes_human "$used")" \
    "$(dash_bytes_human "$avail")" \
    "$pct"
}

# dash_bar <pct 0-100> <inner_width>
# Green filled portion + dim purple background.
dash_bar() {
  local pct="${1:-0}" w="${2:-20}"
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  local fill=$(( pct * w / 100 ))
  local rest=$(( w - fill ))
  local a b
  a=$(_dash_repeat "█" "$fill")
  b=$(_dash_repeat "░" "$rest")
  printf '%s%s%s%s%s' "$THEME_BAR_FG" "$a" "$THEME_BAR_BG" "$b" "$THEME_RST"
}
