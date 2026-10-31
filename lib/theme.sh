#!/usr/bin/env bash
# =============================================================================
# theme.sh — All the colors used by the dashboard and pickers.
#
# Every value below is an ANSI escape sequence. Printing one changes the
# color of everything that follows until you print THEME_RST (reset).
# Example:  printf "${THEME_LABEL}Size:${THEME_RST} 12 GB"
#           -> "Size:" appears purple, "12 GB" appears in the default color.
#
# The palette is grouped by role. To reskin (dark theme, brand colors, etc.)
# you only need to change the "semantic aliases" section at the bottom —
# the widgets never reference raw color numbers directly.
# =============================================================================

# --- Reset and text attributes ------------------------------------------------
THEME_RST=$'\033[0m'      # turn off all coloring / bold / dim
THEME_BOLD=$'\033[1m'     # bold text
THEME_DIM=$'\033[2m'      # dimmed / faded text

# --- Text colors --------------------------------------------------------------
THEME_TEXT=$'\033[38;5;255m'    # near-white — the default body-text color
THEME_MUTED=$'\033[38;5;250m'   # light grey — used for hints and labels

# --- Purple family (borders, headers, accents) -------------------------------
THEME_PURPLE=$'\033[38;5;141m'     # medium purple  — box borders
THEME_PURPLE_HI=$'\033[38;5;177m'  # bright purple  — titles, labels
THEME_PURPLE_DK=$'\033[38;5;61m'   # deep purple    — bar backgrounds

# --- Green family (values, "good" indicators, progress bars) -----------------
THEME_GREEN=$'\033[38;5;83m'     # bright green   — checkmarks, fill bars
THEME_GREEN_HI=$'\033[38;5;120m'  # light green    — reserved
THEME_GREEN_DK=$'\033[38;5;28m'   # forest green   — reserved

# --- Semantic aliases (what widgets actually reference) ----------------------
# These are the ONLY names widgets should use. Swap them to change the look
# of the whole app without editing individual widget code.
THEME_HEADER=$THEME_PURPLE_HI     # top "Photo Import" title
THEME_BORDER=$THEME_PURPLE        # ┌── ─── ─── ─── ┐ characters
THEME_LABEL=$THEME_PURPLE_HI      # "Used", "Free", "Size", etc.
THEME_VALUE=$THEME_TEXT           # the numbers next to labels
THEME_BAR_FG=$THEME_GREEN         # filled portion of a progress bar
THEME_BAR_BG=$THEME_PURPLE_DK     # empty portion of a progress bar
THEME_SELECTED=$THEME_GREEN       # green ✓ next to a chosen item
THEME_FOCUS=$THEME_PURPLE_HI      # highlight for the current cursor row
