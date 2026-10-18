// Copyright 2023 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build wasip1

package os

// LinuxOnTab: the hostname of the guest kernel the wasip1 process runs on
// (upstream wasip1 answers a constant "wasip1" from sys_bsd.go's sysctl).
func hostname() (name string, err error) {
	f, err := Open("/proc/sys/kernel/hostname")
	if err != nil {
		return "", err
	}
	defer f.Close()
	var buf [512]byte
	n, err := f.Read(buf[:])
	if err != nil {
		return "", err
	}
	for n > 0 && (buf[n-1] == '\n' || buf[n-1] == 0) {
		n--
	}
	if n == 0 {
		return "localhost", nil
	}
	return string(buf[:n]), nil
}
