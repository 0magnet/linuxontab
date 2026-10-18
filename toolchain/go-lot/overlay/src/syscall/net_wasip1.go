// Copyright 2023 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build wasip1

// LinuxOnTab: real sockets for GOOS=wasip1.
//
// Upstream wasip1 has no sockets beyond sock_accept on a preopened listener.
// On LinuxOnTab a wasip1 program is an ordinary guest process of a real Linux
// kernel, which every module can reach through the runtime's
// linux.syscall(nr, a0..a5) import (the same one the C binaries use), so the
// socket calls below are plain Linux syscalls on 32-bit asm-generic numbers
// and layouts. Results are converted to WASI errno numbering, which is what
// this package's Errno values are on wasip1.
//
// The address family and socket type arguments take this package's wasip1
// constants (AF_INET=2, AF_INET6=3, SOCK_STREAM=1, ...), as package net passes
// them; levels and option names for the Getsockopt/Setsockopt calls are Linux
// values (SOL_SOCKET=1, SO_REUSEADDR=2, ...): package net is their only user.

package syscall

import (
	"runtime"
	"unsafe"
)

const (
	SHUT_RD   = 0x1
	SHUT_WR   = 0x2
	SHUT_RDWR = SHUT_RD | SHUT_WR
)

type sdflags = uint32

//go:wasmimport wasi_snapshot_preview1 sock_accept
//go:noescape
func sock_accept(fd int32, flags fdflags, newfd *int32) Errno

//go:wasmimport wasi_snapshot_preview1 sock_shutdown
//go:noescape
func sock_shutdown(fd int32, flags sdflags) Errno

//go:wasmimport linux syscall
func linux_syscall(nr, a0, a1, a2, a3, a4, a5 int32) int32

const (
	sysSocket      = 198
	sysBind        = 200
	sysListen      = 201
	sysConnect     = 203
	sysGetsockname = 204
	sysGetpeername = 205
	sysSendto      = 206
	sysRecvfrom    = 207
	sysSetsockopt  = 208
	sysGetsockopt  = 209
	sysShutdown    = 210
	sysSendmsg     = 211
	sysRecvmsg     = 212
	sysAccept4     = 242

	linuxAF_UNIX  = 1
	linuxAF_INET  = 2
	linuxAF_INET6 = 10

	linuxSOCK_NONBLOCK = 0x800
	linuxSOCK_CLOEXEC  = 0x80000
	linuxMSG_NOSIGNAL  = 0x4000
)

// linuxErrno maps a Linux errno to this package's WASI numbering.
var linuxErrno = [...]Errno{
	1: EPERM, 2: ENOENT, 3: ESRCH, 4: EINTR, 5: EIO, 6: ENXIO, 7: E2BIG, 8: ENOEXEC, 9: EBADF,
	10: ECHILD, 11: EAGAIN, 12: ENOMEM, 13: EACCES, 14: EFAULT, 16: EBUSY, 17: EEXIST, 18: EXDEV,
	19: ENODEV, 20: ENOTDIR, 21: EISDIR, 22: EINVAL, 23: ENFILE, 24: EMFILE, 25: ENOTTY, 26: ETXTBSY,
	27: EFBIG, 28: ENOSPC, 29: ESPIPE, 30: EROFS, 31: EMLINK, 32: EPIPE, 33: EDOM, 34: ERANGE,
	35: EDEADLK, 36: ENAMETOOLONG, 37: ENOLCK, 38: ENOSYS, 39: ENOTEMPTY, 40: ELOOP, 42: ENOMSG,
	43: EIDRM, 71: EPROTO, 72: EMULTIHOP, 74: EBADMSG, 75: EOVERFLOW, 84: EILSEQ, 88: ENOTSOCK,
	89: EDESTADDRREQ, 90: EMSGSIZE, 91: EPROTOTYPE, 92: ENOPROTOOPT, 93: EPROTONOSUPPORT,
	95: ENOTSUP, 97: EAFNOSUPPORT, 98: EADDRINUSE, 99: EADDRNOTAVAIL, 100: ENETDOWN,
	101: ENETUNREACH, 102: ENETRESET, 103: ECONNABORTED, 104: ECONNRESET, 105: ENOBUFS,
	106: EISCONN, 107: ENOTCONN, 110: ETIMEDOUT, 111: ECONNREFUSED, 113: EHOSTUNREACH,
	114: EALREADY, 115: EINPROGRESS, 116: ESTALE, 122: EDQUOT, 125: ECANCELED,
}

// LinuxErrno converts a Linux errno value (as returned by SO_ERROR) to an Errno.
func LinuxErrno(e int) Errno {
	if e == 0 {
		return 0
	}
	if e > 0 && e < len(linuxErrno) && linuxErrno[e] != 0 {
		return linuxErrno[e]
	}
	return EIO
}

// ret converts a raw linux.syscall result. Callers pass pointers straight into
// linux_syscall (an import: no Go call, so no stack move, between taking an
// address and the kernel using it).
func ret(r int32) (int, error) {
	if r < 0 {
		return -1, LinuxErrno(int(-r))
	}
	return int(r), nil
}

