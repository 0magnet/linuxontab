// WASI preview1 bridge: lets a GOOS=wasip1 Go binary (or any other
// wasi_snapshot_preview1 command module) run as a normal guest process.
//
// Every WASI call is served with this guest's own Linux syscalls through the
// worker's linux.syscall closure, so a WASI program is a real process: its fds
// are kernel fds (pipes, ttys, sockets, /proc all work), paths go through the
// guest VFS, and exit/kill/wait behave as for C programs. The module must
// import the kernel's shared memory (env.memory); tools/go-wasm-lot.py rewrites
// a Go binary's own memory into that import.
//
// What WASI has no notion of is filled in Linux-style: the whole filesystem is
// one preopen ("/", opened on first use), cwd comes from $PWD (added from
// getcwd when the shell did not export it), files are created 0666 and
// directories 0777 (minus umask), SIGPIPE is ignored so a dead peer is an
// EPIPE error instead of a kill, and Linux errnos are renumbered to WASI's.
//
// Scratch memory: syscalls that need a kernel-visible buffer (NUL-terminated
// paths, statx, timespecs, pollfds, getdents) use [SCRATCH, SCRATCH_END). Go's
// wasm linker never places anything below 12288 (wasmMinDataAddr: a 4 KiB
// null page + 8 KiB that only GOOS=js uses for argv), and Go's heap starts
// after its data, so that range is free for the whole life of a wasip1 Go
// process. Other WASI producers must leave it alone too (wasi-libc starts its
// data at 1024 — such modules are not supported yet).

export const SCRATCH = 1024, SCRATCH_END = 12288;

export function isWasiModule(module) {
    return WebAssembly.Module.imports(module).some((i) => i.module === 'wasi_snapshot_preview1');
}

