// Copyright (C) 2025 The Syncthing Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

//go:build windows

package main

import "errors"

func execSelf(binary string, args []string) error {
	return errors.New("exec not supported on Windows")
}

// noMonitor: run Syncthing in this process instead of as a monitored child.
const noMonitor = false
