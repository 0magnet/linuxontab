#!/bin/sh
# Recipe: postgres — PostgreSQL 17 (server, initdb, psql) for the wasm guest.
#
#   postgres-demo                       first run: initdb, then serve :5432
#   psql -U postgres                    Unix socket (/tmp)
#   psql -h 127.0.0.1 -U postgres       TCP (also reachable from other tabs)
#
# THE ARCHITECTURE PROBLEM: the postmaster forks one backend per connection
# and they all share a big shared-memory segment. Here every process is its
# own wasm instance and nothing is shared between processes (MAP_SHARED and
# SysV shm can't share; the kernel has no SysV IPC at all). So this build
# has no postmaster. `postgres -D …` (no --boot/--single/--check switch)
# runs a stand-alone backend in "server mode" (toolchain/patches/
# postgres-17-lot-wasm.patch, see lot_server_* in tcop/backend_startup.c and
# tcop/postgres.c):
#   - it listens itself (listen_addresses / port / unix_socket_directories)
#     and speaks the normal FE/BE protocol to ONE client at a time; the next
#     client waits in the listen backlog. "Shared" memory is process memory.
#   - client disconnect = session end: open transaction rolled back, then
#     the equivalent of DISCARD ALL, then the next client is accepted.
#   - an idle client (no open transaction) is ended (FATAL 57P01) when
#     another one connects — psql's \c opens the new connection before it
#     closes the old one, and an abandoned idle session must not wedge the
#     server.
#   - a client asking for another database makes the server shut down
#     cleanly (checkpoint) and re-exec itself for that database, handing over
#     the listen sockets and that client. One database per process, because
#     a backend can attach to only one for life.
#   - trust auth only (no pg_hba): any existing login role, no password.
#   - no autovacuum/bgwriter/walwriter/checkpointer (no other processes):
#     checkpoints happen by WAL volume (max_wal_size) and at shutdown; run
#     VACUUM yourself.
#   - Ctrl-C / SIGTERM = clean shutdown.
# initdb and `postgres --single` work as usual (initdb runs postgres --boot /
# --single through popen; those children are separate processes, fine).
#
# Build notes for this target:
#   - wasm-EH setjmp/longjmp: elog/PG_TRY is sigsetjmp everywhere; the sjlj
#     lowering only knows setjmp/longjmp, so the force-included lot-pg-wasm.h
#     maps sigsetjmp/siglongjmp onto them (the saved mask is dropped).
#   - no dlopen: plpgsql, dict_snowball and the non-CJK encoding conversions
#     are compiled with renamed Pg_magic_func/_PG_init and linked into the
#     postgres binary; dfmgr.c's dlopen/dlsym resolve from a generated table
#     (lot_static_modules.c). "$libdir/<module>.so" are empty placeholders
#     (dfmgr stat()s the file first).
#   - postgres is NOT asyncified (NO_ASYNCIFY=1; initdb + psql are, below).
#     Asyncify is only needed for fork(), which the server never calls (its
#     posix_spawn goes through wasm_clone.c), and the browser's ~1 MB native
#     stack is the real recursion limit here: check_stack_depth() measures
#     the shadow stack, which most wasm frames never touch, so it never
#     fires; the process died at ~140 levels of PL/pgSQL recursion. The patch
#     caps SPI nesting at 100 ("stack depth limit exceeded") instead.
#   - latch.c on poll()+self-pipe (WAIT_USE_POLL): the server moves clients
#     onto one descriptor number with dup2(), which an epoll set won't follow.
#   - spinlocks/atomics: native (clang __sync/__atomic on wasm threads).
#   - sbrk-only dlmalloc (mallocng's large-block path traps here),
#     wasm_mmap.c, wasm_fork.c, explicit 8 MB shadow stack.
#   - libpq is built static only (dummy .so to satisfy the Makefiles); psql
#     links libpgcommon_shlib/libpgport_shlib for the symbols libpq.so would
#     have exported.
#   - timezone data compiled with the HOST zic (macOS /usr/sbin/zic).
#   - root: every guest process is root (setuid is ENOSYS), so the
#     "cannot be run as root" checks are compiled out.

