#!/bin/sh
# Recipe: memcached — the in-memory key/value cache, compiled to wasm32.
#
#   memcached -u root -l 0.0.0.0 -p 11211 &
#   printf 'set k 0 0 5\r\nhello\r\nget k\r\nquit\r\n' | nc 127.0.0.1 11211
#
# memcached is libevent + pthreads: a listener thread plus N worker threads
# (default 4), each with its own event_base, woken over eventfd. Plus a few
# housekeeping threads (LRU maintainer/crawler, slab rebalancer, logger).
#
# Build notes for this target:
#   - libevent 2.1.12 is built statically inside this recipe (no openssl, no
#     libevent thread support — memcached gives every thread its own
#     event_base and never calls evthread_use_pthreads). epoll backend.
#   - -Dlinux/-D__linux__: `-target wasm32` predefines neither; libevent and
#     memcached both select Linux paths (epoll, accept4, eventfd) from them.
#   - Threads: sysroot/wasm_clone.c (own stack + TLS per thread) and the
#     locked sbrk-only dlmalloc (wasm_dlmalloc_mt.c) linked before -lc.
#     memcached's slab allocator mallocs 1 MB pages — musl mallocng's
#     large-block path traps here, dlmalloc does not.
#   - setuid()/setgroups() return ENOSYS on this kernel. memcached refuses to
#     run as root without -u and then tries to switch to that user; the
#     drop-privileges block is patched to accept ENOSYS (the process simply
#     stays root, which is the only user the guest has anyway).
#   - restart.c (-e memory file, EXPERIMENTAL) wants file-backed MAP_SHARED
#     mmap + msync. The MAP_ANON shim refuses file mappings, so -e fails
#     cleanly at startup ("failed to mmap") instead of linking garbage.
#   - Explicit 8 MB main stack (wasm-ld default is 64 KB).

NAME="memcached"
MEMCACHED_UPSTREAM="1.6.45"
VERSION="${MEMCACHED_UPSTREAM}-r0"
DESCRIPTION="memcached in-memory key/value cache server (libevent, epoll, worker threads)"
SOURCE_URL="https://www.memcached.org/files/memcached-${MEMCACHED_UPSTREAM}.tar.gz"
SOURCE_SHA256="d362c64e6d8d5287153501eabf7c85b4a761432fbf53f5d7b085d0bb1653c1dd"

LIBEVENT_VER="2.1.12-stable"
LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VER}/libevent-${LIBEVENT_VER}.tar.gz"
LIBEVENT_SHA256="92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb"

