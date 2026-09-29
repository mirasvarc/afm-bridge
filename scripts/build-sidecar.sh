#!/usr/bin/env bash
# Builds afm-bridge-server (arm64, release) and copies it into packages/darwin-arm64/bin.
#
# Usage: scripts/build-sidecar.sh [debug|release]
# Env:   CODESIGN_IDENTITY  signing identity (default "-" = ad hoc). Host apps re-sign
#                           the binary with their own Developer ID anyway, see README.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"
DEST="$ROOT/packages/darwin-arm64/bin/afm-bridge-server"

swift build --package-path "$ROOT/swift" -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build --package-path "$ROOT/swift" -c "$CONFIG" --arch arm64 --show-bin-path)"

mkdir -p "$(dirname "$DEST")"
cp "$BIN_DIR/afm-bridge-server" "$DEST"
chmod 755 "$DEST"
if [[ "$CONFIG" == "release" ]]; then
  strip -x "$DEST"
fi

# Hardened runtime is required for notarization of the host app.
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$DEST"

echo "Built $DEST"
echo "  $(lipo -archs "$DEST"), minimum macOS $(vtool -show-build "$DEST" | awk '/minos/ {print $2}'), $(du -h "$DEST" | cut -f1)"