func p32(p unsafe.Pointer) int32 { return int32(uintptr(p)) }

func bufptr(b []byte) int32 {
	if len(b) == 0 {
		return 0
	}
	return int32(uintptr(unsafe.Pointer(&b[0])))
}

// rawSockaddr is a buffer big enough for any sockaddr the kernel returns.
type rawSockaddr [128]byte

func sockaddrBytes(sa Sockaddr) ([]byte, error) {
	switch v := sa.(type) {
	case *SockaddrInet4:
		if v == nil {
			return nil, EINVAL
		}
		b := make([]byte, 16)
		b[0] = linuxAF_INET
		b[2], b[3] = byte(v.Port>>8), byte(v.Port)
		copy(b[4:8], v.Addr[:])
		return b, nil
	case *SockaddrInet6:
		if v == nil {
			return nil, EINVAL
		}
		b := make([]byte, 28)
		b[0] = linuxAF_INET6
		b[2], b[3] = byte(v.Port>>8), byte(v.Port)
		copy(b[8:24], v.Addr[:])
		*(*uint32)(unsafe.Pointer(&b[24])) = v.ZoneId
		return b, nil
	case *SockaddrUnix:
		if v == nil || len(v.Name) >= 108 {
			return nil, EINVAL
		}
		b := make([]byte, 2+len(v.Name)+1)
		b[0] = linuxAF_UNIX
		copy(b[2:], v.Name)
		if len(v.Name) > 0 && v.Name[0] == '@' { // abstract socket
			b[2] = 0
			b = b[:len(b)-1]
		}
		return b, nil
	}
	return nil, EAFNOSUPPORT
}

func parseSockaddr(b []byte, n int) Sockaddr {
	if n < 2 {
		return nil
	}
	switch int(b[0]) | int(b[1])<<8 {
	case linuxAF_INET:
		sa := &SockaddrInet4{Port: int(b[2])<<8 | int(b[3])}
		copy(sa.Addr[:], b[4:8])
		return sa
	case linuxAF_INET6:
		sa := &SockaddrInet6{Port: int(b[2])<<8 | int(b[3])}
		copy(sa.Addr[:], b[8:24])
		sa.ZoneId = *(*uint32)(unsafe.Pointer(&b[24]))
		return sa
	case linuxAF_UNIX:
		name := b[2:n]
		if len(name) > 0 && name[0] == 0 {
			name = append([]byte{'@'}, name[1:]...)
		}
		for i, c := range name {
			if c == 0 {
				name = name[:i]
				break
			}
		}
		return &SockaddrUnix{Name: string(name)}
	}
	return nil
}

func Socket(proto, sotype, unused int) (fd int, err error) {
	var domain int
	switch proto {
	case AF_INET:
		domain = linuxAF_INET
	case AF_INET6:
		domain = linuxAF_INET6
	case AF_UNIX:
		domain = linuxAF_UNIX
	default:
		return -1, EAFNOSUPPORT
	}
	typ := sotype
	if typ == SOCK_SEQPACKET {
		typ = 5
	}
	return ret(linux_syscall(sysSocket, int32(domain), int32(typ|linuxSOCK_NONBLOCK|linuxSOCK_CLOEXEC), int32(unused), 0, 0, 0))
}

func Bind(fd int, sa Sockaddr) error {
	b, err := sockaddrBytes(sa)
	if err != nil {
		return err
	}
	_, err = ret(linux_syscall(sysBind, int32(fd), bufptr(b), int32(len(b)), 0, 0, 0))
	runtime.KeepAlive(b)
	return err
}

func StopIO(fd int) error {
	return ENOSYS
}

func Listen(fd int, backlog int) error {
	_, err := ret(linux_syscall(sysListen, int32(fd), int32(backlog), 0, 0, 0, 0))
	return err
}

func Accept(fd int) (int, Sockaddr, error) {
	var rsa rawSockaddr
	l := uint32(len(rsa))
	nfd, err := ret(linux_syscall(sysAccept4, int32(fd), p32(unsafe.Pointer(&rsa[0])), p32(unsafe.Pointer(&l)), int32(linuxSOCK_CLOEXEC), 0, 0))
	if err != nil {
		return -1, nil, err
	}
	return nfd, parseSockaddr(rsa[:], int(l)), nil
}

func Connect(fd int, sa Sockaddr) error {
	b, err := sockaddrBytes(sa)
	if err != nil {
		return err
	}
	_, err = ret(linux_syscall(sysConnect, int32(fd), bufptr(b), int32(len(b)), 0, 0, 0))
	runtime.KeepAlive(b)
	return err
}

func sockname(nr, fd int) (Sockaddr, error) {
	var rsa rawSockaddr
	l := uint32(len(rsa))
	if _, err := ret(linux_syscall(int32(nr), int32(fd), p32(unsafe.Pointer(&rsa[0])), p32(unsafe.Pointer(&l)), 0, 0, 0)); err != nil {
		return nil, err
	}
	return parseSockaddr(rsa[:], int(l)), nil
}

// Getsockname returns the local address of a socket (LinuxOnTab).
func Getsockname(fd int) (Sockaddr, error) { return sockname(sysGetsockname, fd) }