build() {
    MC_DEPS="$BUILD_ROOT/deps"
    MC_PREFIX="$MC_DEPS/prefix"
    MC_OBJS="$MC_DEPS/objs"
    MC_BIN="$MC_DEPS/bin"
    mkdir -p "$MC_PREFIX" "$MC_OBJS" "$MC_BIN" "$MC_DEPS/libevent"

    LOTDEFS="-Dlinux=1 -D__linux__=1 -D_GNU_SOURCE=1"

    # ── link shims (all before -lc) ────────────────────────────────────────
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_clone.c"      -o "$MC_OBJS/wasm_clone.o"
    $CC $CFLAGS -w -c "$REPO_ROOT/sysroot/wasm_dlmalloc_mt.c" -o "$MC_OBJS/wasm_dlmalloc_mt.o"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_fork.c"       -o "$MC_OBJS/wasm_fork.o"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_mmap_anon.c"  -o "$MC_OBJS/wasm_mmap_anon.o"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_ld128.c"      -o "$MC_OBJS/wasm_ld128.o"
    cat > "$MC_OBJS/lot_mc_shims.c" <<'SHIMEOF'
/* Bits the wasm32 sysroot does not provide.
 * msync: only reached via restart.c's file mapping, which the MAP_ANON shim
 *        already refuses; a no-op success is honest for anonymous memory.
 * pthread_cancel: musl's needs asm cancellation points that do not exist on
 *        wasm32; memcached never cancels threads, so make sure libc's is not
 *        pulled in by anything (ESRCH = "no such thread"). */
#include <errno.h>
#include <pthread.h>
#include <stddef.h>
int msync(void *addr, size_t len, int flags) { (void)addr; (void)len; (void)flags; return 0; }
int pthread_cancel(pthread_t t) { (void)t; return ESRCH; }
SHIMEOF
    $CC $CFLAGS -c "$MC_OBJS/lot_mc_shims.c" -o "$MC_OBJS/lot_mc_shims.o"

    # fork() is hidden by wasm-musl; daemon.c (-d) uses it.
    printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\nint msync(void *, size_t, int);\n' \
        > "$MC_OBJS/fork-decls.h"
    MC_INC="$LOTDEFS -include $MC_OBJS/fork-decls.h -include $REPO_ROOT/sysroot/wasm_mman.h"

    # cc wrapper: every link step gets LDFLAGS + shims + crt1/libc/builtins
    export LOTCC="$REPO_ROOT/sysroot/lot-cc.sh"
    export LOT_CLANG_BIN="$CLANG" LOT_SYSROOT_DIR="$SYSROOT" LOT_CRT1="$CRT1" LOT_BUILTINS="$BUILTINS"
    export LOT_LDFLAGS="$LDFLAGS -Wl,-z,stack-size=8388608"
    export LOT_LINK_OBJS="$MC_OBJS/wasm_dlmalloc_mt.o $MC_OBJS/wasm_clone.o $MC_OBJS/wasm_fork.o $MC_OBJS/wasm_mmap_anon.o $MC_OBJS/wasm_ld128.o $MC_OBJS/lot_mc_shims.o"
    # macOS ar pads members -> wasm-ld "section too large": GNU-format llvm-ar
    printf '#!/bin/sh\nexec %s --format=gnu "$@"\n' "$AR" > "$MC_BIN/ar"
    chmod +x "$MC_BIN/ar"
    MC_AR="$MC_BIN/ar"
    export PATH="$MC_BIN:$PATH"

    # ── libevent (static, epoll, no openssl, no thread support) ────────────
    _lev_tgz="/tmp/lot-src-libevent-${LIBEVENT_VER}.tar.gz"
    [ -s "$_lev_tgz" ] || curl -L --fail -o "$_lev_tgz" "$LIBEVENT_URL"
    _a="$(shasum -a 256 "$_lev_tgz" | cut -d' ' -f1)"
    [ "$_a" = "$LIBEVENT_SHA256" ] || { echo "libevent checksum mismatch: $_a" >&2; exit 1; }
    tar xzf "$_lev_tgz" -C "$MC_DEPS/libevent" --strip-components=1
    echo "==> libevent $LIBEVENT_VER"
    (cd "$MC_DEPS/libevent" && ./configure --host=wasm32-unknown-linux-musl --prefix="$MC_PREFIX" \
        --disable-shared --enable-static --disable-openssl --disable-thread-support \
        --disable-samples --disable-libevent-regress --disable-debug-mode \
        CC="$LOTCC" CFLAGS="$CFLAGS $MC_INC" CPPFLAGS="$MC_INC" AR="$MC_AR" RANLIB="$RANLIB" \
        ac_cv_func_mmap=no ac_cv_func_sendfile=no ac_cv_func_arc4random=no \
        ac_cv_func_arc4random_buf=no ac_cv_func_sysctl=no \
        > configure.log 2>&1 \
     && make -j8 > make.log 2>&1 && make install > install.log 2>&1) \
     || { echo "libevent build failed — see $MC_DEPS/libevent/*.log" >&2; tail -30 "$MC_DEPS"/libevent/*.log >&2; exit 1; }
    grep -q '#define EVENT__HAVE_EPOLL 1' "$MC_PREFIX/include/event2/event-config.h" \
        || { echo "libevent: epoll backend not detected" >&2; exit 1; }
    [ -f "$MC_PREFIX/lib/libevent.a" ] || { echo "libevent.a missing" >&2; exit 1; }

    # ── memcached ──────────────────────────────────────────────────────────
    cd "$SRC"
    # setuid/setgroups -> ENOSYS here: keep running as the current user.
    perl -0777 -i -pe 's{bool should_exit = errno != EPERM;}{bool should_exit = errno != EPERM && errno != ENOSYS; /* wasm guest */}' memcached.c
    perl -0777 -i -pe 's{if \(setgid\(pw->pw_gid\) < 0 \|\| setuid\(pw->pw_uid\) < 0\) \{}{if ((setgid(pw->pw_gid) < 0 && errno != ENOSYS) || (setuid(pw->pw_uid) < 0 && errno != ENOSYS)) \{ /* wasm guest: setuid is ENOSYS */}' memcached.c
    grep -q 'wasm guest: setuid is ENOSYS' memcached.c || { echo "memcached.c setuid patch failed" >&2; exit 1; }
    grep -q 'errno != ENOSYS; /\* wasm guest' memcached.c || { echo "memcached.c setgroups patch failed" >&2; exit 1; }

    # wasm-ld has no -rpath (static link anyway): drop configure's
    # "-Wl,-rpath,<libevent>/lib" or every later link probe fails.
    sed -i.orig 's|saved_LDFLAGS="$saved_LDFLAGS -Wl,-rpath,$ledir/lib"|:|' configure
    grep -q -- '-Wl,-rpath,$ledir' configure && { echo "configure rpath patch failed" >&2; exit 1; }

    # The libevent "is it 2.x" probe is AC_RUN_IFELSE with an empty
    # cross-compile branch (no answer needed). Alignment probe -> cross says
    # "maybe" -> NEED_ALIGN: harmless (wasm does unaligned loads fine, this
    # only adds memcpys). Seed func checks the -include'd prototypes confuse.
    ./configure --host=wasm32-unknown-linux-musl --prefix=/usr \
        --with-libevent="$MC_PREFIX" \
        --disable-sasl --disable-tls --disable-proxy --disable-seccomp \
        --disable-dtrace --disable-coverage --disable-docs --disable-werror \
        CC="$LOTCC" CFLAGS="$CFLAGS $MC_INC" CPPFLAGS="$MC_INC" AR="$MC_AR" RANLIB="$RANLIB" \
        ac_cv_c_alignment=none \
        ac_cv_func_mlockall=no ac_cv_func_memcntl=no ac_cv_func_getpagesizes=no \
        ac_cv_search_gethugepagesizes=no \
        > configure.log 2>&1 || { tail -40 configure.log >&2; exit 1; }
    grep -E 'HAVE_EVENTFD|HAVE_ACCEPT4|NEED_ALIGN|HAVE_PTHREAD_SETNAME_NP|HAVE_GETOPT_LONG|EXTSTORE' config.h || true

    make -j8 memcached > make.log 2>&1 || { tail -40 make.log >&2; exit 1; }

    mkdir -p "$STAGE/usr/bin"
    cp -f memcached "$STAGE/usr/bin/memcached"
    rmdir "$STAGE/bin" 2>/dev/null || true
}
