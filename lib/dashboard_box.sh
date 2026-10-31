#!/usr/bin/env bash
# =============================================================================
# dashboard_box.sh — The math and characters used to draw the dashboard boxes.
#
# What lives here:
#   • Stripping ANSI color codes so we can measure "visible" text width
#   • Padding colored strings to a target width (padding without breaking colors)
#   • Rendering a single widget "spec" into an array of pre-colored lines
#   • Rendering a horizontal row of side-by-side widgets, aligned by height
#
# A widget "spec" is a compact pipe-delimited string:
#   "Title|width|body_line_1||body_line_2||body_line_3"
# Each "||" separates body lines. dash_render_row takes multiple specs
# and prints one row per line, columns left-to-right.
# =============================================================================

# Strip ANSI SGR sequences and return the remaining string.
dash_strip_ansi() {
  local s="$1"
  local out=""
  local i=0 len=${#s}
  while (( i < len )); do
    local ch="${s:$i:1}"
    if [[ "$ch" == $'\033' && "${s:$((i+1)):1}" == "[" ]]; then
      i=$(( i + 2 ))
      while (( i < len )); do
        local c="${s:$i:1}"
        i=$(( i + 1 ))
        [[ "$c" =~ [A-Za-z] ]] && break
      done
    else
      out+="$ch"
      i=$(( i + 1 ))
    fi
  done
  printf '%s' "$out"
}

# Visible width of a string (ANSI-stripped). All widget content is now ASCII
# after ANSI stripping, so byte count == cell count. Use ${#s} to avoid the
# fragile wc -m + locale dependency (which was causing width miscounts).
dash_vwidth() {
  local plain; plain=$(dash_strip_ansi "$1")
  printf '%s' "${#plain}"
}

# Pad a (possibly colored) string to visible width W on the right with spaces.
dash_pad_right() {
  local s="$1" w="$2"
  local vw; vw=$(dash_vwidth "$s")
  local diff=$(( w - vw ))
  (( diff <= 0 )) && { printf '%s' "$s"; return; }
  local pad; pad=$(printf '%*s' "$diff" '')
  printf '%s%s' "$s" "$pad"
}

# dash_box <title> <total_width> <body_line>...
# Draws a solid box with a title inserted in the top border:
#   ┌─ Title ────────────┐
#   │ body line 1        │
#   │ body line 2        │
#   └────────────────────┘
dash_box() {
  local title="$1" w="$2"; shift 2
  local inner=$(( w - 2 ))          # space between │ │
  local tlen; tlen=$(dash_vwidth "$title")
  # top: ┌─ title ─...─┐
  local left=1                      # ─ before " title "
  local title_seg=$(( tlen + 2 ))   # " title "
  local right_seg=$(( inner - left - title_seg ))
  (( right_seg < 1 )) && right_seg=1
  local lseg; lseg=$(_dash_hline "$left")
  local rseg; rseg=$(_dash_hline "$right_seg")

  printf '%s┌%s %s%s%s %s┐%s\n' \
    "$THEME_BORDER" "$lseg" \
    "$THEME_LABEL$THEME_BOLD" "$title" "$THEME_RST$THEME_BORDER" \
    "$rseg" "$THEME_RST"

  local body
  for body in "$@"; do
    local padded; padded=$(dash_pad_right "$body" $(( inner - 2 )))
    printf '%s│%s %s %s│%s\n' \
      "$THEME_BORDER" "$THEME_RST" \
      "$padded" \
      "$THEME_BORDER" "$THEME_RST"
  done

  local bot; bot=$(_dash_hline "$inner")
  printf '%s└%s┘%s\n' "$THEME_BORDER" "$bot" "$THEME_RST"
}

# dash_boxes_side_by_side  <width_a> <title_a> <lines_a...> --- <width_b> <title_b> <lines_b...>
# For side-by-side rendering, use dash_box_lines to produce arrays then paste them.
# Simpler alternative: use dash_render_row below.

# dash_render_row <gap> <box_spec1> <box_spec2> ...
# Each box_spec is: "title|width|line1||line2||line3..."
# Renders boxes side-by-side. Boxes may have different heights; shorter ones
# are padded with blank border-only lines to match the tallest.
dash_render_row() {
  local gap="$1"; shift
  local -a specs=("$@")

  local -a titles=() widths=() bodies=()
  local spec
  for spec in "${specs[@]}"; do
    local title="${spec%%|*}"; spec="${spec#*|}"
    local width="${spec%%|*}"; spec="${spec#*|}"
    titles+=("$title")
    widths+=("$width")
    bodies+=("$spec")   # remaining: line1||line2||...
  done

  # Build each box's rendered lines into an array of strings, indexed [box*MAX + row].
  local -a boxlines=()
  local -a heights=()
  local maxh=0
  local i
  for i in "${!titles[@]}"; do
    local title="${titles[$i]}" w="${widths[$i]}" b="${bodies[$i]}"
    local -a lines=()
    while [[ -n "$b" ]]; do
      if [[ "$b" == *"||"* ]]; then
        lines+=("${b%%||*}"); b="${b#*||}"
      else
        lines+=("$b"); b=""
      fi
    done
    local h=$(( ${#lines[@]} + 2 ))
    (( h > maxh )) && maxh=$h
    heights+=("$h")

    # Render top
    local inner=$(( w - 2 ))
    local tlen; tlen=$(dash_vwidth "$title")
    local right_seg=$(( inner - 1 - tlen - 2 ))
    (( right_seg < 1 )) && right_seg=1
    local lseg="─"
    local rseg; rseg=$(_dash_hline "$right_seg")
    boxlines+=("${THEME_BORDER}┌${lseg} ${THEME_LABEL}${THEME_BOLD}${title}${THEME_RST}${THEME_BORDER} ${rseg}┐${THEME_RST}")

    local ln
    for ln in "${lines[@]}"; do
      local padded; padded=$(dash_pad_right "$ln" $(( inner - 2 )))
      boxlines+=("${THEME_BORDER}│${THEME_RST} ${padded} ${THEME_BORDER}│${THEME_RST}")
    done

    local bot; bot=$(_dash_hline "$inner")
    boxlines+=("${THEME_BORDER}└${bot}┘${THEME_RST}")
  done

  # Compute per-box offset into boxlines
  local -a offsets=()
  local acc=0
  for i in "${!heights[@]}"; do
    offsets+=("$acc"); acc=$(( acc + heights[i] ))
  done

  # Blank line template (border only) for padding shorter boxes.
  _blank_border() {
    local w="$1"
    local inner=$(( w - 2 ))
    local sp; sp=$(printf '%*s' "$inner" '')
    printf '%s│%s%s│%s' "$THEME_BORDER" "$THEME_RST" "$sp" "$THEME_RST"
  }

  local row
  for (( row=0; row<maxh; row++ )); do
    local out=""
    for i in "${!titles[@]}"; do
      local h=${heights[$i]}
      local w=${widths[$i]}
      local seg
      if (( row < h - 1 )); then
        # top + body lines
        seg="${boxlines[$(( offsets[i] + row ))]}"
      elif (( row == maxh - 1 )); then
        # bottom lines aligned to bottom-most row
        seg="${boxlines[$(( offsets[i] + h - 1 ))]}"
      else
        seg=$(_blank_border "$w")
      fi
      out+="$seg"
      if (( i < ${#titles[@]} - 1 )); then
        out+=$(printf '%*s' "$gap" '')
      fi
    done
    printf '%s\n' "$out"
  done
}
