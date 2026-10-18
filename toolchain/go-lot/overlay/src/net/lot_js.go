// Copyright 2023 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build js

// LinuxOnTab: js keeps upstream's fake network; wasip1 has real sockets
// (lot_wasip1.go).

package net

import (
	"context"
	"syscall"
)

func socket(ctx context.Context, net string, family, sotype, proto int, ipv6only bool, laddr, raddr sockaddr, ctrlCtxFn func(context.Context, string, string, syscall.RawConn) error) (*netFD, error) {
	return fakeSocket(ctx, net, family, sotype, proto, ipv6only, laddr, raddr, ctrlCtxFn)
}

func (fd *netFD) acceptInit(netfd *netFD, rsa syscall.Sockaddr) {}