export function makeWasiImports({ memory, kernel, syscall, log }) {
    const B = BigInt;
    const dbg = log || (() => {});
    const sc = (nr, a0 = 0, a1 = 0, a2 = 0, a3 = 0, a4 = 0, a5 = 0) => syscall(nr, a0 | 0, a1 | 0, a2 | 0, a3 | 0, a4 | 0, a5 | 0) | 0;
    const dv = () => new DataView(memory.buffer);
    const u8 = () => new Uint8Array(memory.buffer);
    const lo = (x) => Number(B.asUintN(32, B(x))) | 0;
    const hi = (x) => Number(B.asUintN(32, B.asUintN(64, B(x)) >> 32n)) | 0;
    const u32 = (x) => x >>> 0;

    let sp = SCRATCH;
    const reset = () => { sp = SCRATCH; };
    const scratch = (size, align = 8) => {
        sp = (sp + align - 1) & ~(align - 1);
        const p = sp; sp += size;
        if (sp > SCRATCH_END) throw new Error('wasi scratch overflow');
        return p;
    };
    const emptyStr = () => { const p = scratch(1, 1); u8()[p] = 0; return p; };
    // WASI paths are (ptr, len) without a terminator; the kernel wants a C string.
    const cpath = (ptr, len) => {
        len = u32(len);
        if (len >= 4096) return -1;
        const p = scratch(len + 1, 1);
        const m = u8();
        m.copyWithin(p, u32(ptr), u32(ptr) + len);
        m[p + len] = 0;
        return p;
    };

    // ---- errno: Linux -> WASI ---------------------------------------------
    const LINUX_TO_WASI = {
        1: 63, 2: 44, 3: 71, 4: 27, 5: 29, 6: 60, 7: 1, 8: 45, 9: 8, 10: 12, 11: 6, 12: 48, 13: 2, 14: 21,
        16: 10, 17: 20, 18: 75, 19: 43, 20: 54, 21: 31, 22: 28, 23: 41, 24: 33, 25: 59, 26: 74, 27: 22,
        28: 51, 29: 70, 30: 69, 31: 34, 32: 64, 33: 18, 34: 68, 35: 16, 36: 37, 37: 46, 38: 52, 39: 55,
        40: 32, 42: 49, 43: 24, 61: 49, 67: 47, 71: 65, 72: 36, 74: 9, 75: 61, 84: 25, 88: 57, 89: 17,
        90: 35, 91: 67, 92: 50, 93: 66, 94: 66, 95: 58, 96: 58, 97: 5, 98: 3, 99: 4, 100: 38, 101: 40,
        102: 39, 103: 13, 104: 15, 105: 42, 106: 30, 107: 53, 108: 64, 110: 73, 111: 14, 112: 23, 113: 23,
        114: 7, 115: 26, 116: 72, 122: 19, 125: 11, 130: 62, 131: 56,
    };
    const E = (r) => (r >= 0 ? 0 : (LINUX_TO_WASI[-r] ?? 29));   // unknown -> EIO
    const W = { SUCCESS: 0, BADF: 8, INVAL: 28, NOTDIR: 54, NAMETOOLONG: 37, FAULT: 21, NOSYS: 52, INTR: 27 };

    const AT_FDCWD = -100, AT_EMPTY_PATH = 0x1000, AT_SYMLINK_NOFOLLOW = 0x100, AT_SYMLINK_FOLLOW = 0x400, AT_REMOVEDIR = 0x200;
    const O_WRONLY = 1, O_RDWR = 2, O_CREAT = 0x40, O_EXCL = 0x80, O_TRUNC = 0x200, O_APPEND = 0x400, O_NONBLOCK = 0x800,
        O_DSYNC = 0x1000, O_LARGEFILE = 0x8000, O_DIRECTORY = 0x10000, O_NOFOLLOW = 0x20000, O_CLOEXEC = 0x80000, O_SYNC = 0x101000;
    const FDFLAG_APPEND = 1, FDFLAG_DSYNC = 2, FDFLAG_NONBLOCK = 4, FDFLAG_RSYNC = 8, FDFLAG_SYNC = 16;
    const RIGHT_FD_READ = 1 << 1, RIGHT_FD_WRITE = 1 << 6, RIGHT_FD_READDIR = 1 << 14;
    const ALL_RIGHTS = 0x1fffffffn;

    // ---- process setup (args, env, SIGPIPE) on the first call ---------------
    let proc = null;
    const setup = () => {
        if (proc) return proc;
        proc = { argv: [], envp: [] };
        // SIGPIPE -> SIG_IGN (kernel sigaction: handler, flags, mask[2])
        reset();
        const act = scratch(16);
        u8().fill(0, act, act + 16);
        dv().setUint32(act, 1, true);
        sc(134, 13, act, 0, 8);
        // argv/envp: the kernel copies one {len, envc, argc, argv*, envp*, data[]}
        // block into user memory. It may be bigger than the scratch area, so
        // borrow the top of the memory — far above Go's heap this early (the
        // kernel gives every process >= 128 MiB) — and zero it afterwards: Go
        // relies on memory it has not sbrk'd yet being zero.
        try {
            const len = kernel.exports.get_args_length();
            if (len > 0) {
                const size = (len + 15) & ~15;
                const buf = memory.buffer.byteLength - size;
                const r = kernel.exports.get_args(buf);
                if (r >= 0) {
                    const d = dv(), m = u8();
                    const envc = d.getInt32(buf + 4, true), argc = d.getInt32(buf + 8, true);
                    const argv = d.getUint32(buf + 12, true), envp = d.getUint32(buf + 16, true);
                    const cstr = (p) => { let e = p; while (m[e]) e++; return m.slice(p, e); };
                    for (let i = 0; i < argc; i++) proc.argv.push(cstr(d.getUint32(argv + 4 * i, true)));
                    for (let i = 0; i < envc; i++) proc.envp.push(cstr(d.getUint32(envp + 4 * i, true)));
                }
                u8().fill(0, buf, buf + size);
            }
        } catch (e) { dbg('wasi: get_args failed: ' + e); }
        const dec = new TextDecoder();
        if (!proc.envp.some((e) => dec.decode(e.subarray(0, 4)) === 'PWD=')) {
            reset();
            const p = scratch(4096, 1);
            const r = sc(17, p, 4096);                                   // getcwd
            if (r > 0) proc.envp.push(new TextEncoder().encode('PWD=' + dec.decode(u8().slice(p, p + r - 1))));
        }
        if (proc.envp.some((e) => dec.decode(e) === 'WASI_DEBUG=1')) proc.debug = true;
        return proc;
    };
    const sizes = (list, pCount, pBytes) => {
        const d = dv();
        d.setUint32(u32(pCount), list.length, true);
        d.setUint32(u32(pBytes), list.reduce((n, s) => n + s.length + 1, 0), true);
        return 0;
    };
    const fill = (list, pPtrs, pBuf) => {
        const d = dv(), m = u8();
        let at = u32(pBuf);
        list.forEach((s, i) => { d.setUint32(u32(pPtrs) + 4 * i, at, true); m.set(s, at); m[at + s.length] = 0; at += s.length + 1; });
        return 0;
    };

    // ---- preopen: the whole tree as one "/" directory ------------------------
    let preFd = -1;
    const preopen = () => {
        if (preFd < 0) {
            reset();
            const p = scratch(2, 1); u8()[p] = 0x2f; u8()[p + 1] = 0;
            preFd = sc(56, AT_FDCWD, p, O_DIRECTORY | O_CLOEXEC | O_LARGEFILE, 0);
            if (preFd < 0) dbg('wasi: cannot open / (' + preFd + ')');
        }
        return preFd;
    };

    // ---- stat ------------------------------------------------------------------
    const ftype = (mode) => {
        switch (mode & 0xf000) {
            case 0x4000: return 3; case 0x8000: return 4; case 0xa000: return 7;
            case 0x2000: return 2; case 0x6000: return 1; case 0xc000: return 6;
            default: return 0;
        }
    };
    const statx = (dirfd, path, flags) => {
        const sx = scratch(256);
        const r = sc(291, dirfd, path, flags, 0x7ff, sx);                // statx(STATX_BASIC_STATS)
        return r < 0 ? r : sx;
    };
    const putFilestat = (sx, out) => {
        const d = dv();
        const ns = (o) => d.getBigInt64(sx + o, true) * 1000000000n + B(d.getUint32(sx + o + 8, true));
        const dev = (B(d.getUint32(sx + 136, true)) << 32n) | B(d.getUint32(sx + 140, true));
        d.setBigUint64(out + 0, dev, true);
        d.setBigUint64(out + 8, d.getBigUint64(sx + 32, true), true);
        u8().fill(0, out + 16, out + 24);
        u8()[out + 16] = ftype(d.getUint16(sx + 28, true));
        d.setBigUint64(out + 24, B(d.getUint32(sx + 16, true)), true);
        d.setBigUint64(out + 32, d.getBigUint64(sx + 40, true), true);
        d.setBigUint64(out + 40, B.asUintN(64, ns(64)), true);
        d.setBigUint64(out + 48, B.asUintN(64, ns(112)), true);
        d.setBigUint64(out + 56, B.asUintN(64, ns(96)), true);
    };
    const sockType = (fd) => {
        const v = scratch(4), l = scratch(4);
        dv().setUint32(l, 4, true);
        return sc(209, fd, 1, 3, v, l) === 0 && dv().getInt32(v, true) === 2 ? 5 : 6;   // SOL_SOCKET, SO_TYPE; SOCK_DGRAM
    };

    // ---- poll_oneoff ---------------------------------------------------------------
    const now = (clk) => {
        const ts = scratch(16);
        if (sc(403, clk, ts) !== 0) return 0n;
        const d = dv();
        return d.getBigInt64(ts, true) * 1000000000n + d.getBigInt64(ts + 8, true);
    };
    const poll_oneoff = (inp, out, nsubs, pNevents) => {
        reset();
        inp = u32(inp); out = u32(out); nsubs = u32(nsubs);
        const d0 = dv();
        const subs = [];
        let fds = 0, nfds = 0, deadline = null;                       // deadline: {clk, at} with the earliest absolute time
        const timers = [];
        for (let i = 0; i < nsubs; i++) {
            const s = inp + 48 * i;
            const tag = d0.getUint8(s + 8);
            const sub = { ud: d0.getBigUint64(s, true), tag };
            if (tag === 0) {
                const clk = d0.getUint32(s + 16, true), t = d0.getBigUint64(s + 24, true), abs = d0.getUint16(s + 40, true) & 1;
                sub.clk = clk;
                sub.at = abs ? t : now(clk) + t;
                timers.push(sub);
            } else if (tag === 1 || tag === 2) {
                sub.fd = d0.getInt32(s + 16, true);
                sub.slot = nfds++;
            }
            subs.push(sub);
        }
        if (nfds) {
            fds = scratch(8 * nfds);
            const d = dv();
            for (const s of subs) if (s.slot !== undefined) {
                d.setInt32(fds + 8 * s.slot, s.fd, true);
                d.setInt16(fds + 8 * s.slot + 4, s.tag === 1 ? 1 : 4, true); // POLLIN / POLLOUT
                d.setInt16(fds + 8 * s.slot + 6, 0, true);
            }
        }
        let ts = 0;
        if (timers.length) {
            // All clocks are compared on their own timeline; poll sleeps for the shortest wait.
            let wait = null;
            for (const t of timers) { const w = t.at - now(t.clk); if (wait === null || w < wait) wait = w; }
            if (wait < 0n) wait = 0n;
            ts = scratch(16);
            dv().setBigInt64(ts, wait / 1000000000n, true);
            dv().setBigInt64(ts + 8, wait % 1000000000n, true);
        }
        const r = sc(414, fds, nfds, ts, 0, 8);                       // ppoll_time64
        if (r < 0 && r !== -4) return E(r);
        let n = 0;
        const d = dv();
        const emit = (s, err, type, flags) => {
            const e = out + 32 * n++;
            u8().fill(0, e, e + 32);
            d.setBigUint64(e, s.ud, true);
            d.setUint16(e + 8, err, true);
            d.setUint8(e + 10, type);
            d.setUint16(e + 24, flags, true);
        };
        for (const s of subs) {
            if (s.slot === undefined) continue;
            const re = d.getInt16(fds + 8 * s.slot + 6, true);
            if (!re) continue;
            if (re & 0x20) { emit(s, W.BADF, s.tag, 0); continue; }        // POLLNVAL
            emit(s, 0, s.tag, (re & 0x10) ? 1 : 0);                         // POLLHUP -> FD_READWRITE_HANGUP
        }
        for (const t of timers) if (now(t.clk) >= t.at) emit(t, 0, 0, 0);
        d.setUint32(u32(pNevents), n, true);
        return 0;
    };

    // ---- fd_readdir -----------------------------------------------------------------
    const DT = { 4: 3, 8: 4, 10: 7, 2: 2, 6: 1, 12: 6 };
    const fd_readdir = (fd, buf, len, cookie, pUsed) => {
        reset();
        buf = u32(buf); len = u32(len);
        const res = scratch(8);
        const c = B.asUintN(64, B(cookie));
        const lr = sc(62, fd, hi(c), lo(c), res, 0);                    // _llseek(SEEK_SET)
        if (lr < 0) return E(lr);
        const chunk = scratch(4096);
        let used = 0;
        outer: for (;;) {
            const r = sc(61, fd, chunk, 4096);                           // getdents64
            if (r < 0) return E(r);
            if (r === 0) break;
            const d = dv(), m = u8();
            for (let off = 0; off < r;) {
                const ent = chunk + off, reclen = d.getUint16(ent + 16, true);
                let nlen = 0; while (m[ent + 19 + nlen]) nlen++;
                const hdr = new Uint8Array(24), hv = new DataView(hdr.buffer);
                hv.setBigUint64(0, d.getBigUint64(ent + 8, true), true);  // d_next = d_off
                hv.setBigUint64(8, d.getBigUint64(ent, true), true);
                hv.setUint32(16, nlen, true);
                hv.setUint8(20, DT[m[ent + 18]] ?? 0);
                const rec = new Uint8Array(24 + nlen);
                rec.set(hdr); rec.set(m.subarray(ent + 19, ent + 19 + nlen), 24);
                const take = Math.min(rec.length, len - used);
                u8().set(rec.subarray(0, take), buf + used);
                used += take;
                if (used >= len) break outer;                              // full: caller resumes from a cookie
                off += reclen;
            }
        }
        dv().setUint32(u32(pUsed), used, true);
        return 0;
    };

    const fdflagsToO = (f) => (f & FDFLAG_APPEND ? O_APPEND : 0) | (f & FDFLAG_NONBLOCK ? O_NONBLOCK : 0) |
        (f & FDFLAG_SYNC ? O_SYNC : 0) | (f & (FDFLAG_DSYNC | FDFLAG_RSYNC) ? O_DSYNC : 0);
    const timespec = (p, ns) => { const d = dv(); d.setBigInt64(p, ns / 1000000000n, true); d.setBigInt64(p + 8, ns % 1000000000n, true); };

    let yields = 0;
    const wasi = {
        args_sizes_get: (pc, pb) => sizes(setup().argv, pc, pb),
        args_get: (pp, pb) => fill(setup().argv, pp, pb),
        environ_sizes_get: (pc, pb) => sizes(setup().envp, pc, pb),
        environ_get: (pp, pb) => fill(setup().envp, pp, pb),
        clock_res_get: (id, pRes) => { reset(); const ts = scratch(16); const r = sc(406, id, ts); if (r) return E(r); const d = dv(); d.setBigUint64(u32(pRes), B.asUintN(64, d.getBigInt64(ts, true) * 1000000000n + d.getBigInt64(ts + 8, true)), true); return 0; },
        clock_time_get: (id, _precision, pTime) => {
            reset();
            const ts = scratch(16), r = sc(403, id, ts);
            if (r) return E(r);
            const d = dv();
            d.setBigUint64(u32(pTime), B.asUintN(64, d.getBigInt64(ts, true) * 1000000000n + d.getBigInt64(ts + 8, true)), true);
            return 0;
        },
        fd_advise: () => 0,
        fd_allocate: (fd, off, len) => E(sc(47, fd, 0, lo(off), hi(off), lo(len), hi(len))),
        fd_close: (fd) => { if (fd === preFd) return 0; return E(sc(57, fd)); },
        fd_datasync: (fd) => E(sc(83, fd)),
        fd_sync: (fd) => E(sc(82, fd)),
        fd_fdstat_get: (fd, out) => {
            setup(); reset();
            const sx = statx(fd, emptyStr(), AT_EMPTY_PATH);
            if (sx < 0) return E(sx);
            let type = ftype(dv().getUint16(sx + 28, true));
            if (type === 6) type = sockType(fd);
            const fl = sc(25, fd, 3);                                     // F_GETFL
            if (fl < 0) return E(fl);
            const flags = (fl & O_APPEND ? FDFLAG_APPEND : 0) | (fl & O_NONBLOCK ? FDFLAG_NONBLOCK : 0) |
                ((fl & O_SYNC) === O_SYNC ? FDFLAG_SYNC : 0) | (fl & O_DSYNC ? FDFLAG_DSYNC : 0);
            const d = dv(); out = u32(out);
            u8().fill(0, out, out + 24);
            d.setUint8(out, type);
            d.setUint16(out + 2, flags, true);
            d.setBigUint64(out + 8, ALL_RIGHTS, true);
            d.setBigUint64(out + 16, ALL_RIGHTS, true);
            return 0;
        },
        fd_fdstat_set_flags: (fd, flags) => {
            const fl = sc(25, fd, 3);
            if (fl < 0) return E(fl);
            return E(sc(25, fd, 4, (fl & ~(O_APPEND | O_NONBLOCK)) | fdflagsToO(flags & (FDFLAG_APPEND | FDFLAG_NONBLOCK))));
        },
        fd_fdstat_set_rights: () => 0,
        fd_filestat_get: (fd, out) => { reset(); const sx = statx(fd, emptyStr(), AT_EMPTY_PATH); if (sx < 0) return E(sx); putFilestat(sx, u32(out)); return 0; },
        fd_filestat_set_size: (fd, size) => E(sc(46, fd, lo(size), hi(size))),          // ftruncate64
        fd_filestat_set_times: (fd, atim, mtim, fst) => {
            reset();
            const ts = scratch(32);
            const one = (p, t, set, nowBit) => { if (fst & nowBit) { timespec(p, 0n); dv().setBigInt64(p + 8, 0x3fffffffn, true); } else if (fst & set) timespec(p, B(t)); else { timespec(p, 0n); dv().setBigInt64(p + 8, 0x3ffffffen, true); } };
            one(ts, atim, 1, 2); one(ts + 16, mtim, 4, 8);
            return E(sc(412, fd, 0, ts, 0));                                 // utimensat_time64(fd, NULL)
        },
        fd_pread: (fd, iovs, n, off, pN) => { const r = sc(69, fd, iovs, n, lo(off), hi(off)); if (r < 0) return E(r); dv().setUint32(u32(pN), r, true); return 0; },
        fd_pwrite: (fd, iovs, n, off, pN) => { const r = sc(70, fd, iovs, n, lo(off), hi(off)); if (r < 0) return E(r); dv().setUint32(u32(pN), r, true); return 0; },
        fd_read: (fd, iovs, n, pN) => { const r = sc(65, fd, iovs, n); if (r < 0) return E(r); dv().setUint32(u32(pN), r, true); return 0; },
        fd_write: (fd, iovs, n, pN) => { const r = sc(66, fd, iovs, n); if (r < 0) return E(r); dv().setUint32(u32(pN), r, true); return 0; },
        fd_prestat_get: (fd, out) => {
            const p = preopen();
            if (p < 0 || fd > p) return W.BADF;
            if (fd < p) return W.NOTDIR;
            const d = dv(); out = u32(out);
            d.setUint32(out, 0, true);                                    // tag dir
            d.setUint32(out + 4, 1, true);                                // name length of "/"
            return 0;
        },
        fd_prestat_dir_name: (fd, path, len) => { if (fd !== preFd) return W.BADF; if (u32(len) < 1) return W.NAMETOOLONG; u8()[u32(path)] = 0x2f; return 0; },
        fd_readdir,
        fd_renumber: (from, to) => { const r = sc(24, from, to, 0); if (r < 0) return E(r); sc(57, from); return 0; },
        fd_seek: (fd, off, whence, pNew) => E(sc(62, fd, hi(off), lo(off), u32(pNew), whence)),   // _llseek writes the u64 result
        fd_tell: (fd, pNew) => E(sc(62, fd, 0, 0, u32(pNew), 1)),
        path_create_directory: (fd, path, len) => { reset(); const p = cpath(path, len); if (p < 0) return W.NAMETOOLONG; return E(sc(34, fd, p, 0o777)); },
        path_filestat_get: (fd, flags, path, len, out) => {
            reset();
            const p = cpath(path, len); if (p < 0) return W.NAMETOOLONG;
            const sx = statx(fd, p, (flags & 1) ? 0 : AT_SYMLINK_NOFOLLOW);
            if (sx < 0) return E(sx);
            putFilestat(sx, u32(out));
            return 0;
        },
        path_filestat_set_times: (fd, flags, path, len, atim, mtim, fst) => {
            reset();
            const p = cpath(path, len); if (p < 0) return W.NAMETOOLONG;
            const ts = scratch(32);
            const one = (q, t, set, nowBit) => { if (fst & nowBit) { timespec(q, 0n); dv().setBigInt64(q + 8, 0x3fffffffn, true); } else if (fst & set) timespec(q, B(t)); else { timespec(q, 0n); dv().setBigInt64(q + 8, 0x3ffffffen, true); } };
            one(ts, atim, 1, 2); one(ts + 16, mtim, 4, 8);
            return E(sc(412, fd, p, ts, (flags & 1) ? 0 : AT_SYMLINK_NOFOLLOW));
        },
        path_link: (ofd, oflags, op, ol, nfd, np, nl) => {
            reset();
            const a = cpath(op, ol), b = cpath(np, nl); if (a < 0 || b < 0) return W.NAMETOOLONG;
            return E(sc(37, ofd, a, nfd, b, (oflags & 1) ? AT_SYMLINK_FOLLOW : 0));
        },
        path_open: (fd, dirflags, path, len, oflags, rightsBase, _inherit, fdflags, pFd) => {
            setup(); reset();
            const p = cpath(path, len); if (p < 0) return W.NAMETOOLONG;
            const rb = B.asUintN(64, B(rightsBase));
            const r = (rb & B(RIGHT_FD_READ | RIGHT_FD_READDIR)) !== 0n, w = (rb & B(RIGHT_FD_WRITE)) !== 0n;
            let fl = (w ? (r ? O_RDWR : O_WRONLY) : 0) | O_LARGEFILE | O_CLOEXEC | fdflagsToO(fdflags);
            if (oflags & 1) fl |= O_CREAT;
            if (oflags & 2) fl |= O_DIRECTORY;
            if (oflags & 4) fl |= O_EXCL;
            if (oflags & 8) fl |= O_TRUNC;
            if (!(dirflags & 1)) fl |= O_NOFOLLOW;
            const nfd = sc(56, fd, p, fl, 0o666);
            if (nfd < 0) return E(nfd);
            dv().setUint32(u32(pFd), nfd, true);
            return 0;
        },
        path_readlink: (fd, path, len, buf, blen, pUsed) => {
            reset();
            const p = cpath(path, len); if (p < 0) return W.NAMETOOLONG;
            const r = sc(78, fd, p, buf, blen);
            if (r < 0) return E(r);
            dv().setUint32(u32(pUsed), r, true);
            return 0;
        },
        path_remove_directory: (fd, path, len) => { reset(); const p = cpath(path, len); if (p < 0) return W.NAMETOOLONG; return E(sc(35, fd, p, AT_REMOVEDIR)); },
        path_rename: (ofd, op, ol, nfd, np, nl) => {
            reset();
            const a = cpath(op, ol), b = cpath(np, nl); if (a < 0 || b < 0) return W.NAMETOOLONG;
            return E(sc(276, ofd, a, nfd, b, 0));
        },
        path_symlink: (op, ol, fd, np, nl) => {
            reset();
            const a = cpath(op, ol), b = cpath(np, nl); if (a < 0 || b < 0) return W.NAMETOOLONG;
            return E(sc(36, a, fd, b));
        },
        path_unlink_file: (fd, path, len) => { reset(); const p = cpath(path, len); if (p < 0) return W.NAMETOOLONG; return E(sc(35, fd, p, 0)); },
        poll_oneoff,
        proc_exit: (code) => { sc(94, code); throw new Error('wasi: exit_group returned'); },
        proc_raise: (sig) => E(sc(129, sc(172), sig)),
        random_get: (buf, len) => {
            buf = u32(buf); len = u32(len);
            for (let got = 0; got < len;) {
                const r = sc(278, buf + got, len - got, 0);
                if (r < 0) return E(r);
                got += r;
            }
            return 0;
        },
        sched_yield: () => {
            // A long run of yields with nothing else in between is a spin-wait
            // that can never end in a single-threaded runtime; say where.
            if (++yields === 100000) dbg('wasi: spinning in sched_yield:\n' + new Error().stack);
            return E(sc(124));
        },
        sock_accept: (fd, flags, pFd) => {
            const r = sc(242, fd, 0, 0, O_CLOEXEC | ((flags & FDFLAG_NONBLOCK) ? O_NONBLOCK : 0));   // accept4
            if (r < 0) return E(r);
            dv().setUint32(u32(pFd), r, true);
            return 0;
        },
        sock_recv: (fd, iovs, n, riflags, pN, pFlags) => {
            reset();
            const msg = scratch(28);
            u8().fill(0, msg, msg + 28);
            const d = dv();
            d.setUint32(msg + 8, u32(iovs), true); d.setUint32(msg + 12, n, true);
            const r = sc(212, fd, msg, ((riflags & 1) ? 2 : 0) | ((riflags & 2) ? 0x100 : 0));   // recvmsg: MSG_PEEK, MSG_WAITALL
            if (r < 0) return E(r);
            dv().setUint32(u32(pN), r, true);
            dv().setUint16(u32(pFlags), (dv().getUint32(msg + 24, true) & 0x20) ? 1 : 0, true);   // MSG_TRUNC -> RECV_DATA_TRUNCATED
            return 0;
        },
        sock_send: (fd, iovs, n, _flags, pN) => {
            reset();
            const msg = scratch(28);
            u8().fill(0, msg, msg + 28);
            const d = dv();
            d.setUint32(msg + 8, u32(iovs), true); d.setUint32(msg + 12, n, true);
            const r = sc(211, fd, msg, 0x4000);                          // sendmsg(MSG_NOSIGNAL)
            if (r < 0) return E(r);
            dv().setUint32(u32(pN), r, true);
            return 0;
        },
        sock_shutdown: (fd, how) => E(sc(210, fd, how === 1 ? 0 : how === 2 ? 1 : 2)),
    };
    // Optional per-call trace with WASI_DEBUG=1 in the environment.
    for (const [name, f] of Object.entries(wasi)) {
        const quiet = name === 'sched_yield' || name === 'clock_time_get';
        wasi[name] = (...a) => {
            if (!quiet) yields = 0;
            const r = f(...a);
            if (proc?.debug && name !== 'fd_write') dbg('wasi: ' + name + '(' + a.map(String).join(',') + ') = ' + r);
            return r;
        };
    }
    return { wasi_snapshot_preview1: wasi };
}
