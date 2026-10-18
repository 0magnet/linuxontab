// Copyright 2023 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build wasip1

// LinuxOnTab: the address-typed socket helpers internal/poll uses, on top of
// the real (Linux syscall) sockets in package syscall.

package unix

import (
	"syscall"
	_ "unsafe"
)

func RecvfromInet4(fd int, p []byte, flags int, from *syscall.SockaddrInet4) (int, error) {
	n, sa, err := syscall.Recvfrom(fd, p, flags)
	if sa4, ok := sa.(*syscall.SockaddrInet4); ok && from != nil {
		*from = *sa4
	}
	return n, err
}

func RecvfromInet6(fd int, p []byte, flags int, from *syscall.SockaddrInet6) (n int, err error) {
	n, sa, err := syscall.Recvfrom(fd, p, flags)
	if sa6, ok := sa.(*syscall.SockaddrInet6); ok && from != nil {
		*from = *sa6
	}
	return n, err
}

func SendtoInet4(fd int, p []byte, flags int, to *syscall.SockaddrInet4) (err error) {
	if to == nil {
		return syscall.Sendto(fd, p, flags, nil)
	}
	return syscall.Sendto(fd, p, flags, to)
}

func SendtoInet6(fd int, p []byte, flags int, to *syscall.SockaddrInet6) (err error) {
	if to == nil {
		return syscall.Sendto(fd, p, flags, nil)
	}
	return syscall.Sendto(fd, p, flags, to)
}

func SendmsgNInet4(fd int, p, oob []byte, to *syscall.SockaddrInet4, flags int) (n int, err error) {
	if to == nil {
		return syscall.SendmsgN(fd, p, oob, nil, flags)
	}
	return syscall.SendmsgN(fd, p, oob, to, flags)
}

func SendmsgNInet6(fd int, p, oob []byte, to *syscall.SockaddrInet6, flags int) (n int, err error) {
	if to == nil {
		return syscall.SendmsgN(fd, p, oob, nil, flags)
	}
	return syscall.SendmsgN(fd, p, oob, to, flags)
}

func RecvmsgInet4(fd int, p, oob []byte, flags int, from *syscall.SockaddrInet4) (n, oobn int, recvflags int, err error) {
	n, oobn, recvflags, sa, err := syscall.Recvmsg(fd, p, oob, flags)
	if sa4, ok := sa.(*syscall.SockaddrInet4); ok && from != nil {
		*from = *sa4
	}
	return n, oobn, recvflags, err
}

func RecvmsgInet6(fd int, p, oob []byte, flags int, from *syscall.SockaddrInet6) (n, oobn int, recvflags int, err error) {
	n, oobn, recvflags, sa, err := syscall.Recvmsg(fd, p, oob, flags)
	if sa6, ok := sa.(*syscall.SockaddrInet6); ok && from != nil {
		*from = *sa6
	}
	return n, oobn, recvflags, err
}
