// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build wasip1

// LinuxOnTab: real TCP/UDP for GOOS=wasip1.
//
// Upstream wasip1 (like js) gets an in-process fake network from net_fake.go.
// On LinuxOnTab, package syscall's wasip1 socket calls are real Linux
// syscalls (see syscall/net_wasip1.go), so this file gives wasip1 the unix
// implementation instead: socket() and the dial/listen paths are
// sock_posix.go + fd_unix.go, the netFD datagram methods are fd_posix.go, and
// the socket options are sockopt_linux.go / tcpsockopt_unix.go, all adapted to
// the netFD of fd_fake.go (whose embedded *fakeNetFD stays nil here; the
// methods below take precedence over the ones it would promote).

package net

import (
	"context"
	"internal/poll"
	"os"
	"runtime"
	"syscall"
	"time"
)

// Linux socket option levels and names (syscall's wasip1 constants are not
// the kernel's).
const (
	solSocket       = 1
	soReuseaddr     = 2
	soError         = 4
	soBroadcast     = 6
	soSndbuf        = 7
	soRcvbuf        = 8
	soKeepalive     = 9
	soLinger        = 13
	ipprotoTCP      = 6
	tcpNodelay      = 1
	tcpKeepidle     = 4
	tcpKeepintvl    = 5
	tcpKeepcnt      = 6
	ipprotoIPv6     = 41
	ipv6V6only      = 26
	readFromSysName = "recvfrom"
	readMsgSysName  = "recvmsg"
	writeToSysName  = "sendto"
	writeMsgSysName = "sendmsg"
)

func lotBoolint(b bool) int {
	if b {
		return 1
	}
	return 0
}

func socket(ctx context.Context, net string, family, sotype, proto int, ipv6only bool, laddr, raddr sockaddr, ctrlCtxFn func(context.Context, string, string, syscall.RawConn) error) (fd *netFD, err error) {
	s, err := socketFunc(family, sotype, proto)
	if err != nil {
		return nil, os.NewSyscallError("socket", err)
	}
	if err = setDefaultSockopts(s, family, sotype, ipv6only); err != nil {
		poll.CloseFunc(s)
		return nil, err
	}
	fd = &netFD{
		pfd: poll.FD{
			Sysfd:         s,
			IsStream:      sotype == syscall.SOCK_STREAM,
			ZeroReadIsEOF: sotype != syscall.SOCK_DGRAM && sotype != syscall.SOCK_RAW,
		},
		family: family,
		sotype: sotype,
		net:    net,
	}

	if laddr != nil && raddr == nil {
		switch sotype {
		case syscall.SOCK_STREAM, syscall.SOCK_SEQPACKET:
			if err := fd.listenStream(ctx, laddr, listenerBacklog(), ctrlCtxFn); err != nil {
				fd.Close()
				return nil, err
			}
			return fd, nil
		case syscall.SOCK_DGRAM:
			if err := fd.listenDatagram(ctx, laddr, ctrlCtxFn); err != nil {
				fd.Close()
				return nil, err
			}
			return fd, nil
		}
	}
	if err := fd.dial(ctx, laddr, raddr, ctrlCtxFn); err != nil {
		fd.Close()
		return nil, err
	}
	return fd, nil
}

func (fd *netFD) ctrlNetwork() string {
	switch fd.net {
	case "unix", "unixgram", "unixpacket":
		return fd.net
	}
	switch fd.net[len(fd.net)-1] {
	case '4', '6':
		return fd.net
	}
	if fd.family == syscall.AF_INET {
		return fd.net + "4"
	}
	return fd.net + "6"
}

