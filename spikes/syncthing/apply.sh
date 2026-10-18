#!/bin/sh
# Port Syncthing v1.30.0 (source tree with `go mod vendor` done) to GOOS=wasip1
# for LinuxOnTab. Idempotent. Build with the toolchain/go-lot GOROOT.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
S="${1:?usage: apply.sh <syncthing-src>}"
cd "$S"
tag() { # tag FILE OLD NEW: rewrite the //go:build line
  sed -i.bak "s#^//go:build $2\$#//go:build $3#" "$1" && rm -f "$1.bak"
  grep -q "^//go:build $3\$" "$1" || { echo "apply.sh: build tag of $1 changed" >&2; exit 1; }
}
cp "$HERE/files/file_storage_wasip1.go" vendor/github.com/syndtr/goleveldb/leveldb/storage/
cp "$HERE/files/basicfs_fileinfo_wasip1.go" lib/fs/
# gofrs/flock (syncthing.lock): the unix implementation over a flock shim
F=vendor/github.com/gofrs/flock
sed -e 's#^//go:build darwin || dragonfly || freebsd || illumos || linux || netbsd || openbsd$#//go:build wasip1#' \
    -e '/"golang.org\/x\/sys\/unix"/d' "$F/flock_unix.go" > "$F/flock_wasip1.go"
grep -q '^//go:build wasip1$' "$F/flock_wasip1.go"
cp "$HERE/files/flock_wasip1_sys.go" "$F/"
tag "$F/flock_others.go" '(!unix \&\& !windows) || plan9' '(!unix \&\& !windows \&\& !wasip1) || plan9'
# no xattrs, no SO_REUSEPORT dialing (control_unsupported.go: plain sockets)
tag lib/fs/basicfs_xattr_unix.go '!windows \&\& !dragonfly \&\& !illumos \&\& !solaris \&\& !openbsd' '!windows \&\& !dragonfly \&\& !illumos \&\& !solaris \&\& !openbsd \&\& !wasip1'
tag lib/fs/basicfs_xattr_unsupported.go 'windows || dragonfly || illumos || solaris || openbsd' 'windows || dragonfly || illumos || solaris || openbsd || wasip1'
tag lib/dialer/control_unix.go '!solaris \&\& !windows' '!solaris \&\& !windows \&\& !wasip1'
tag lib/dialer/control_unsupported.go 'solaris' 'solaris || wasip1'
# no process priorities or rlimits through WASI
cp "$HERE/files/rlimit_wasip1.go" lib/osutil/
tag lib/osutil/rlimit_unix.go '!windows' '!windows \&\& !wasip1'
tag lib/osutil/lowprio_unix.go '(!windows \&\& !linux \&\& !ios) || android' '(!windows \&\& !linux \&\& !ios \&\& !wasip1) || android'
tag lib/osutil/lowprio_noop.go 'ios' 'ios || wasip1'
# total memory for usage reports: the guest has /proc/meminfo like Linux
sed 's#^package ur#//go:build wasip1\n\npackage ur#' lib/ur/memsize_linux.go > lib/ur/memsize_wasip1.go
# cmd/syncthing: no exec, no browser, no getrusage
cp "$HERE/files/main_wasip1.go" "$HERE/files/exec_unix.go" "$HERE/files/exec_windows.go" cmd/syncthing/
sed -i.bak 's#return syscall.Exec(binary, args, os.Environ())#return execSelf(binary, args)#' cmd/syncthing/monitor.go && rm -f cmd/syncthing/monitor.go.bak
grep -q 'return execSelf(binary, args)' cmd/syncthing/monitor.go
grep -q 'syscall\.' cmd/syncthing/monitor.go || sed -i.bak '/^	"syscall"$/d' cmd/syncthing/monitor.go
rm -f cmd/syncthing/monitor.go.bak
sed -i.bak 's#^	if options.InternalInnerProcess {$#	if options.InternalInnerProcess || noMonitor {#' cmd/syncthing/main.go && rm -f cmd/syncthing/main.go.bak
grep -q 'options.InternalInnerProcess || noMonitor' cmd/syncthing/main.go
tag cmd/syncthing/openurl_unix.go '!windows' '!windows \&\& !wasip1'
tag cmd/syncthing/perfstats_unsupported.go 'solaris || windows' 'solaris || windows || wasip1'
tag cmd/syncthing/perfstats_unix.go '!solaris \&\& !windows' '!solaris \&\& !windows \&\& !wasip1'
# filesystem watching: inotify through Go's poller (basicfs_watch_wasip1.go)
cp "$HERE/files/basicfs_watch_wasip1.go" lib/fs/
tag lib/fs/basicfs_watch.go '!(solaris \&\& !cgo) \&\& !(darwin \&\& !cgo) \&\& !(darwin \&\& kqueue) \&\& !(android \&\& amd64)' '!(solaris \&\& !cgo) \&\& !(darwin \&\& !cgo) \&\& !(darwin \&\& kqueue) \&\& !(android \&\& amd64) \&\& !wasip1'
# GUI: short event polls. The console's web view proxies a guest port one
# request at a time, so a 60 s /rest/events long-poll held every other API call
# (config saves, status) behind it; with timeout=2 the GUI polls every 2 s.
E=gui/default/syncthing/core/eventService.js
grep -q "lastID + '&timeout=2'" "$E" || sed -i.bak "s#urlbase + '/events?since=' + lastID)#urlbase + '/events?since=' + lastID + '\&timeout=2')#" "$E"
rm -f "$E.bak"; grep -q "lastID + '&timeout=2'" "$E"
C=gui/default/syncthing/core/syncthingController.js
sed -i.bak 's#"/events/disk?limit=25"#"/events/disk?limit=25\&timeout=2"#' "$C" && rm -f "$C.bak"
grep -q 'events/disk?limit=25&timeout=2' "$C"
# Keepalives under ~30 s: inside the guest a TCP stream idle for ~45-50 s
# stops delivering data (no FIN; a network-path issue, not this port), which
# dropped relay sessions (relay pings every 60 s, 2 min timeout) and device
# connections (BEP pings every 90 s) every few minutes. The relay client pings
# the relay itself (relays answer with a Pong) and BEP pings every 30 s.
python3 - lib/relay/client/static.go lib/protocol/protocol.go <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if "keepalive := time.NewTicker" not in s:
    old = """	timeout := time.NewTimer(c.messageTimeout)

	for {
		select {"""
    new = """	timeout := time.NewTimer(c.messageTimeout)
	keepalive := time.NewTicker(30 * time.Second) // LinuxOnTab: see spikes/syncthing/apply.sh
	defer keepalive.Stop()

	for {
		select {
		case <-keepalive.C:
			if err := protocol.WriteMessage(c.conn, protocol.Ping{}); err != nil {
				l.Debugln("Relay write:", err)
				return err
			}
"""
    assert s.count(old) == 1, "static.go changed"
    s = s.replace(old, new)
    old = """			case protocol.SessionInvitation:"""
    new = """			case protocol.Pong:

			case protocol.SessionInvitation:"""
    assert s.count(old) == 1
    s = s.replace(old, new)
    open(p, "w").write(s)
p = sys.argv[2]; s = open(p).read()
s = s.replace("PingSendInterval = 90 * time.Second", "PingSendInterval = 30 * time.Second // LinuxOnTab: was 90 s, see spikes/syncthing/apply.sh")
assert "PingSendInterval = 30 * time.Second" in s, "protocol.go changed"
open(p, "w").write(s)
PY
echo "syncthing: wasip1 patches applied"
