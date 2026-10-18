#!/bin/sh
# Build Syncthing v1.30.0 for the LinuxOnTab guest (GOOS=wasip1).
#   sh spikes/syncthing/build.sh [OUT]   (default /tmp/lot-build/syncthing-out/syncthing)
# Needs the toolchain/go-lot GOROOT (sh toolchain/go-lot/setup.sh).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ST_VERSION="${ST_VERSION:-v1.30.0}"
B="${LOT_BUILD:-/tmp/lot-build}"
SRC="$B/syncthing-${ST_VERSION#v}"
OUT="${1:-$B/syncthing-out/syncthing}"
mkdir -p "$(dirname "$OUT")"
export GOROOT="${GO_LOT:-$B/go-lot}" GOTOOLCHAIN=local
export PATH="$GOROOT/bin:$PATH"
[ -x "$GOROOT/bin/go" ] || sh "$REPO/toolchain/go-lot/setup.sh"
if [ ! -d "$SRC" ]; then
  git clone -q --depth 1 --branch "$ST_VERSION" https://github.com/syncthing/syncthing.git "$SRC"
  (cd "$SRC" && go mod vendor)
fi
sh "$HERE/apply.sh" "$SRC"
cd "$SRC"
STAMP=$(git log -1 --format=%ct)
SOURCE_DATE_EPOCH=$STAMP go generate -mod=vendor github.com/syncthing/syncthing/lib/api/auto   # GUI assets (apply.sh patches them)
P=github.com/syncthing/syncthing/lib/build
GOOS=wasip1 GOARCH=wasm go build -mod=vendor -tags noupgrade -trimpath \
  -ldflags "-s -w -X $P.Version=$ST_VERSION -X $P.Stamp=$STAMP -X $P.User=linuxontab -X $P.Host=linuxontab" \
  -o "$OUT.wasm" ./cmd/syncthing
python3 "$REPO/tools/go-wasm-lot.py" "$OUT.wasm" "$OUT"
