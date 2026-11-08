#!/bin/zsh
# Builds StreamDisk.app into build/ and signs it with the local identity (see setup-signing.sh).
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

config=${1:-debug}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift build -c "$config" --product StreamDiskApp

NAME="StreamDisk Local Signing"
identity=$(security find-identity -p codesigning | awk -v n="\"$NAME\"" '$0 ~ n {print $2; exit}')
if [[ -z "$identity" ]]; then
  echo "No \"$NAME\" identity; run scripts/setup-signing.sh first." >&2
  exit 1
fi
if [[ ! -f oauth_client.json ]]; then
  echo "oauth_client.json is missing; the app needs it to sign in to Google." >&2
  exit 1
fi

version=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
version=${version:-0.1.0}
build=$(git rev-list --count HEAD)

app=build/StreamDisk.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$config/StreamDiskApp" "$app/Contents/MacOS/StreamDisk"
cp oauth_client.json "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.streamdisk</string>
  <key>CFBundleName</key><string>StreamDisk</string>
  <key>CFBundleDisplayName</key><string>StreamDisk</string>
  <key>CFBundleExecutable</key><string>StreamDisk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Chinmay Kudalkar</string>
</dict>
</plist>
PLIST

codesign --force --sign "$identity" --identifier app.streamdisk --options runtime "$app"
echo "Built and signed $app"
