// Copyright (c) 2012, Suryandaru Triandana <syndtr@gmail.com>
// All rights reserved.
//
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

//go:build wasip1

// LinuxOnTab: file_storage_unix.go for GOOS=wasip1. The process runs on a
// real Linux kernel (the guest), so the lock is a real flock(2) through the
// runtime's linux.syscall import; the rest is plain os.

package storage

import (
	"os"
	"syscall"
)

//go:wasmimport linux syscall
func linuxSyscall(nr, a0, a1, a2, a3, a4, a5 int32) int32

type unixFileLock struct {
	f *os.File
}

func (fl *unixFileLock) release() error {
	if err := setFileLock(fl.f, false, false); err != nil {
		return err
	}
	return fl.f.Close()
}

func newFileLock(path string, readOnly bool) (fl fileLock, err error) {
	var flag int
	if readOnly {
		flag = os.O_RDONLY
	} else {
		flag = os.O_RDWR
	}
	f, err := os.OpenFile(path, flag, 0)
	if os.IsNotExist(err) {
		f, err = os.OpenFile(path, flag|os.O_CREATE, 0644)
	}
	if err != nil {
		return
	}
	err = setFileLock(f, readOnly, true)
	if err != nil {
		f.Close()
		return
	}
	fl = &unixFileLock{f: f}
	return
}

func setFileLock(f *os.File, readOnly, lock bool) error {
	const lockSH, lockEX, lockNB, lockUN = 1, 2, 4, 8
	how := lockUN
	if lock {
		if readOnly {
			how = lockSH
		} else {
			how = lockEX
		}
	}
	if r := linuxSyscall(32, int32(f.Fd()), int32(how|lockNB), 0, 0, 0, 0); r < 0 { // flock
		return syscall.LinuxErrno(int(-r))
	}
	return nil
}

func rename(oldpath, newpath string) error {
	return os.Rename(oldpath, newpath)
}

func isErrInvalid(err error) bool {
	if err == os.ErrInvalid {
		return true
	}
	if patherr, ok := err.(*os.PathError); ok && patherr.Err == syscall.EINVAL {
		return true
	}
	return false
}

func syncDir(name string) error {
	f, err := os.Open(name)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := f.Sync(); err != nil && !isErrInvalid(err) {
		return err
	}
	return nil
}
