#!/bin/zsh
# Builds a release StreamDisk.app and wraps it in build/StreamDisk-<version>.dmg with an
# Applications shortcut, ready to attach to a GitHub release.
# Usage: scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/StreamDisk.app/Contents/Info.plist)
dmg="build/StreamDisk-$version.dmg"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R build/StreamDisk.app "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "StreamDisk" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
echo "Packaged $dmg ($(du -h "$dmg" | cut -f1))"
