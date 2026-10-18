#!/bin/sh
# Recipe: syncthing — Syncthing v1.30.0, continuous peer-to-peer file sync.
#
#   syncthing serve --no-browser --gui-address=0.0.0.0:8384 &
#   (then: top bar > web view > guest port 8384, or the console row)
#
# Syncthing is Go, and Go has no Linux-on-wasm port, so this is a GOOS=wasip1
# build run as an ordinary guest process:
#   - toolchain/go-lot: Go 1.25.5 whose wasip1 syscall/net/os speak to the
#     guest kernel through the runtime's linux.syscall import — real TCP/UDP
#     sockets (dial, listen, accept, UDP, DNS, TLS), file modes, hostname — and
#     whose indefinite notetsleepg parks instead of spinning (os/signal's loop
#     kept the scheduler from ever blocking in poll_oneoff: 100% CPU, DNS
#     timeouts).
#   - the runtime serves the module's wasi_snapshot_preview1 imports from the
#     guest's own syscalls (shell/linux-dist-7.1/src/lot/wasi-bridge.js), and
#     tools/go-wasm-lot.py turns Go's own memory into the shared env.memory
#     import every guest process needs (1 GiB maximum, __lot_big_memory).
#   - spikes/syncthing/apply.sh: the wasip1 port of Syncthing itself — leveldb
#     and gofrs/flock locking (flock(2) via linux.syscall), no exec/monitor
#     process (always the inner process), no xattrs/SO_REUSEPORT/rlimits, an
#     inotify watcher read through Go's poller with a polling fallback (this
#     kernel has no inotify), and 2 s GUI event polls (the web view proxies
#     one request at a time, a 60 s long-poll held every other API call).
# Needs the runtime with the WASI bridge (shell/linux-dist-7.1, 2026-10-18+).
# Not asyncified: Go's wasm keeps its own stacks; a wasip1 process cannot
# fork or exec anyway.

NAME="syncthing"
SYNCTHING_UPSTREAM="1.30.0"
VERSION="${SYNCTHING_UPSTREAM}-r0"
DESCRIPTION="Syncthing: continuous peer-to-peer file synchronization (web GUI on :8384)"
SOURCE_URL="local:"
DEPENDS=""
NO_ASYNCIFY=1

build() {
    command -v git >/dev/null || { echo "syncthing: needs git" >&2; exit 1; }
    ST_VERSION="v$SYNCTHING_UPSTREAM" sh "$REPO_ROOT/spikes/syncthing/build.sh" "$BUILD_ROOT/syncthing" || exit 1
    mkdir -p "$STAGE/usr/local/bin"
    cp "$BUILD_ROOT/syncthing" "$STAGE/usr/local/bin/syncthing"
    chmod 755 "$STAGE/usr/local/bin/syncthing"
}