func (fd *netFD) dial(ctx context.Context, laddr, raddr sockaddr, ctrlCtxFn func(context.Context, string, string, syscall.RawConn) error) error {
	var c *rawConn
	if ctrlCtxFn != nil {
		c = newRawConn(fd)
		var ctrlAddr string
		if raddr != nil {
			ctrlAddr = raddr.String()
		} else if laddr != nil {
			ctrlAddr = laddr.String()
		}
		if err := ctrlCtxFn(ctx, fd.ctrlNetwork(), ctrlAddr, c); err != nil {
			return err
		}
	}

	var lsa syscall.Sockaddr
	var err error
	if laddr != nil {
		if lsa, err = laddr.sockaddr(fd.family); err != nil {
			return err
		} else if lsa != nil {
			if err = syscall.Bind(fd.pfd.Sysfd, lsa); err != nil {
				return os.NewSyscallError("bind", err)
			}
		}
	}
	var rsa syscall.Sockaddr  // remote address from the user
	var crsa syscall.Sockaddr // remote address we actually connected to
	if raddr != nil {
		if rsa, err = raddr.sockaddr(fd.family); err != nil {
			return err
		}
		if crsa, err = fd.connect(ctx, lsa, rsa); err != nil {
			return err
		}
		fd.isConnected = true
	} else {
		if err := fd.init(); err != nil {
			return err
		}
	}
	lsa, _ = syscall.Getsockname(fd.pfd.Sysfd)
	if crsa != nil {
		fd.setAddr(fd.addrFunc()(lsa), fd.addrFunc()(crsa))
	} else if rsa, _ = syscall.Getpeername(fd.pfd.Sysfd); rsa != nil {
		fd.setAddr(fd.addrFunc()(lsa), fd.addrFunc()(rsa))
	} else {
		fd.setAddr(fd.addrFunc()(lsa), raddr)
	}
	return nil
}

func (fd *netFD) listenStream(ctx context.Context, laddr sockaddr, backlog int, ctrlCtxFn func(context.Context, string, string, syscall.RawConn) error) error {
	var err error
	if err = setDefaultListenerSockopts(fd.pfd.Sysfd); err != nil {
		return err
	}
	var lsa syscall.Sockaddr
	if lsa, err = laddr.sockaddr(fd.family); err != nil {
		return err
	}
	if ctrlCtxFn != nil {
		c := newRawConn(fd)
		if err := ctrlCtxFn(ctx, fd.ctrlNetwork(), laddr.String(), c); err != nil {
			return err
		}
	}
	if err = syscall.Bind(fd.pfd.Sysfd, lsa); err != nil {
		return os.NewSyscallError("bind", err)
	}
	if err = listenFunc(fd.pfd.Sysfd, backlog); err != nil {
		return os.NewSyscallError("listen", err)
	}
	if err = fd.init(); err != nil {
		return err
	}
	lsa, _ = syscall.Getsockname(fd.pfd.Sysfd)
	fd.setAddr(fd.addrFunc()(lsa), nil)
	return nil
}

func (fd *netFD) listenDatagram(ctx context.Context, laddr sockaddr, ctrlCtxFn func(context.Context, string, string, syscall.RawConn) error) error {
	switch addr := laddr.(type) {
	case *UDPAddr:
		// We provide a socket that listens to a wildcard address with
		// reusable UDP port when the given laddr is an appropriate UDP
		// multicast address prefix. This allows multiple sockets to listen
		// to the same multicast group.
		if addr.IP != nil && addr.IP.IsMulticast() {
			if err := setDefaultMulticastSockopts(fd.pfd.Sysfd); err != nil {
				return err
			}
			addr := *addr
			switch fd.family {
			case syscall.AF_INET:
				addr.IP = IPv4zero
			case syscall.AF_INET6:
				addr.IP = IPv6unspecified
			}
			laddr = &addr
		}
	}
	var err error
	var lsa syscall.Sockaddr
	if lsa, err = laddr.sockaddr(fd.family); err != nil {
		return err
	}
	if ctrlCtxFn != nil {
		c := newRawConn(fd)
		if err := ctrlCtxFn(ctx, fd.ctrlNetwork(), laddr.String(), c); err != nil {
			return err
		}
	}
	if err = syscall.Bind(fd.pfd.Sysfd, lsa); err != nil {
		return os.NewSyscallError("bind", err)
	}
	if err = fd.init(); err != nil {
		return err
	}
	lsa, _ = syscall.Getsockname(fd.pfd.Sysfd)
	fd.setAddr(fd.addrFunc()(lsa), nil)
	return nil
}

