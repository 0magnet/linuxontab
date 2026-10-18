// Copyright (C) 2025 The Syncthing Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

//go:build wasip1

// LinuxOnTab: a wasip1 process cannot start or exec other processes, so there
// is no browser to open and no monitor re-exec (run with --no-restart).

package main

import "errors"

var errWasip1 = errors.New("not supported on wasip1")

func openURL(url string) error { return errWasip1 }

func execSelf(binary string, args []string) error { return errWasip1 }

// noMonitor: run Syncthing in this process instead of as a monitored child.
const noMonitor = true
