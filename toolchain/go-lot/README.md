# Go programs on the LinuxOnTab guest (GOOS=wasip1)

Go has no Linux-on-wasm port, but it has `GOOS=wasip1`. A wasip1 binary runs
here as an ordinary guest process:

- The 7.1 runtime serves the module's `wasi_snapshot_preview1` imports with the
  process's own Linux syscalls (`shell/linux-dist-7.1/src/lot/wasi-bridge.js`):
  the whole filesystem is one `/` preopen, fds are kernel fds, and exit, kill
  and wait behave as they do for C programs.
- `tools/go-wasm-lot.py` rewrites Go's own memory into the shared `env.memory`
  import every guest process needs (1 GiB maximum, `__lot_big_memory`).
- This toolchain (`setup.sh`, a pristine Go release plus `overlay/` and a few
  scripted edits) closes the gaps WASI leaves:
  - `syscall/net_wasip1.go`, `net/lot_wasip1.go`: real TCP/UDP sockets through
    the runtime's `linux.syscall` import (dial, listen, accept, UDP, socket
    options, DNS through the pure-Go resolver, TLS on top).
  - `runtime/lock_wasip1.go`: an indefinite `notetsleepg` parks instead of
    spinning. Upstream spins on `sched_yield` + `Gosched` forever once a
    program calls `signal.Notify`, so the scheduler never blocks in
    `poll_oneoff`: 100% CPU and socket deadlines that expire before readiness
    is noticed.
  - `os.Hostname` from `/proc`, and real permission bits and chmod
    (`syscall/lot_fs_wasip1.go`; WASI has no file modes).

Build:

    sh toolchain/go-lot/setup.sh                     # -> /tmp/lot-build/go-lot
    GOROOT=/tmp/lot-build/go-lot GOOS=wasip1 GOARCH=wasm \
      /tmp/lot-build/go-lot/bin/go build -o prog.wasm .
    python3 tools/go-wasm-lot.py prog.wasm prog      # guest-loadable

Do not build wasip1 binaries with the Homebrew Go on this machine. Its
GOROOT was hand-patched on 2026-06-01 for an old wasm3 `sock_*` experiment.

Not supported: `os/exec` and fork (wasip1 has no processes), signal handlers
(a signal's default action applies; SIGPIPE is ignored), inotify (the guest
kernel is built without it). `spikes/go-wasip1/` holds the test programs.
Syncthing (`packages/recipes/syncthing.sh`) is the first real user.