// Getpeername returns the remote address of a connected socket (LinuxOnTab).
func Getpeername(fd int) (Sockaddr, error) { return sockname(sysGetpeername, fd) }

func Recvfrom(fd int, p []byte, flags int) (n int, from Sockaddr, err error) {
	var rsa rawSockaddr
	l := uint32(len(rsa))
	n, err = ret(linux_syscall(sysRecvfrom, int32(fd), bufptr(p), int32(len(p)), int32(flags), p32(unsafe.Pointer(&rsa[0])), p32(unsafe.Pointer(&l))))
	runtime.KeepAlive(p)
	if err != nil {
		return 0, nil, err
	}
	return n, parseSockaddr(rsa[:], int(l)), nil
}

func Sendto(fd int, p []byte, flags int, to Sockaddr) error {
	var b []byte
	if to != nil {
		var err error
		if b, err = sockaddrBytes(to); err != nil {
			return err
		}
	}
	_, err := ret(linux_syscall(sysSendto, int32(fd), bufptr(p), int32(len(p)), int32(flags|linuxMSG_NOSIGNAL), bufptr(b), int32(len(b))))
	runtime.KeepAlive(p)
	runtime.KeepAlive(b)
	return err
}

// struct msghdr and struct iovec on 32-bit Linux.
type msghdr struct {
	name       uint32
	namelen    uint32
	iov        uint32
	iovlen     uint32
	control    uint32
	controllen uint32
	flags      int32
}

type iovec32 struct {
	base uint32
	len  uint32
}

func Recvmsg(fd int, p, oob []byte, flags int) (n, oobn, recvflags int, from Sockaddr, err error) {
	var rsa rawSockaddr
	iov := iovec32{base: uint32(bufptr(p)), len: uint32(len(p))}
	msg := msghdr{
		name: uint32(uintptr(unsafe.Pointer(&rsa[0]))), namelen: uint32(len(rsa)),
		iov: uint32(uintptr(unsafe.Pointer(&iov))), iovlen: 1,
		control: uint32(bufptr(oob)), controllen: uint32(len(oob)),
	}
	n, err = ret(linux_syscall(sysRecvmsg, int32(fd), p32(unsafe.Pointer(&msg)), int32(flags), 0, 0, 0))
	runtime.KeepAlive(p)
	runtime.KeepAlive(oob)
	if err != nil {
		return 0, 0, 0, nil, err
	}
	return n, int(msg.controllen), int(msg.flags), parseSockaddr(rsa[:], int(msg.namelen)), nil
}

func SendmsgN(fd int, p, oob []byte, to Sockaddr, flags int) (n int, err error) {
	var b []byte
	if to != nil {
		if b, err = sockaddrBytes(to); err != nil {
			return 0, err
		}
	}
	iov := iovec32{base: uint32(bufptr(p)), len: uint32(len(p))}
	msg := msghdr{
		name: uint32(bufptr(b)), namelen: uint32(len(b)),
		iov: uint32(uintptr(unsafe.Pointer(&iov))), iovlen: 1,
		control: uint32(bufptr(oob)), controllen: uint32(len(oob)),
	}
	n, err = ret(linux_syscall(sysSendmsg, int32(fd), p32(unsafe.Pointer(&msg)), int32(flags|linuxMSG_NOSIGNAL), 0, 0, 0))
	runtime.KeepAlive(p)
	runtime.KeepAlive(oob)
	runtime.KeepAlive(b)
	return n, err
}

// GetsockoptInt reads an int option; level and opt are Linux values.
func GetsockoptInt(fd, level, opt int) (value int, err error) {
	var v int32
	l := uint32(4)
	_, err = ret(linux_syscall(sysGetsockopt, int32(fd), int32(level), int32(opt), p32(unsafe.Pointer(&v)), p32(unsafe.Pointer(&l)), 0))
	return int(v), err
}

// SetsockoptInt sets an int option; level and opt are Linux values.
func SetsockoptInt(fd, level, opt int, value int) error {
	v := int32(value)
	_, err := ret(linux_syscall(sysSetsockopt, int32(fd), int32(level), int32(opt), p32(unsafe.Pointer(&v)), int32(4), 0))
	return err
}

// SetsockoptBytes sets an option from a raw buffer (LinuxOnTab); Linux level/opt.
func SetsockoptBytes(fd, level, opt int, b []byte) error {
	_, err := ret(linux_syscall(sysSetsockopt, int32(fd), int32(level), int32(opt), bufptr(b), int32(len(b)), 0))
	runtime.KeepAlive(b)
	return err
}

func SetReadDeadline(fd int, t int64) error {
	return ENOSYS
}

func SetWriteDeadline(fd int, t int64) error {
	return ENOSYS
}

func Shutdown(fd int, how int) error {
	var h int
	switch how {
	case SHUT_RD:
		h = 0
	case SHUT_WR:
		h = 1
	default:
		h = 2
	}
	_, err := ret(linux_syscall(sysShutdown, int32(fd), int32(h), 0, 0, 0, 0))
	return err
}