func (fd *netFD) connect(ctx context.Context, la, ra syscall.Sockaddr) (rsa syscall.Sockaddr, ret error) {
	switch err := connectFunc(fd.pfd.Sysfd, ra); err {
	case syscall.EINPROGRESS, syscall.EALREADY, syscall.EINTR:
	case nil, syscall.EISCONN:
		select {
		case <-ctx.Done():
			return nil, mapErr(ctx.Err())
		default:
		}
		if err := fd.pfd.Init(fd.net, true); err != nil {
			return nil, err
		}
		runtime.KeepAlive(fd)
		return nil, nil
	default:
		return nil, os.NewSyscallError("connect", err)
	}
	if err := fd.pfd.Init(fd.net, true); err != nil {
		return nil, err
	}
	if deadline, hasDeadline := ctx.Deadline(); hasDeadline {
		fd.pfd.SetWriteDeadline(deadline)
		defer fd.pfd.SetWriteDeadline(noDeadline)
	}

	// Wait for the connection, or for the context to be canceled: then the
	// write deadline is moved into the past to interrupt the wait.
	ctxDone := ctx.Done()
	if ctxDone != nil {
		done := make(chan struct{})
		interruptRes := make(chan error)
		defer func() {
			close(done)
			if ctxErr := <-interruptRes; ctxErr != nil && ret == nil {
				ret = mapErr(ctxErr)
				fd.Close()
			}
		}()
		go func() {
			select {
			case <-ctxDone:
				fd.pfd.SetWriteDeadline(aLongTimeAgo)
				testHookCanceledDial()
				interruptRes <- ctx.Err()
			case <-done:
				interruptRes <- nil
			}
		}()
	}

	for {
		if err := fd.pfd.WaitWrite(); err != nil {
			select {
			case <-ctxDone:
				return nil, mapErr(ctx.Err())
			default:
			}
			return nil, err
		}
		nerr, err := getsockoptIntFunc(fd.pfd.Sysfd, solSocket, soError)
		if err != nil {
			return nil, os.NewSyscallError("getsockopt", err)
		}
		switch err := syscall.LinuxErrno(nerr); err {
		case syscall.EINPROGRESS, syscall.EALREADY, syscall.EINTR:
		case syscall.EISCONN:
			return nil, nil
		case syscall.Errno(0):
			if rsa, err := syscall.Getpeername(fd.pfd.Sysfd); err == nil {
				return rsa, nil
			}
		default:
			return nil, os.NewSyscallError("connect", err)
		}
		runtime.KeepAlive(fd)
	}
}

// acceptInit gives a connection accepted on fd its real addresses.
func (fd *netFD) acceptInit(netfd *netFD, rsa syscall.Sockaddr) {
	netfd.family, netfd.sotype, netfd.net = fd.family, fd.sotype, fd.net
	if netfd.family == 0 { // listener from FileListener: no family recorded
		netfd.family, netfd.sotype = syscall.AF_INET, syscall.SOCK_STREAM
		if _, ok := rsa.(*syscall.SockaddrInet6); ok {
			netfd.family = syscall.AF_INET6
		}
	}
	lsa, _ := syscall.Getsockname(netfd.pfd.Sysfd)
	if la, ra := netfd.addrFunc()(lsa), netfd.addrFunc()(rsa); la != nil && ra != nil {
		netfd.setAddr(la, ra)
	}
}

func (fd *netFD) readFrom(p []byte) (n int, sa syscall.Sockaddr, err error) {
	n, sa, err = fd.pfd.ReadFrom(p)
	runtime.KeepAlive(fd)
	return n, sa, wrapSyscallError(readFromSysName, err)
}

func (fd *netFD) readFromInet4(p []byte, from *syscall.SockaddrInet4) (n int, err error) {
	n, err = fd.pfd.ReadFromInet4(p, from)
	runtime.KeepAlive(fd)
	return n, wrapSyscallError(readFromSysName, err)
}

