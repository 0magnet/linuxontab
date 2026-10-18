// Copyright (C) 2025 The Syncthing Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

//go:build wasip1

package osutil

import "errors"

func MaximizeOpenFileLimit() (int, error) {
	return 0, errors.New("not supported on wasip1")
}
