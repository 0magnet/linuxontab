#!/bin/sh
# Recipe: php — PHP 8.3 CLI (with the built-in web server) for the wasm guest.
#
#   php -v
#   php -r 'echo json_encode(["a" => 1.5]), PHP_EOL;'
#   php-demo                 # php -S 0.0.0.0:8082 -t /var/www/php (web view port 8082)
#
# Static, single-process build: --disable-all plus the cheap bundled
# extensions (ctype, tokenizer, filter, session, mbstring without mbregex,
# posix) and SQLite (sqlite3 + pdo_sqlite) from the amalgamation, linked in.
# No dlopen, no opcache/JIT, no fibers. `php -S` serves on one process
# (PHP_CLI_SERVER_WORKERS unset) over select().
#
# Porting notes for this target:
#   - Zend's try/catch (zend_try → SETJMP) is setjmp/longjmp: everything is
#     compiled with the native wasm-EH sjlj lowering and links
#     sysroot/sjlj_rt_wasmeh.c. The lowering only knows setjmp/longjmp, so
#     ac_cv_func_sigsetjmp=no keeps Zend off sigsetjmp.
#   - Zend MM allocates 2 MB-aligned chunks with mmap and trims/extends them
#     with partial munmap/mremap. Here there is no mmap, so chunks come from
#     posix_memalign (sbrk-only dlmalloc — musl mallocng traps on >128 KB
#     blocks) and truncate/extend report "unsupported" (Windows behaviour:
#     huge-block realloc falls back to alloc + copy). memory_limit works.
#   - Fibers: no boost asm for wasm32 and no getcontext in musl → configure
#     picks the ucontext backend; Fiber::start() throws a FiberError instead
#     (stubs keep the link happy; the context switch is never reached).
#   - -export-dynamic is dropped from the CLI link (wasm-ld would export every
#     symbol).
#   - VM kind is CALL (no global register variables on wasm32): handlers are
#     one exact signature, so no call_indirect mismatch there.
#   - Explicit 8 MB stack (wasm-ld default is 64 KB).

NAME="php"
PHP_UPSTREAM="8.3.35"
VERSION="${PHP_UPSTREAM}-r0"
DESCRIPTION="PHP 8.3 CLI + built-in web server (php-demo serves /var/www/php on port 8082)"
SOURCE_URL="https://www.php.net/distributions/php-${PHP_UPSTREAM}.tar.gz"
SOURCE_SHA256="e60396276fd57e8210f88919d9acd4aab98d65fbb7f431c13285ca1fb04ff205"
DEPENDS=""

SQLITE_URL="https://www.sqlite.org/2025/sqlite-autoconf-3510000.tar.gz"

