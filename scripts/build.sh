#!/bin/zsh
# Builds the streamdisk tool and signs it with the local identity (see setup-signing.sh).
# Usage: scripts/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

config=${1:-debug}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift build -c "$config"

NAME="StreamDisk Local Signing"
identity=$(security find-identity -p codesigning | awk -v n="\"$NAME\"" '$0 ~ n {print $2; exit}')
if [[ -z "$identity" ]]; then
  echo "No \"$NAME\" identity; run scripts/setup-signing.sh first." >&2
  exit 1
fi
binary=".build/$config/streamdisk"
codesign --force --sign "$identity" --identifier app.streamdisk.cli --options runtime "$binary"
echo "Built and signed $binary"