func (fd *netFD) readFromInet6(p []byte, from *syscall.SockaddrInet6) (n int, err error) {
	n, err = fd.pfd.ReadFromInet6(p, from)
	runtime.KeepAlive(fd)
	return n, wrapSyscallError(readFromSysName, err)
}

func (fd *netFD) readMsg(p []byte, oob []byte, flags int) (n, oobn, retflags int, sa syscall.Sockaddr, err error) {
	n, oobn, retflags, sa, err = fd.pfd.ReadMsg(p, oob, flags)
	runtime.KeepAlive(fd)
	return n, oobn, retflags, sa, wrapSyscallError(readMsgSysName, err)
}

func (fd *netFD) readMsgInet4(p []byte, oob []byte, flags int, sa *syscall.SockaddrInet4) (n, oobn, retflags int, err error) {
	n, oobn, retflags, err = fd.pfd.ReadMsgInet4(p, oob, flags, sa)
	runtime.KeepAlive(fd)
	return n, oobn, retflags, wrapSyscallError(readMsgSysName, err)
}

func (fd *netFD) readMsgInet6(p []byte, oob []byte, flags int, sa *syscall.SockaddrInet6) (n, oobn, retflags int, err error) {
	n, oobn, retflags, err = fd.pfd.ReadMsgInet6(p, oob, flags, sa)
	runtime.KeepAlive(fd)
	return n, oobn, retflags, wrapSyscallError(readMsgSysName, err)
}

func (fd *netFD) writeTo(p []byte, sa syscall.Sockaddr) (n int, err error) {
	n, err = fd.pfd.WriteTo(p, sa)
	runtime.KeepAlive(fd)
	return n, wrapSyscallError(writeToSysName, err)
}

func (fd *netFD) writeToInet4(p []byte, sa *syscall.SockaddrInet4) (n int, err error) {
	n, err = fd.pfd.WriteToInet4(p, sa)
	runtime.KeepAlive(fd)
	return n, wrapSyscallError(writeToSysName, err)
}

func (fd *netFD) writeToInet6(p []byte, sa *syscall.SockaddrInet6) (n int, err error) {
	n, err = fd.pfd.WriteToInet6(p, sa)
	runtime.KeepAlive(fd)
	return n, wrapSyscallError(writeToSysName, err)
}

func (fd *netFD) writeMsg(p []byte, oob []byte, sa syscall.Sockaddr) (n int, oobn int, err error) {
	n, oobn, err = fd.pfd.WriteMsg(p, oob, sa)
	runtime.KeepAlive(fd)
	return n, oobn, wrapSyscallError(writeMsgSysName, err)
}

func (fd *netFD) writeMsgInet4(p []byte, oob []byte, sa *syscall.SockaddrInet4) (n int, oobn int, err error) {
	n, oobn, err = fd.pfd.WriteMsgInet4(p, oob, sa)
	runtime.KeepAlive(fd)
	return n, oobn, wrapSyscallError(writeMsgSysName, err)
}

func (fd *netFD) writeMsgInet6(p []byte, oob []byte, sa *syscall.SockaddrInet6) (n int, oobn int, err error) {
	n, oobn, err = fd.pfd.WriteMsgInet6(p, oob, sa)
	runtime.KeepAlive(fd)
	return n, oobn, wrapSyscallError(writeMsgSysName, err)
}

func (fd *netFD) dup() (f *os.File, err error) {
	ns, call, err := fd.pfd.Dup()
	if err != nil {
		if call != "" {
			err = os.NewSyscallError(call, err)
		}
		return nil, err
	}
	return os.NewFile(uintptr(ns), fd.name()), nil
}

// Socket options (sockopt_linux.go, sockopt_posix.go, tcpsockopt_unix.go).

func setDefaultSockopts(s, family, sotype int, ipv6only bool) error {
	if family == syscall.AF_INET6 && sotype != syscall.SOCK_RAW {
		// Allow both IP versions even if the OS default
		// is otherwise. Note that some operating systems
		// never admit this option.
		syscall.SetsockoptInt(s, ipprotoIPv6, ipv6V6only, lotBoolint(ipv6only))
	}
	if (sotype == syscall.SOCK_DGRAM || sotype == syscall.SOCK_RAW) && family != syscall.AF_UNIX {
		// Allow broadcast.
		return os.NewSyscallError("setsockopt", syscall.SetsockoptInt(s, solSocket, soBroadcast, 1))
	}
	return nil
}

