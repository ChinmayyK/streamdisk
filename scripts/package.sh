#!/bin/zsh
# Builds a release StreamDisk.app and wraps it in build/StreamDisk.dmg (a stable name, so
# releases/latest/download/StreamDisk.dmg always works): the app on the
# left, an Applications shortcut on the right, and a background (Design/dmg/background.svg,
# exported as a 1x + 2x TIFF) that also says how to open an app Apple hasn't notarized.
# Needs create-dmg (brew install create-dmg).
# Usage: scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/StreamDisk.app/Contents/Info.plist)
dmg="build/StreamDisk.dmg"
rm -f "$dmg"

create-dmg \
  --volname "StreamDisk" \
  --volicon "build/StreamDisk.app/Contents/Resources/AppIcon.icns" \
  --background "Design/dmg/background.tiff" \
  --window-pos 200 120 \
  --window-size 600 468 \
  --icon-size 128 \
  --text-size 13 \
  --icon "StreamDisk.app" 150 165 \
  --hide-extension "StreamDisk.app" \
  --app-drop-link 450 165 \
  "$dmg" \
  "build/StreamDisk.app" >/dev/null

shasum -a 256 "$dmg"
echo "Packaged $dmg, version $version ($(du -h "$dmg" | cut -f1))"
