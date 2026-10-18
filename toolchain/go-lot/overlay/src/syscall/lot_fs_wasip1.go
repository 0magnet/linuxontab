// Copyright 2023 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build wasip1

// LinuxOnTab: real permission bits for GOOS=wasip1. WASI has no file modes, so
// upstream reports 0700/0600 for everything and makes Chmod a no-op; on
// LinuxOnTab the process runs on a real kernel, so Stat/Lstat/Fstat take the
// mode from statx and Chmod/Fchmod change it (linux.syscall, see net_wasip1.go).

package syscall

import "unsafe"

const (
	sysStatx    = 291
	sysFchmod   = 52
	sysFchmodat = 53

	atEmptyPath       = 0x1000
	atSymlinkNofollow = 0x100
	statxMode         = 0x2
)

// lotCPath copies a WASI (pointer, length) path into a NUL-terminated buffer.
func lotCPath(pathPtr *byte, pathLen size) []byte {
	b := make([]byte, pathLen+1)
	copy(b, unsafe.Slice(pathPtr, pathLen))
	return b
}

func lotStatxMode(dirFd int32, path []byte, flags int32) (uint32, bool) {
	var sx [256]byte
	r := linux_syscall(sysStatx, dirFd, int32(uintptr(unsafe.Pointer(&path[0]))), flags, statxMode, int32(uintptr(unsafe.Pointer(&sx[0]))), 0)
	if r != 0 {
		return 0, false
	}
	return uint32(sx[28]) | uint32(sx[29])<<8, true
}

// lotPathMode sets st.Mode from the kernel, or falls back to the defaults.
func lotPathMode(st *Stat_t, dirFd int32, pathPtr *byte, pathLen size, follow bool) {
	flags := int32(atSymlinkNofollow)
	if follow {
		flags = 0
	}
	if m, ok := lotStatxMode(dirFd, lotCPath(pathPtr, pathLen), flags); ok {
		st.Mode = int(m & 0o7777)
		return
	}
	setDefaultMode(st)
}

func lotFdMode(st *Stat_t, fd int32) {
	empty := []byte{0}
	if m, ok := lotStatxMode(fd, empty, atEmptyPath); ok {
		st.Mode = int(m & 0o7777)
		return
	}
	setDefaultMode(st)
}

func lotChmod(dirFd int32, pathPtr *byte, pathLen size, mode uint32) error {
	p := lotCPath(pathPtr, pathLen)
	_, err := ret(linux_syscall(sysFchmodat, dirFd, int32(uintptr(unsafe.Pointer(&p[0]))), int32(mode&0o7777), 0, 0, 0))
	return err
}

func lotFchmod(fd int, mode uint32) error {
	_, err := ret(linux_syscall(sysFchmod, int32(fd), int32(mode&0o7777), 0, 0, 0, 0))
	return err
}
