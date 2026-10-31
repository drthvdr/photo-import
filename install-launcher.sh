#!/usr/bin/env bash
# install-launcher.sh — build a "Photo Import.app" bundle you can double-click
# from Applications, Spotlight, or the Dock. The app opens a new Terminal
# window and runs `photo-import`.
#
# Usage:  ./install-launcher.sh              → installs to /Applications
#         ./install-launcher.sh ~/Applications → custom location

set -euo pipefail

DEST_DIR="${1:-/Applications}"
APP_PATH="$DEST_DIR/Photo Import.app"
CMD="$(cd "$(dirname "$0")" && pwd)/photo-import"

if [[ ! -x "$CMD" ]]; then
  echo "error: expected $CMD to exist and be executable" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

# Write the AppleScript source, then compile it into a real .app bundle.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/launcher.applescript" <<APPLESCRIPT
-- Check whether Terminal was already running BEFORE we activate it. When
-- Terminal isn't running, \`activate\` launches it AND opens a default empty
-- window; \`do script\` would then open a SECOND window. To avoid that,
-- reuse the default window in the cold-start case.
--
-- We DO NOT try to close the window from this script. The photo-import
-- script closes its own Terminal.app window on clean exit (via osascript
-- guarded by TERM_PROGRAM == "Apple_Terminal"). If the launcher also
-- tried to close, it would race the script's close and Terminal.app
-- would throw a "Can't get window id ..." modal dialog.
tell application "System Events" to set wasRunning to exists (process "Terminal")

tell application "Terminal"
    activate
    if wasRunning then
        do script "clear; '$CMD'; sleep 1; exit"
    else
        delay 0.3
        do script "clear; '$CMD'; sleep 1; exit" in front window
    end if
end tell
APPLESCRIPT

# Remove any previous version.
[[ -e "$APP_PATH" ]] && rm -rf "$APP_PATH"

osacompile -o "$APP_PATH" "$tmp/launcher.applescript"

# ── Icon: convert icon.png (if present) into a proper .icns and embed it ─────
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_SRC="$PROJECT_DIR/icon.png"
if [[ -f "$ICON_SRC" ]]; then
  echo "Applying icon from $ICON_SRC …"
  iconset="$tmp/AppIcon.iconset"
  mkdir -p "$iconset"
  # macOS expects these sizes in a .iconset directory.
  for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
              "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
              "512 512x512" "1024 512x512@2x"; do
    read -r px name <<< "$pair"
    sips -z "$px" "$px" "$ICON_SRC" --out "$iconset/icon_${name}.png" >/dev/null 2>&1 || true
  done
  iconutil -c icns "$iconset" -o "$tmp/AppIcon.icns" 2>/dev/null

  if [[ -f "$tmp/AppIcon.icns" ]]; then
    cp "$tmp/AppIcon.icns" "$APP_PATH/Contents/Resources/applet.icns"
    # Nudge Finder + LaunchServices to pick up the new icon.
    touch "$APP_PATH"
  else
    echo "  (couldn't build .icns — leaving default icon)" >&2
  fi
fi

echo
echo "Installed:  $APP_PATH"
echo
echo "Next steps:"
echo "  • Open Finder → Applications → drag 'Photo Import' to your Dock"
echo "  • Or press ⌘Space and type 'Photo Import' to launch via Spotlight"
echo
echo "Custom icons:"
echo "  • Drop a new icon.png into $PROJECT_DIR/ and re-run this script"
echo "  • Or right-click 'Photo Import.app' → Get Info → drag any image onto the tiny icon"
