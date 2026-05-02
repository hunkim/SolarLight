#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/SolarLight.app"
ASSETS_DIR="$ROOT_DIR/Assets"
DMG_STAGING_DIR="$BUILD_DIR/dmg"
DMG_TEMP_PATH="$BUILD_DIR/SolarLight-rw.dmg"
VERSION="${SOLARLIGHT_VERSION:-}"
DMG_NAME="SolarLight"
VOLUME_NAME="SolarLight"

if [[ -n "$VERSION" ]]; then
  DMG_NAME="SolarLight-$VERSION"
fi

DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"

# Set SOLARLIGHT_SKIP_APP_BUILD=1 to reuse an existing .build/SolarLight.app
# (e.g. after a Developer ID signing pass) instead of rebuilding/re-signing it.
if [[ "${SOLARLIGHT_SKIP_APP_BUILD:-0}" != "1" ]]; then
  "$ROOT_DIR/Scripts/package-app.sh" >/dev/null
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "error: $APP_DIR not found. Run Scripts/package-app.sh first or unset SOLARLIGHT_SKIP_APP_BUILD." >&2
  exit 1
fi

# Ensure DMG background images exist (regenerate if either is missing).
if [[ ! -f "$ASSETS_DIR/dmg-background.png" || ! -f "$ASSETS_DIR/dmg-background@2x.png" ]]; then
  swift "$ROOT_DIR/Scripts/make-dmg-background.swift" >/dev/null
fi

rm -rf "$DMG_STAGING_DIR" "$DMG_PATH" "$DMG_TEMP_PATH"
mkdir -p "$DMG_STAGING_DIR"

# Stage the app and a hidden background folder.
cp -R "$APP_DIR" "$DMG_STAGING_DIR/SolarLight.app"
mkdir -p "$DMG_STAGING_DIR/.background"
cp "$ASSETS_DIR/dmg-background.png" "$DMG_STAGING_DIR/.background/background.png"
# Tiled retina image: macOS picks @2x automatically when present alongside the 1x file.
cp "$ASSETS_DIR/dmg-background@2x.png" "$DMG_STAGING_DIR/.background/background@2x.png"

# Build a writable DMG so we can apply Finder window styling, then convert to compressed read-only.
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$DMG_TEMP_PATH" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TEMP_PATH")"
DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_POINT="$(echo "$ATTACH_OUTPUT" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"

cleanup() {
  if [[ -n "${MOUNT_POINT:-}" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$DEVICE" -quiet >/dev/null 2>&1 || hdiutil detach "$DEVICE" -force -quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Symlink to /Applications so users can drag-drop without extracting first.
ln -s /Applications "$MOUNT_POINT/Applications"

# Hide the .background folder so it doesn't appear in the DMG window.
chflags hidden "$MOUNT_POINT/.background" || true

# Apply Finder window styling: hidden toolbar, custom background, fixed icon positions.
osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {300, 120, 840, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set label position of viewOptions to bottom
        set shows icon preview of viewOptions to true
        set shows item info of viewOptions to false
        try
            set background picture of viewOptions to file ".background:background.png"
        end try
        set position of item "SolarLight.app" of container window to {140, 180}
        set position of item "Applications" of container window to {400, 180}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Persist Finder metadata to the volume.
sync
sleep 1

# Bless the volume so Finder uses our window settings on first open.
bless --folder "$MOUNT_POINT" --openfolder "$MOUNT_POINT" >/dev/null 2>&1 || true

# Set a custom volume icon (uses the app icon).
if [[ -f "$ASSETS_DIR/AppIcon.icns" ]]; then
  cp "$ASSETS_DIR/AppIcon.icns" "$MOUNT_POINT/.VolumeIcon.icns"
  SetFile -c icnC "$MOUNT_POINT/.VolumeIcon.icns" 2>/dev/null || true
  SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
fi

sync
hdiutil detach "$DEVICE" -quiet >/dev/null
trap - EXIT

# Convert to compressed read-only DMG.
hdiutil convert "$DMG_TEMP_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$DMG_TEMP_PATH"

echo "$DMG_PATH"