build() {
    cd "$SRC"
    L="$SRC/lot"
    mkdir -p "$L/bin" "$L/sqlite"

    # ── toolchain glue ──────────────────────────────────────────────────────
    # macOS ar pads members ("section too large" in wasm-ld): GNU llvm-ar
    printf '#!/bin/sh\nexec %s --format=gnu "$@"\n' "$AR" > "$L/bin/ar"
    chmod +x "$L/bin/ar"
    export PATH="$L/bin:$PATH"
    LOTAR="$L/bin/ar"
    export LOTCC="$REPO_ROOT/sysroot/lot-cc.sh"
    export LOT_CLANG_BIN="$CLANG" LOT_SYSROOT_DIR="$SYSROOT" LOT_CRT1="$CRT1" LOT_BUILTINS="$BUILTINS"
    export LOT_LDFLAGS="$LDFLAGS -Wl,-z,stack-size=8388608"

    SJLJ="-mexception-handling -mllvm -wasm-enable-sjlj"

    # Declarations the wasm32 sysroot hides (fork, mmap & friends).
    cat > "$L/lot-php-wasm.h" <<'EOF'
#ifndef LOT_PHP_WASM_H
#define LOT_PHP_WASM_H
#include <sys/types.h>
#include <stddef.h>
pid_t fork(void);
pid_t vfork(void);
#include "wasm_mman.h"
#ifndef MAP_STACK
#define MAP_STACK 0x20000
#endif
#ifdef __cplusplus
extern "C" {
#endif
int mprotect(void *, size_t, int);
int madvise(void *, size_t, int);
#ifdef __cplusplus
}
#endif
#endif
EOF
    # Link-only stubs: mprotect (fiber guard pages, never reached), and the
    # ucontext calls the Fiber backend references (fibers are refused up front).
    cat > "$L/lot-php-compat.c" <<'EOF'
#include <errno.h>
#include <stddef.h>
#include <ucontext.h>
int mprotect(void *a, size_t l, int p) { (void)a; (void)l; (void)p; return 0; }
int madvise(void *a, size_t l, int adv) { (void)a; (void)l; (void)adv; return 0; }
int getcontext(ucontext_t *u) { (void)u; return 0; }
void makecontext(ucontext_t *u, void (*fn)(void), int argc, ...) { (void)u; (void)fn; (void)argc; }
int swapcontext(ucontext_t *o, const ucontext_t *n) { (void)o; (void)n; errno = ENOSYS; return -1; }
EOF
    INC="-I$REPO_ROOT/sysroot -include $L/lot-php-wasm.h"
    DEFS="-D__linux__=1 -Dlinux=1 -D_GNU_SOURCE -D_LARGEFILE64_SOURCE"
    PHPCFLAGS="$CFLAGS $SJLJ $DEFS $INC -Wcast-function-type-strict"

    $CC $CFLAGS -w -c "$REPO_ROOT/sysroot/wasm_dlmalloc.c" -o "$L/wasm_dlmalloc.o"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_fork.c" -o "$L/wasm_fork.o"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_mmap_anon.c" -o "$L/wasm_mmap_anon.o"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_ld128.c" -o "$L/wasm_ld128.o"
    $CC $CFLAGS -c "$L/lot-php-compat.c" -o "$L/lot-php-compat.o"
    # the sjlj runtime MUST itself be built with the sjlj pass
    $CC $CFLAGS $SJLJ -c "$REPO_ROOT/sysroot/sjlj_rt_wasmeh.c" -o "$L/sjlj_rt.o"
    export LOT_LINK_OBJS="$L/wasm_dlmalloc.o $L/wasm_fork.o $L/wasm_mmap_anon.o $L/wasm_ld128.o $L/lot-php-compat.o $L/sjlj_rt.o"

    # ── SQLite amalgamation (static) ────────────────────────────────────────
    _sa="/tmp/lot-src-php-sqlite-$(basename "$SQLITE_URL")"
    [ -s "$_sa" ] || curl -sL --fail -o "$_sa" "$SQLITE_URL" || { echo "sqlite download failed" >&2; exit 1; }
    tar xzf "$_sa" -C "$L/sqlite" --strip-components=1
    # no mmap I/O, no extension loading, single-threaded (no pthreads in php)
    $CC $CFLAGS $DEFS $INC -w -DHAVE_MREMAP=0 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION \
        -DSQLITE_MAX_MMAP_SIZE=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0 \
        -DSQLITE_ENABLE_COLUMN_METADATA \
        -c "$L/sqlite/sqlite3.c" -o "$L/sqlite/sqlite3.o"
    rm -f "$L/sqlite/libsqlite3.a"
    "$LOTAR" rcs "$L/sqlite/libsqlite3.a" "$L/sqlite/sqlite3.o"

    # ── source patches ──────────────────────────────────────────────────────
    python3 - <<'PY'
import re, sys
def patch(path, old, new, count=1):
    s = open(path).read()
    if new in s:
        return
    if s.count(old) < 1:
        sys.exit(f"php patch: anchor not found in {path}: {old[:60]!r}")
    s = s.replace(old, new, count)
    open(path, "w").write(s)

# Zend MM: chunks from posix_memalign; no partial unmapping / in-place growth.
patch("Zend/zend_alloc.c",
"static void *zend_mm_chunk_alloc_int(size_t size, size_t alignment)\n{\n",
"static void *zend_mm_chunk_alloc_int(size_t size, size_t alignment)\n{\n"
"#ifdef __wasm__\n"
"\t/* LinuxOnTab wasm32: no mmap. Aligned blocks from the sbrk heap. */\n"
"\tvoid *wptr = NULL;\n"
"\tif (posix_memalign(&wptr, alignment, size) != 0) {\n"
"\t\treturn NULL;\n"
"\t}\n"
"\tmemset(wptr, 0, size);\n"
"\treturn wptr;\n"
"#endif\n")
patch("Zend/zend_alloc.c",
"#endif\n\tzend_mm_munmap(addr, size);\n}\n",
"#endif\n#ifdef __wasm__\n\t(void)size;\n\tfree(addr);\n#else\n\tzend_mm_munmap(addr, size);\n#endif\n}\n")
patch("Zend/zend_alloc.c",
"#ifndef _WIN32\n\tzend_mm_munmap((char*)addr + new_size, old_size - new_size);\n\treturn 1;\n",
"#if defined(__wasm__)\n\treturn 0;\n#elif !defined(_WIN32)\n\tzend_mm_munmap((char*)addr + new_size, old_size - new_size);\n\treturn 1;\n")
patch("Zend/zend_alloc.c",
"#ifdef HAVE_MREMAP\n\t/* We don't use MREMAP_MAYMOVE",
"#if defined(__wasm__)\n\treturn 0;\n#elif defined(HAVE_MREMAP)\n\t/* We don't use MREMAP_MAYMOVE")

# Fibers: refuse cleanly (no context switching primitive on wasm32).
patch("Zend/zend_fibers.c",
"ZEND_API zend_result zend_fiber_init_context(zend_fiber_context *context, void *kind, zend_fiber_coroutine coroutine, size_t stack_size)\n{\n",
"ZEND_API zend_result zend_fiber_init_context(zend_fiber_context *context, void *kind, zend_fiber_coroutine coroutine, size_t stack_size)\n{\n"
"#ifdef __wasm__\n"
"\t(void)context; (void)kind; (void)coroutine; (void)stack_size;\n"
"\tzend_throw_exception_ex(zend_ce_fiber_error, 0, \"Fibers are not supported on this platform (wasm32)\");\n"
"\treturn FAILURE;\n"
"#endif\n")
PY
    grep -q "LinuxOnTab wasm32: no mmap" Zend/zend_alloc.c || { echo "zend_alloc patch failed" >&2; exit 1; }

    # ── configure ───────────────────────────────────────────────────────────
    ./configure --host=wasm32-unknown-linux-musl --build="$(sh ./build/config.guess)" \
        --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
        --with-config-file-path=/etc/php --with-config-file-scan-dir=/etc/php/conf.d \
        --disable-all --enable-cli --disable-cgi --disable-phpdbg --disable-fpm \
        --without-pear --without-iconv --disable-opcache --disable-opcache-jit \
        --without-pcre-jit --without-valgrind --disable-fiber-asm --disable-zend-signals \
        --disable-shared --enable-static \
        --enable-ctype --enable-tokenizer --enable-filter --enable-session \
        --enable-posix --enable-mbstring --disable-mbregex \
        --enable-pdo --with-pdo-sqlite --with-sqlite3 \
        CC="$LOTCC" CFLAGS="$PHPCFLAGS" CPPFLAGS="$DEFS $INC" \
        AR="$LOTAR" RANLIB="$RANLIB" \
        PKG_CONFIG=/usr/bin/false PKG_CONFIG_LIBDIR=/nonexistent \
        SQLITE_CFLAGS="-I$L/sqlite" SQLITE_LIBS="-L$L/sqlite -lsqlite3" \
        ac_cv_func_sigsetjmp=no ac_cv_func_mremap=no ac_cv_func_mmap=no \
        ac_cv_func_fork=yes ac_cv_func_vfork=no \
        ac_cv_func_pthread_getattr_np=no ac_cv_func_pthread_attr_getstack=no \
        ac_cv_syscall_shadow_stack_exists=no \
        > "$SRC/lot-configure.log" 2>&1 \
        || { tail -40 "$SRC/lot-configure.log"; echo "php configure failed — see $SRC/lot-configure.log + config.log" >&2; exit 1; }
    tail -5 "$SRC/lot-configure.log"

    # wasm-ld --export-dynamic would export every global symbol
    sed -i.orig 's/ -export-dynamic / /g' Makefile
    grep -q -- '-export-dynamic' Makefile && { echo "export-dynamic still in Makefile" >&2; exit 1; }

    make -j8 sapi/cli/php > "$SRC/lot-make.log" 2>&1 \
        || { grep -n "error" "$SRC/lot-make.log" | head -40; echo "php make failed — see $SRC/lot-make.log" >&2; exit 1; }
    echo "==> cast-function-type warnings:"
    grep -c "Wcast-function-type" "$SRC/lot-make.log" || true

    # ── stage ───────────────────────────────────────────────────────────────
    mkdir -p "$STAGE/usr/bin" "$STAGE/etc/php/conf.d" "$STAGE/var/www/php" "$STAGE/var/lib/php/sessions"
    cp -f sapi/cli/php "$STAGE/usr/bin/php"
    cat > "$STAGE/etc/php/php.ini" <<'INI'
; LinuxOnTab guest defaults
date.timezone = UTC
memory_limit = 128M
display_errors = stderr
error_reporting = E_ALL
html_errors = Off
session.save_path = /var/lib/php/sessions
variables_order = "EGPCS"
INI
    cat > "$STAGE/usr/bin/php-demo" <<'SH'
#!/bin/sh
# php-demo — serve /var/www/php with PHP's built-in web server on :8082.
# Open it with the top bar's web view (port 8082), or: wget -qO- http://127.0.0.1:8082/
PORT="${1:-8082}"
echo "php-demo: http://0.0.0.0:$PORT/  (docroot /var/www/php, Ctrl-C to stop)"
exec php -S "0.0.0.0:$PORT" -t /var/www/php
SH
    chmod 755 "$STAGE/usr/bin/php-demo"
    cat > "$STAGE/var/www/php/index.php" <<'PHP'
<?php
// LinuxOnTab PHP demo — served by `php -S` inside the wasm guest.
$counterFile = '/var/lib/php/counter.txt';
$count = (int)@file_get_contents($counterFile) + 1;
@file_put_contents($counterFile, (string)$count, LOCK_EX);

$name = isset($_POST['name']) ? trim((string)$_POST['name']) : '';
$h = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES);

