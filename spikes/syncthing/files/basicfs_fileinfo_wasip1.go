// Copyright (C) 2025 The Syncthing Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

//go:build wasip1

package fs

import (
	"syscall"
	"time"
)

func (fi basicFileInfo) InodeChangeTime() time.Time {
	if sys, ok := fi.FileInfo.Sys().(*syscall.Stat_t); ok {
		return time.Unix(0, int64(sys.Ctime))
	}
	return time.Time{}
}