NAME="postgres"
PG_UPSTREAM="17.11"
VERSION="${PG_UPSTREAM}"
DESCRIPTION="PostgreSQL 17 database (single-process server: one client at a time) + psql, initdb; start with postgres-demo (port 5432)"
SOURCE_URL="https://ftp.postgresql.org/pub/source/v${PG_UPSTREAM}/postgresql-${PG_UPSTREAM}.tar.bz2"
SOURCE_SHA256="dd27f2b3c59e73ed14aa3324901242bf69a032a6347805f274e6260322d42979"
# build() asyncifies initdb and psql itself; postgres must stay plain
NO_ASYNCIFY=1

# loadable modules linked into the server: name:dir
PG_STATIC_MODULES="plpgsql:src/pl/plpgsql/src dict_snowball:src/backend/snowball"
for _m in utf8_and_iso8859_1 utf8_and_iso8859 utf8_and_win utf8_and_cyrillic \
          cyrillic_and_mic latin_and_mic latin2_and_win1250; do
    PG_STATIC_MODULES="$PG_STATIC_MODULES $_m:src/backend/utils/mb/conversion_procs/$_m"
done

build() {
    cd "$SRC"
    patch -p1 < "$REPO_ROOT/toolchain/patches/postgres-17-lot-wasm.patch"
    grep -q "lot_server_accept" src/backend/tcop/backend_startup.c || { echo "patch failed" >&2; exit 1; }

    LOT="$SRC/lot"
    mkdir -p "$LOT/bin" "$LOT/mods"

    # ── force-included into every TU (configure probes too) ──────────────
    cat > "$LOT/lot-pg-wasm.h" <<'HEOF'
/* lot-pg-wasm.h -- force-included into every PostgreSQL TU for the
 * LinuxOnTab wasm32 guest (packages/recipes/postgres.sh). */
#ifndef LOT_PG_WASM_H
#define LOT_PG_WASM_H
#define LOT_WASM 1
/* wasm32 predefines neither linux nor __linux__ */
#ifndef __linux__
#define __linux__ 1
#endif
#include <setjmp.h>
#include <sys/types.h>
/* musl hides these on wasm32; sysroot/wasm_fork.c provides the asyncify
 * fork thunk (the server never forks; linked for completeness) */
pid_t fork(void);
pid_t vfork(void);
/* The wasm-EH sjlj lowering (-mllvm -wasm-enable-sjlj) only rewrites
 * setjmp/longjmp. elog/PG_TRY use sigsetjmp/siglongjmp everywhere
 * (sigjmp_buf == jmp_buf in musl). The saved signal mask is dropped. */
#undef sigsetjmp
#undef siglongjmp
#define sigsetjmp(env, savemask) setjmp(env)
#define siglongjmp(env, val) longjmp(env, val)
/* musl hides MAP_/PROT_ constants and the mman prototypes on wasm32;
 * sysroot/wasm_mmap.c is the implementation */
#include "wasm_mman.h"
int msync(void *, size_t, int);
int mprotect(void *, size_t, int);
int madvise(void *, size_t, int);
int posix_madvise(void *, size_t, int);
/* latch.c: poll() + self-pipe. The single-process server moves clients
 * onto one descriptor number with dup2(), which an epoll set would not
 * follow. */
#define WAIT_USE_POLL 1
#endif
HEOF

    # ── shims ────────────────────────────────────────────────────────────
    SJLJ="-mexception-handling -mllvm -wasm-enable-sjlj"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_clone.c" -o "$LOT/wasm_clone.o"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_fork.c" -o "$LOT/wasm_fork.o"
    $CC $CFLAGS -w -c "$REPO_ROOT/sysroot/wasm_dlmalloc.c" -o "$LOT/wasm_dlmalloc.o"
    $CC $CFLAGS -w -c "$REPO_ROOT/sysroot/wasm_mmap.c" -o "$LOT/wasm_mmap.o"
    # the sjlj runtime MUST itself be built with the sjlj pass
    $CC $CFLAGS $SJLJ -c "$REPO_ROOT/sysroot/sjlj_rt_wasmeh.c" -o "$LOT/sjlj_rt.o"

    # lot-cc.sh appends the wasm link line to every link step
    export LOTCC="$REPO_ROOT/sysroot/lot-cc.sh"
    chmod +x "$LOTCC"
    export LOT_CLANG_BIN="$CLANG" LOT_SYSROOT_DIR="$SYSROOT" LOT_CRT1="$CRT1" LOT_BUILTINS="$BUILTINS"
    # 8 MB shadow stack: wasm-ld's 64 KB default is the classic mystery segfault
    export LOT_LDFLAGS="$LDFLAGS -Wl,-z,stack-size=8388608"
    export LOT_LINK_OBJS="$LOT/wasm_clone.o $LOT/wasm_fork.o $LOT/wasm_dlmalloc.o $LOT/wasm_mmap.o $LOT/sjlj_rt.o"
    # macOS ar pads members and breaks wasm-ld: GNU-format llvm-ar
    printf '#!/bin/sh\nexec %s --format=gnu "$@"\n' "$AR" > "$LOT/bin/ar"
    chmod +x "$LOT/bin/ar"
    NM="$(dirname "$AR")/llvm-nm"
    ZIC="$(command -v zic || echo /usr/sbin/zic)"
    [ -x "$ZIC" ] || { echo "need a host zic for the timezone data" >&2; exit 1; }

    PGCFLAGS="$CFLAGS $SJLJ -Qunused-arguments"
    PGCPPFLAGS="-I$REPO_ROOT/sysroot -include $LOT/lot-pg-wasm.h"

    # ── configure (cross: run tests answered by cache vars) ──────────────
    ./configure --host=wasm32-unknown-linux-musl --build="$(uname -m)-apple-darwin" \
        --prefix=/usr --disable-rpath --disable-nls \
        --without-readline --without-icu --without-zlib --without-lz4 --without-zstd \
        --without-ldap --without-gssapi --without-pam \
        CC="$LOTCC" CFLAGS="$PGCFLAGS" CPPFLAGS="$PGCPPFLAGS" \
        AR="$LOT/bin/ar" RANLIB="$RANLIB" ZIC="$ZIC" \
        pgac_cv_type_long_int_64=no pgac_cv_type_long_long_int_64=yes \
        > "$LOT/configure.log" 2>&1 || { tail -30 "$LOT/configure.log" >&2; exit 1; }
    grep -q "define HAVE_SPINLOCKS 1" src/include/pg_config.h || { echo "no spinlocks?" >&2; exit 1; }

    make -C src/backend generated-headers
    # frontend libs and src/timezone (zic) first: the LIBS= override used
    # for the postgres link below propagates into the backend's sub-makes,
    # and zic, which the backend build recurses into, needs the stock LIBS
    make -C src/port -j8
    make -C src/common -j8
    make -C src/timezone -j8

    # ── loadable modules, compiled for static linking ────────────────────
    printf 'lotobjs:\n\t@echo $(OBJS)\n' > "$LOT/printobjs.mk"
    : > "$LOT/mods/objs.list"
    for _e in $PG_STATIC_MODULES; do
        _m=${_e%%:*}; _d="$SRC/${_e#*:}"
        _objs=$(make -s -C "$_d" -f Makefile -f "$LOT/printobjs.mk" lotobjs)
        make -C "$_d" -j8 COPT="-DPg_magic_func=${_m}_Pg_magic_func -D_PG_init=${_m}__PG_init" $_objs
        for _o in $_objs; do echo "$_m $_d/$_o" >> "$LOT/mods/objs.list"; done
    done
    python3 - "$LOT/mods" "$NM" <<'PYEOF'
import subprocess, sys, collections
out, nm = sys.argv[1], sys.argv[2]
mods = collections.OrderedDict()
for line in open(f"{out}/objs.list"):
    m, o = line.split()
    mods.setdefault(m, []).append(o)
decl, tables, entries = [], [], []
for m, objs in mods.items():
    syms = []
    for o in objs:
        r = subprocess.run([nm, "--defined-only", "-g", o], capture_output=True, text=True, check=True)
        syms += [p[2] for p in (l.split() for l in r.stdout.splitlines()) if len(p) == 3 and p[1] == "T"]
    rows = []
    for s in syms:
        # declare every symbol with its real signature: an address taken
        # through a mismatched declaration gets a trapping wasm-ld stub
        if s.startswith("pg_finfo_"):
            f = s[len("pg_finfo_"):]
            decl += [f"extern const Pg_finfo_record *{s}(void);", f"extern Datum {f}(PG_FUNCTION_ARGS);"]
            rows += [f'\t{{"{s}", (void *) {s}}},', f'\t{{"{f}", (void *) {f}}},']
        elif s == f"{m}_Pg_magic_func":
            decl.append(f"extern const Pg_magic_struct *{s}(void);")
            rows.append(f'\t{{"Pg_magic_func", (void *) {s}}},')
        elif s == f"{m}__PG_init":
            decl.append(f"extern void {s}(void);")
            rows.append(f'\t{{"_PG_init", (void *) {s}}},')
    tables.append(f"static const lot_sym lot_syms_{m}[] = {{\n" + "\n".join(rows) + "\n\t{NULL, NULL}\n};")
    entries.append(f'\t{{"{m}", lot_syms_{m}}},')
nl = "\n"
src = f"""/* generated by packages/recipes/postgres.sh: the loadable modules linked
 * into this static postgres, for dfmgr.c's lot_dlopen()/lot_dlsym() */
#include "postgres.h"
#include "fmgr.h"
#include <string.h>

typedef struct {{ const char *name; void *addr; }} lot_sym;
typedef struct {{ const char *lib; const lot_sym *syms; }} lot_mod;

{nl.join(decl)}

{nl.join(tables)}

static const lot_mod lot_mods[] = {{
{nl.join(entries)}
\t{{NULL, NULL}}
}};

static char lot_dl_err[MAXPGPATH + 128];
static bool lot_dl_err_set = false;

void *lot_dlopen(const char *file, int mode);
void *lot_dlsym(void *handle, const char *name);
char *lot_dlerror(void);
int lot_dlclose(void *handle);

void *
lot_dlopen(const char *file, int mode)
{{
\tconst char *base = strrchr(file, '/');
\tsize_t len;

\tbase = base ? base + 1 : file;
\tlen = strlen(base);
\tif (len > 3 && strcmp(base + len - 3, ".so") == 0)
\t\tlen -= 3;
\tfor (const lot_mod *m = lot_mods; m->lib; m++)
\t\tif (strlen(m->lib) == len && strncmp(m->lib, base, len) == 0)
\t\t\treturn (void *) m;
\tsnprintf(lot_dl_err, sizeof(lot_dl_err),
\t\t\t "%s: not linked into this postgres (LinuxOnTab builds have no dynamic loading)", file);
\tlot_dl_err_set = true;
\treturn NULL;
}}

void *
lot_dlsym(void *handle, const char *name)
{{
\tconst lot_mod *m = handle;

\tfor (const lot_sym *s = m->syms; s->name; s++)
\t\tif (strcmp(s->name, name) == 0)
\t\t\treturn s->addr;
\tsnprintf(lot_dl_err, sizeof(lot_dl_err), "%s: undefined symbol in %s", name, m->lib);
\tlot_dl_err_set = true;
\treturn NULL;
}}

char *
lot_dlerror(void)
{{
\tif (!lot_dl_err_set)
\t\treturn NULL;
\tlot_dl_err_set = false;
\treturn lot_dl_err;
}}

int
lot_dlclose(void *handle)
{{
\treturn 0;
}}
"""
open(f"{out}/lot_static_modules.c", "w").write(src)
print("==> static modules:", ", ".join(f"{m} ({len(o)} objs)" for m, o in mods.items()))
PYEOF
    $LOTCC $PGCFLAGS $PGCPPFLAGS -D_GNU_SOURCE -Isrc/include \
        -c "$LOT/mods/lot_static_modules.c" -o "$LOT/mods/lot_static_modules.o"
    MODOBJS="$LOT/mods/lot_static_modules.o $(awk '{print $2}' "$LOT/mods/objs.list" | tr '\n' ' ')"

    # ── the server ───────────────────────────────────────────────────────
    make -C src/backend -j8 postgres LIBS="-lm $MODOBJS"
    if command -v wasm-objdump >/dev/null 2>&1 && \
       wasm-objdump -x src/backend/postgres | grep -q "signature_mismatch"; then
        echo "postgres: wasm-ld emitted signature_mismatch stubs" >&2; exit 1
    fi

    # ── clients: libpq static only, initdb, psql ─────────────────────────
    (cd src/interfaces/libpq && make -j8 all-static-lib && sleep 1 &&
     touch libpq.so.5.17 libpq-refs-stamp &&
     ln -sf libpq.so.5.17 libpq.so.5 && ln -sf libpq.so.5.17 libpq.so)
    make -C src/bin/initdb -j8
    # libpq.so would export the encoding helpers psql uses (pg_encoding_to_char …)
    make -C src/bin/psql -j8 LIBS="-lpgcommon -lpgport -lm -lpgcommon_shlib -lpgport_shlib"

    # ── install ──────────────────────────────────────────────────────────
    make -C src/backend install DESTDIR="$STAGE" LIBS="-lm $MODOBJS"
    make -C src/include/catalog install DESTDIR="$STAGE"
    make -C src/timezone install DESTDIR="$STAGE" ZIC="$ZIC"
    make -C src/pl/plpgsql/src install-data DESTDIR="$STAGE"
    make -C src/backend/snowball snowball_create.sql
    PGSHARE="$STAGE/usr/share/postgresql"
    cp src/backend/snowball/snowball_create.sql "$PGSHARE/"
    mkdir -p "$PGSHARE/tsearch_data"
    cp src/backend/snowball/stopwords/*.stop "$PGSHARE/tsearch_data/"
    mkdir -p "$STAGE/usr/lib/postgresql"
    for _m in $(awk '{print $1}' "$LOT/mods/objs.list" | sort -u); do
        : > "$STAGE/usr/lib/postgresql/$_m.so"     # placeholder: linked in
    done
    # initdb (popen/system) and psql (pager, \!) spawn children: asyncify them
    for _b in initdb psql; do
        "$WASM_OPT" --enable-exception-handling --asyncify -O1 \
            "src/bin/$_b/$_b" -o "$STAGE/usr/bin/$_b"
        chmod 755 "$STAGE/usr/bin/$_b"
    done

    cat > "$STAGE/usr/bin/postgres-demo" <<'DEMOEOF'
#!/bin/sh
# postgres-demo [database] — PostgreSQL 17 on LinuxOnTab.
# First run: initdb /var/lib/postgresql/data (superuser "postgres", trust
# auth, UTF8). Then the server runs in the foreground on 0.0.0.0:5432 and
# the Unix socket in /tmp. This build is single-process: it serves ONE
# client at a time (others wait; an idle session yields to a new client)
# and one database per server process (asking for another one restarts
# the server for it, keeping the client).
#   psql -U postgres                    (Unix socket)
#   psql -h 127.0.0.1 -U postgres       (TCP; also from other tabs)
# Stop: Ctrl-C or kill -TERM <pid> (clean shutdown with a checkpoint).
PGDATA="${PGDATA:-/var/lib/postgresql/data}"
export PGDATA
DB="${1:-postgres}"
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo " postgres-demo: first run, creating a database cluster in $PGDATA"
    mkdir -p "$PGDATA" || exit 1
    chmod 700 "$PGDATA"
    initdb -D "$PGDATA" -U postgres --auth=trust -E UTF8 --no-locale \
        --no-instructions -c listen_addresses='*' -c shared_buffers=16MB \
        -c max_connections=10 -c max_worker_processes=0 \
        -c max_parallel_workers_per_gather=0 -c max_wal_size=256MB \
        -c dynamic_shared_memory_type=posix || exit 1
fi
echo " postgres-demo: serving database \"$DB\" on port 5432 (one client at a time)"
echo "   psql -U postgres $DB      or      psql -h 127.0.0.1 -U postgres $DB"
# Restart after a crash (status >= 2); 0/1 = clean stop or startup error.
while :; do
    postgres -D "$PGDATA" "$DB"
    rc=$?
    case $rc in
        0|1) exit $rc ;;
    esac
    echo " postgres-demo: server exited with status $rc; restarting in 2 s" >&2
    sleep 2
done
DEMOEOF
    chmod 755 "$STAGE/usr/bin/postgres-demo"

    # no headers, pkgconfig, docs or static libs in the package
    rm -rf "$STAGE/usr/include" "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share/doc"
    rmdir "$STAGE/bin" 2>/dev/null || true
    echo "==> staged:"; (cd "$STAGE" && find . -type f | sed 's|^\./||' | grep -v '^usr/share/postgresql/timezone/' | sort)
}