$db = null;
if (class_exists('PDO') && in_array('sqlite', PDO::getAvailableDrivers(), true)) {
    $db = new PDO('sqlite:/var/lib/php/demo.sqlite');
    $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $db->exec('CREATE TABLE IF NOT EXISTS guests (id INTEGER PRIMARY KEY, name TEXT, at TEXT)');
    if ($name !== '') {
        $st = $db->prepare('INSERT INTO guests (name, at) VALUES (?, ?)');
        $st->execute([$name, date('c')]);
    }
}
$guests = $db ? $db->query('SELECT name, at FROM guests ORDER BY id DESC LIMIT 10')->fetchAll(PDO::FETCH_ASSOC) : [];
?><!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PHP on LinuxOnTab</title>
<style>
 :root { color-scheme: light dark; --bg:#f6f7fb; --fg:#1d2330; --card:#fff; --mut:#5b6476; --acc:#777bb4; }
 @media (prefers-color-scheme: dark) { :root { --bg:#141821; --fg:#e7e9ef; --card:#1d2230; --mut:#9aa3b5; } }
 body { margin:0; font:15px/1.5 system-ui, sans-serif; background:var(--bg); color:var(--fg); }
 main { max-width:720px; margin:0 auto; padding:24px 16px; }
 h1 { margin:0 0 4px; font-size:24px; } h1 span { color:var(--acc); }
 .card { background:var(--card); border-radius:10px; padding:16px; margin:14px 0; box-shadow:0 1px 3px rgba(0,0,0,.08); }
 table { border-collapse:collapse; width:100%; } td { padding:4px 8px; border-bottom:1px solid rgba(127,127,127,.2); }
 td:first-child { color:var(--mut); width:40%; }
 input, button { font:inherit; padding:6px 10px; border-radius:6px; border:1px solid rgba(127,127,127,.4); }
 button { background:var(--acc); color:#fff; border:0; }
 small { color:var(--mut); }
</style></head><body><main>
<h1><span>PHP</span> <?= $h(PHP_VERSION) ?> on LinuxOnTab</h1>
<small>Rendered by <code>php -S</code> running in a wasm32 Linux guest in your browser tab.</small>
<div class="card"><table>
<tr><td>PHP version</td><td><?= $h(PHP_VERSION) ?> (<?= $h(PHP_SAPI) ?>, <?= $h(php_uname('s') . ' ' . php_uname('r') . ' ' . php_uname('m')) ?>)</td></tr>
<tr><td>Zend Engine</td><td><?= $h(zend_version()) ?></td></tr>
<tr><td>Server time</td><td><?= $h(date('Y-m-d H:i:s T')) ?></td></tr>
<tr><td>Visits (counter file)</td><td><?= $count ?></td></tr>
<tr><td>Memory</td><td><?= $h(number_format(memory_get_usage() / 1024, 1)) ?> KiB (peak <?= $h(number_format(memory_get_peak_usage() / 1024, 1)) ?> KiB)</td></tr>
<tr><td>Extensions</td><td><?= $h(implode(', ', get_loaded_extensions())) ?></td></tr>
</table></div>
<div class="card">
<form method="post"><label>Sign the guest book: <input name="name" maxlength="40" required></label> <button>Sign</button></form>
<?php if ($name !== ''): ?><p>Hello, <b><?= $h($name) ?></b>!</p><?php endif; ?>
<?php if ($guests): ?><table><?php foreach ($guests as $g): ?>
<tr><td><?= $h($g['at']) ?></td><td><?= $h($g['name']) ?></td></tr>
<?php endforeach; ?></table><?php elseif (!$db): ?><small>(pdo_sqlite not available)</small><?php endif; ?>
</div>
</main></body></html>
PHP
    rmdir "$STAGE/bin" 2>/dev/null || true
}
