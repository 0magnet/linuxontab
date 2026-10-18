#!/usr/bin/env python3
"""go-wasm-lot.py IN OUT [--max-mib N] — make a GOOS=wasip1 binary loadable as a guest process.

The kernel only executes modules that IMPORT their memory as a shared
env.memory with a maximum (it hands every process a SharedArrayBuffer-backed
memory it can copy syscall arguments in and out of). Go's wasm linker always
DEFINES its memory, so this rewrites the memory section into that import:

  memory (min, no max)   ->   import "env" "memory" (memory min MAX shared)

and adds an `__lot_big_memory` export so the runtime keeps the declared
maximum instead of capping the process at 256 MiB (Go's heap plus Syncthing's
working set needs more). Nothing else changes: Go's code never uses atomics, and
the memory index stays 0. The runtime serves the module's
wasi_snapshot_preview1 imports from shell/linux-dist-7.1/src/lot/wasi-bridge.js,
which keeps its scratch buffers in [1024, 12288): Go's linker never puts data
below 12288, and this tool refuses a module whose data starts lower.
"""
import sys


def leb_u(b, i):
    r = s = 0
    while True:
        x = b[i]; i += 1
        r |= (x & 0x7F) << s; s += 7
        if not x & 0x80:
            return r, i


def enc_u(v):
    out = bytearray()
    while True:
        x = v & 0x7F; v >>= 7
        if v:
            out.append(x | 0x80)
        else:
            out.append(x)
            return bytes(out)


def name(s):
    s = s.encode()
    return enc_u(len(s)) + s


def main():
    args = sys.argv[1:]
    max_mib = 1024
    if '--max-mib' in args:
        k = args.index('--max-mib'); max_mib = int(args[k + 1]); del args[k:k + 2]
    src, dst = args
    b = open(src, 'rb').read()
    assert b[:8] == b'\0asm\1\0\0\0', 'not a wasm module'
    secs = []
    i = 8
    while i < len(b):
        sid = b[i]; size, j = leb_u(b, i + 1)
        secs.append([sid, b[j:j + size]]); i = j + size

    # The WASI bridge's scratch range must be free of static data.
    for sid, payload in secs:
        if sid != 11:
            continue
        n, k = leb_u(payload, 0)
        for _ in range(n):
            kind, k = leb_u(payload, k)
            if kind == 1:                       # passive: no address
                pass
            else:
                if kind == 2:
                    _, k = leb_u(payload, k)    # memory index
                assert payload[k] == 0x41, 'data offset is not an i32.const'
                off, k = leb_u(payload, k + 1)  # (offsets this large never need the sign bit)
                assert payload[k] == 0x0B
                k += 1
                assert off >= 12288, f'data at {off} overlaps the WASI bridge scratch [1024, 12288)'
            size, k = leb_u(payload, k)
            k += size

    mem = [s for s in secs if s[0] == 5]
    assert len(mem) == 1, 'expected one memory section'
    p = mem[0][1]
    count, k = leb_u(p, 0)
    assert count == 1, 'expected one memory'
    flags = p[k]; k += 1
    mn, k = leb_u(p, k)
    mx = None
    if flags & 1:
        mx, k = leb_u(p, k)
    pages = max_mib * 16
    if mx is not None:
        pages = min(pages, mx)
    assert pages >= mn, f'max {pages} pages < min {mn}'
    entry = name('env') + name('memory') + bytes([2, 3]) + enc_u(mn) + enc_u(pages)

    imp = [s for s in secs if s[0] == 2]
    if imp:
        n, k = leb_u(imp[0][1], 0)
        imp[0][1] = enc_u(n + 1) + imp[0][1][k:] + entry
    else:
        # the import section goes right after the type section (id 1)
        at = next((x + 1 for x, s in enumerate(secs) if s[0] == 1), 0)
        secs.insert(at, [2, enc_u(1) + entry])
    secs = [s for s in secs if s[0] != 5]

    exp = [s for s in secs if s[0] == 7]
    assert exp, 'no export section'
    n, k = leb_u(exp[0][1], 0)
    exp[0][1] = enc_u(n + 1) + exp[0][1][k:] + name('__lot_big_memory') + bytes([2]) + enc_u(0)

    out = bytearray(b[:8])
    for sid, payload in secs:
        out += bytes([sid]) + enc_u(len(payload)) + payload
    open(dst, 'wb').write(out)
    print(f'{dst}: env.memory shared min={mn} max={pages} pages ({len(out)} bytes)')


if __name__ == '__main__':
    main()