func setDefaultListenerSockopts(s int) error {
	// Allow reuse of recently-used addresses.
	return os.NewSyscallError("setsockopt", syscall.SetsockoptInt(s, solSocket, soReuseaddr, 1))
}

func setDefaultMulticastSockopts(s int) error {
	// Allow multicast UDP and raw IP datagram sockets to listen
	// concurrently across multiple listeners.
	return os.NewSyscallError("setsockopt", syscall.SetsockoptInt(s, solSocket, soReuseaddr, 1))
}

// setsockoptInt is poll.FD.SetsockoptInt, which wasip1's internal/poll lacks.
func (fd *netFD) setsockoptInt(level, opt, value int) error {
	var err error
	if cerr := fd.pfd.RawControl(func(s uintptr) { err = syscall.SetsockoptInt(int(s), level, opt, value) }); cerr != nil {
		return cerr
	}
	return err
}

func setReadBuffer(fd *netFD, bytes int) error {
	err := fd.setsockoptInt(solSocket, soRcvbuf, bytes)
	runtime.KeepAlive(fd)
	return wrapSyscallError("setsockopt", err)
}

func setWriteBuffer(fd *netFD, bytes int) error {
	err := fd.setsockoptInt(solSocket, soSndbuf, bytes)
	runtime.KeepAlive(fd)
	return wrapSyscallError("setsockopt", err)
}

func setKeepAlive(fd *netFD, keepalive bool) error {
	err := fd.setsockoptInt(solSocket, soKeepalive, lotBoolint(keepalive))
	runtime.KeepAlive(fd)
	return wrapSyscallError("setsockopt", err)
}

func setLinger(fd *netFD, sec int) error {
	var l [8]byte // struct linger { int l_onoff; int l_linger; }
	if sec >= 0 {
		l[0] = 1
		l[4], l[5], l[6], l[7] = byte(sec), byte(sec>>8), byte(sec>>16), byte(sec>>24)
	}
	var err error
	if cerr := fd.pfd.RawControl(func(s uintptr) { err = syscall.SetsockoptBytes(int(s), solSocket, soLinger, l[:]) }); cerr != nil {
		return cerr
	}
	runtime.KeepAlive(fd)
	return wrapSyscallError("setsockopt", err)
}

func setNoDelay(fd *netFD, noDelay bool) error {
	err := fd.setsockoptInt(ipprotoTCP, tcpNodelay, lotBoolint(noDelay))
	runtime.KeepAlive(fd)
	return wrapSyscallError("setsockopt", err)
}

func setKeepAliveIdle(fd *netFD, d time.Duration) error {
	if d == 0 {
		d = defaultTCPKeepAliveIdle
	} else if d < 0 {
		return nil
	}
	secs := int(roundDurationUp(d, time.Second))
	err := fd.setsockoptInt(ipprotoTCP, tcpKeepidle, secs)
	runtime.KeepAlive(fd)
	return wrapSyscallError("setsockopt", err)
}

func setKeepAliveInterval(fd *netFD, d time.Duration) error {
	if d == 0 {
		d = defaultTCPKeepAliveInterval
	} else if d < 0 {
		return nil
	}
	secs := int(roundDurationUp(d, time.Second))
	err := fd.setsockoptInt(ipprotoTCP, tcpKeepintvl, secs)
	runtime.KeepAlive(fd)
	return wrapSyscallError("setsockopt", err)
}

func setKeepAliveCount(fd *netFD, n int) error {
	if n == 0 {
		n = defaultTCPKeepAliveCount
	} else if n < 0 {
		return nil
	}
	err := fd.setsockoptInt(ipprotoTCP, tcpKeepcnt, n)
	runtime.KeepAlive(fd)
	return wrapSyscallError("setsockopt", err)
}
