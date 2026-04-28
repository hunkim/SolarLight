#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/SolarLight.app"
DMG_STAGING_DIR="$BUILD_DIR/dmg"
DMG_PATH="$BUILD_DIR/SolarLight.dmg"

"$ROOT_DIR/Scripts/package-app.sh" >/dev/null

rm -rf "$DMG_STAGING_DIR" "$DMG_PATH"
mkdir -p "$DMG_STAGING_DIR"

cp -R "$APP_DIR" "$DMG_STAGING_DIR/SolarLight.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

hdiutil create \
  -volname "SolarLight" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "$DMG_PATH"
