#!/bin/sh
# Build the LinuxOnTab Go toolchain: a pristine Go release with this
# directory's patches, at $GO_LOT (default /tmp/lot-build/go-lot).
#
# GOOS=wasip1 programs built with it get real TCP/UDP through the guest
# kernel (overlay/: syscall/net_wasip1.go, internal/syscall/unix/net_wasip1.go,
# net/lot_*.go, plus the small edits below). Everything else about wasip1 —
# files, clocks, poll — is upstream, served at run time by the runtime's WASI
# bridge (shell/linux-dist-7.1/src/lot/wasi-bridge.js). Link output with
# tools/go-wasm-lot.py to make it loadable by the guest.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
GO_VERSION="${GO_VERSION:-1.25.5}"
GO_LOT="${GO_LOT:-/tmp/lot-build/go-lot}"
CACHE="${CACHE:-/tmp/lot-build}"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=darwin-arm64 ;; Darwin-x86_64) PLAT=darwin-amd64 ;;
  Linux-x86_64) PLAT=linux-amd64 ;; Linux-aarch64) PLAT=linux-arm64 ;;
  *) echo "unsupported host" >&2; exit 1 ;;
esac
TGZ="$CACHE/go$GO_VERSION.$PLAT.tar.gz"
[ -f "$TGZ" ] || curl -fL "https://go.dev/dl/go$GO_VERSION.$PLAT.tar.gz" -o "$TGZ"
rm -rf "$GO_LOT"; mkdir -p "$GO_LOT"
tar -xzf "$TGZ" -C "$GO_LOT" --strip-components=1
cp -R "$HERE/overlay/." "$GO_LOT/"
N="$GO_LOT/src/net"
# js keeps the fake network under a new name; wasip1 gets socket() from lot_wasip1.go.
sed -i.orig 's/^func socket(ctx context.Context/func fakeSocket(ctx context.Context/' "$N/net_fake.go"
sed -i.orig 's#^//go:build js || wasip1$#//go:build js#' "$N/sockopt_fake.go" "$N/tcpsockopt_stub.go"
# accepted connections get their real addresses
sed -i.orig 's/d, _, errcall, err := fd.pfd.Accept()/d, rsa, errcall, err := fd.pfd.Accept()/' "$N/fd_fake.go"
python3 - "$N/fd_fake.go" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """	netfd = newFD("tcp", d)
	if err = netfd.init(); err != nil {
		netfd.Close()
		return nil, err
	}
	return netfd, nil"""
assert old in s, "fd_fake.go accept changed upstream"
s = s.replace(old, old.replace("	return netfd, nil", "	fd.acceptInit(netfd, rsa)\n	return netfd, nil"))
open(p, "w").write(s)
PY
# runtime: an indefinite notetsleepg (os/signal's receive loop, profBuf.read)
# parks instead of spinning on sched_yield+Gosched. The spin kept a goroutine
# runnable forever, so the scheduler never blocked in poll_oneoff and socket
# readiness went unnoticed until deadlines expired (DNS "i/o timeout" in any
# program that calls signal.Notify), at 100% CPU.
python3 - "$GO_LOT/src/runtime/lock_wasip1.go" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old_wake = """	n.key = 1
}"""
new_wake = """	n.key = 1
	if gp := noteWaiters[n]; gp != nil {
		delete(noteWaiters, n)
		goready(gp, 1)
	}
}

// LinuxOnTab: goroutines parked in an indefinite notetsleepg.
var noteWaiters map[*note]*g"""
old_sleep = """	deadline := nanotime() + ns
	for {"""
new_sleep = """	if ns < 0 {
		for n.key == 0 {
			if noteWaiters == nil {
				noteWaiters = make(map[*note]*g)
			}
			noteWaiters[n] = gp
			gopark(nil, nil, waitReasonSleep, traceBlockForever, 1)
		}
		return true
	}

	deadline := nanotime() + ns
	for {"""
