#!/usr/bin/env bash
# Packs afm-bridge and afm-bridge-darwin-arm64 the way they would be published and puts the
# tarballs into examples/electron/vendor, so the example installs them like a registry package.
#
# Usage: scripts/pack-local.sh   (run scripts/build-sidecar.sh and `pnpm build` first)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/examples/electron/vendor"
BIN="$ROOT/packages/darwin-arm64/bin/afm-bridge-server"

[[ -x "$BIN" ]] || { echo "Missing $BIN, run scripts/build-sidecar.sh first" >&2; exit 1; }
[[ -f "$ROOT/packages/client/dist/index.js" ]] || { echo "Client not built, run pnpm build first" >&2; exit 1; }

rm -rf "$DEST" && mkdir -p "$DEST"
# pnpm pack rewrites `workspace:*` in afm-bridge. The binary package is packed with npm
# because pnpm 8 drops the executable bit of bin/afm-bridge-server.
(cd "$ROOT/packages/client" && pnpm pack --pack-destination "$DEST" >/dev/null)
(cd "$ROOT/packages/darwin-arm64" && npm pack --pack-destination "$DEST" --silent >/dev/null)
if ! tar tvzf "$DEST"/afm-bridge-darwin-arm64-*.tgz | grep -q '^-rwx.*bin/afm-bridge-server'; then
  echo "bin/afm-bridge-server is not executable in the tarball" >&2
  exit 1
fi
# Stable names so package.json can point at them regardless of the version.
for f in "$DEST"/*.tgz; do
  mv "$f" "$DEST/$(basename "$f" | sed -E 's/-[0-9]+\.[0-9]+\.[0-9]+.*\.tgz$/.tgz/')"
done
ls -1 "$DEST"
