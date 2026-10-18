// Copyright 2015 Tim Heckman. All rights reserved.
// Use of this source code is governed by the BSD 3-Clause
// license that can be found in the LICENSE file.

//go:build wasip1

// LinuxOnTab: flock_wasip1.go is flock_unix.go with golang.org/x/sys/unix
// (which has no wasip1 port) replaced by this shim: real flock(2) through
// the runtime's linux.syscall import.

package flock

import "syscall"

//go:wasmimport linux syscall
func linuxSyscall(nr, a0, a1, a2, a3, a4, a5 int32) int32

var unix = struct {
	LOCK_SH, LOCK_EX, LOCK_NB, LOCK_UN int
	EWOULDBLOCK, EIO, EBADF            error
	Flock                              func(fd, how int) error
}{
	LOCK_SH: 1, LOCK_EX: 2, LOCK_NB: 4, LOCK_UN: 8,
	EWOULDBLOCK: syscall.EAGAIN, EIO: syscall.EIO, EBADF: syscall.EBADF,
	Flock: func(fd, how int) error {
		if r := linuxSyscall(32, int32(fd), int32(how), 0, 0, 0, 0); r < 0 {
			return syscall.LinuxErrno(int(-r))
		}
		return nil
	},
}