assert s.count(old_wake) == 1 and s.count(old_sleep) == 1, "lock_wasip1.go changed upstream"
s = s.replace(old_wake, new_wake).replace(old_sleep, new_sleep)
open(p, "w").write(s)
PY
# syscall: real permission bits (overlay/src/syscall/lot_fs_wasip1.go)
python3 - "$GO_LOT/src/syscall/fs_wasip1.go" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
reps = [
    ("""	errno := path_filestat_get(dirFd, LOOKUP_SYMLINK_FOLLOW, pathPtr, pathLen, unsafe.Pointer(st))
	setDefaultMode(st)""", """	errno := path_filestat_get(dirFd, LOOKUP_SYMLINK_FOLLOW, pathPtr, pathLen, unsafe.Pointer(st))
	lotPathMode(st, dirFd, pathPtr, pathLen, true)"""),
    ("""	errno := path_filestat_get(dirFd, 0, pathPtr, pathLen, unsafe.Pointer(st))
	setDefaultMode(st)""", """	errno := path_filestat_get(dirFd, 0, pathPtr, pathLen, unsafe.Pointer(st))
	lotPathMode(st, dirFd, pathPtr, pathLen, false)"""),
    ("""	errno := fd_filestat_get(int32(fd), unsafe.Pointer(st))
	setDefaultMode(st)""", """	errno := fd_filestat_get(int32(fd), unsafe.Pointer(st))
	lotFdMode(st, int32(fd))"""),
    ("""func Chmod(path string, mode uint32) error {
	var stat Stat_t
	return Stat(path, &stat)
}""", """func Chmod(path string, mode uint32) error {
	if path == "" {
		return EINVAL
	}
	dirFd, pathPtr, pathLen := preparePath(path)
	return lotChmod(dirFd, pathPtr, pathLen, mode)
}"""),
    ("""func Fchmod(fd int, mode uint32) error {
	var stat Stat_t
	return Fstat(fd, &stat)
}""", """func Fchmod(fd int, mode uint32) error {
	return lotFchmod(fd, mode)
}"""),
]
for a, b in reps:
    assert s.count(a) == 1, "fs_wasip1.go changed upstream: " + a[:40]
    s = s.replace(a, b)
open(p, "w").write(s)
PY
python3 - "$GO_LOT/src/os/stat_wasip1.go" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """	if fs.sys.Filetype == syscall.FILETYPE_DIRECTORY {
		fs.mode |= 0700
	} else {
		fs.mode |= 0600
	}"""
new = """	// LinuxOnTab: syscall fills in the kernel's mode bits (lot_fs_wasip1.go).
	fs.mode |= FileMode(fs.sys.Mode & 0777)
	if fs.sys.Mode&0o4000 != 0 {
		fs.mode |= ModeSetuid
	}
	if fs.sys.Mode&0o2000 != 0 {
		fs.mode |= ModeSetgid
	}
	if fs.sys.Mode&0o1000 != 0 {
		fs.mode |= ModeSticky
	}"""
assert s.count(old) == 1, "stat_wasip1.go changed upstream"
open(p, "w").write(s.replace(old, new))
PY
# os.Hostname: the guest's hostname (overlay/src/os/sys_hostname_wasip1.go)
sed -i.orig 's#^//go:build darwin || dragonfly || freebsd || (js \&\& wasm) || netbsd || openbsd || wasip1$#//go:build darwin || dragonfly || freebsd || (js \&\& wasm) || netbsd || openbsd#' "$GO_LOT/src/os/sys_bsd.go"
grep -q '|| openbsd$' "$GO_LOT/src/os/sys_bsd.go" && rm -f "$GO_LOT/src/os/sys_bsd.go.orig"
grep -q '^func fakeSocket' "$N/net_fake.go" && grep -q '^//go:build js$' "$N/sockopt_fake.go" "$N/tcpsockopt_stub.go"
rm -f "$N"/*.orig
echo "$GO_LOT: go$GO_VERSION + LinuxOnTab wasip1 sockets"
