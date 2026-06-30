#!/usr/bin/env bash
# scripts/it/m2_fs.sh — M2 filesystem integration test: agnos coreutils-class
# tools read+write a real fs under mirshi's translation (no QEMU, no
# --selftest-trace). Proves the M2 acceptance via HOST EFFECTS, not just stdout.
#
# All fs ops are confined to a mktemp sandbox (cleaned on exit). The pure
# translation arithmetic is unit-tested under `cyrius test`; this is the live
# fork+exec+PTRACE_SYSCALL + process_vm_* path. Same ptrace requirements as the
# M0/M1 ITs (x86_64, same-uid child; container: --cap-add=SYS_PTRACE
# --security-opt seccomp=unconfined).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

cyrius build src/main.cyr build/mirshi >/dev/null

sbox="$(mktemp -d)"
trap 'rm -rf "$sbox"' EXIT
fix="$sbox/fix"; mkdir -p "$fix"

mirshi="$root/build/mirshi"

# Build an agnos fixture from stdin (paths use strlen() at runtime, so no path
# lengths are baked in) and echo the built binary path.
build_fix() {  # name
    local name="$1"
    cyrius build --agnos "$fix/$name.cyr" "$fix/$name" >/dev/null
    echo "$fix/$name"
}

ck() { # desc test-expr...
    local desc="$1"; shift
    if "$@"; then echo "OK: $desc"; else echo "FAIL: $desc" >&2; fail=1; fi
}

# Past setup: some fixtures legitimately exit non-zero (e.g. statbad -> 7) and we
# assert rc explicitly, so do NOT let set -e abort on a non-zero child. A fixture
# build failure still surfaces as a failed run assertion below.
set +e
fail=0

# --- writefile: open(CREAT|WRONLY|TRUNC) -> write -> close ---
cat > "$fix/writefile.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var p = "$sbox/out.txt";
    var fd = sys_open(p, strlen(p), AO_WRONLY | AO_CREAT | AO_TRUNC);
    if (fd < 0) { return 1; }
    sys_write(fd, "hello fs\n", 9);
    sys_close(fd);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix writefile >/dev/null
"$mirshi" "$fix/writefile"; rc=$?
ck "writefile rc==0" test "$rc" -eq 0
ck "writefile created host file" test -f "$sbox/out.txt"
ck "writefile content" test "$(cat "$sbox/out.txt")" = "hello fs"

# --- readfile (cat <file>): open(RDONLY) -> read -> write(stdout) -> close ---
printf 'seeded content line\n' > "$sbox/seed.txt"
cat > "$fix/readfile.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var p = "$sbox/seed.txt";
    var fd = sys_open(p, strlen(p), AO_RDONLY);
    if (fd < 0) { return 1; }
    var buf[512];
    var n = sys_read(fd, &buf, 512);
    if (n > 0) { sys_write(1, &buf, n); }
    sys_close(fd);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix readfile >/dev/null
got="$("$mirshi" "$fix/readfile")"; rc=$?
ck "readfile rc==0" test "$rc" -eq 0
ck "readfile echoes file content" test "$got" = "seeded content line"

# --- cpfile: two open()s (both modes), read/write loop, two closes ---
head -c 700 /dev/urandom | base64 | head -c 600 > "$sbox/cp_src.txt"
cat > "$fix/cpfile.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var sp = "$sbox/cp_src.txt";
    var dp = "$sbox/cp_dst.txt";
    var src = sys_open(sp, strlen(sp), AO_RDONLY);
    if (src < 0) { return 1; }
    var dst = sys_open(dp, strlen(dp), AO_WRONLY | AO_CREAT | AO_TRUNC);
    if (dst < 0) { return 2; }
    var buf[256];
    while (1 == 1) {
        var n = sys_read(src, &buf, 256);
        if (n <= 0) { sys_close(src); sys_close(dst); return 0; }
        sys_write(dst, &buf, n);
    }
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix cpfile >/dev/null
"$mirshi" "$fix/cpfile"; rc=$?
ck "cpfile rc==0" test "$rc" -eq 0
ck "cpfile dst matches src (cmp)" cmp -s "$sbox/cp_src.txt" "$sbox/cp_dst.txt"

# --- mkdirf: mkdir(path) ---
cat > "$fix/mkdirf.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var p = "$sbox/newdir";
    return sys_mkdir(p, strlen(p));
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix mkdirf >/dev/null
"$mirshi" "$fix/mkdirf"; rc=$?
ck "mkdirf rc==0" test "$rc" -eq 0
ck "mkdirf created host dir" test -d "$sbox/newdir"

# --- renamef: rename(a,b) (two-path, register MOVE) ---
printf 'rename me\n' > "$sbox/ren_a.txt"
cat > "$fix/renamef.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var a = "$sbox/ren_a.txt";
    var b = "$sbox/ren_b.txt";
    return sys_rename(a, strlen(a), b, strlen(b));
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix renamef >/dev/null
"$mirshi" "$fix/renamef"; rc=$?
ck "renamef rc==0" test "$rc" -eq 0
ck "renamef moved a->b" test ! -e "$sbox/ren_a.txt" -a -f "$sbox/ren_b.txt"

# --- linkf: link(a,b) hardlink (two-path) ---
printf 'link me\n' > "$sbox/lnk_a.txt"
cat > "$fix/linkf.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var a = "$sbox/lnk_a.txt";
    var b = "$sbox/lnk_b.txt";
    return sys_link(a, strlen(a), b, strlen(b));
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix linkf >/dev/null
"$mirshi" "$fix/linkf"; rc=$?
ck "linkf rc==0" test "$rc" -eq 0
ck "linkf created hardlink (same inode)" test "$sbox/lnk_a.txt" -ef "$sbox/lnk_b.txt"

# --- unlinkf: unlink(a) ---
printf 'delete me\n' > "$sbox/del.txt"
cat > "$fix/unlinkf.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var p = "$sbox/del.txt";
    return sys_unlink(p, strlen(p));
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix unlinkf >/dev/null
"$mirshi" "$fix/unlinkf"; rc=$?
ck "unlinkf rc==0" test "$rc" -eq 0
ck "unlinkf removed host file" test ! -e "$sbox/del.txt"

# --- statfile: stat(path,statbuf) -> the 144B->48B repack (mode + size) ---
printf '0123456789\n' > "$sbox/statme.txt"   # 11 bytes
cat > "$fix/statfile.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var p = "$sbox/statme.txt";
    var sb[48];
    if (sys_stat(p, strlen(p), &sb) != 0) { return 1; }
    var mode = load64(&sb + 0);
    if ((mode & 0x8000) != 0) { sys_write(1, "isfile ", 7); }   # S_IFREG type bit
    sys_write(1, "size=", 5);
    fmt_int(load64(&sb + 16));                                  # STAT_SIZE@16
    sys_write(1, "\n", 1);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix statfile >/dev/null
got="$("$mirshi" "$fix/statfile")"; rc=$?
ck "statfile rc==0" test "$rc" -eq 0
ck "statfile repack: regular file + size 11" test "$got" = "isfile size=11"

# --- statbad: stat of a nonexistent path -> agnos bare -1 (error convention) ---
cat > "$fix/statbad.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var p = "$sbox/does_not_exist";
    var sb[48];
    if (sys_stat(p, strlen(p), &sb) != 0) { return 7; }   # expect -1 (nonzero)
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix statbad >/dev/null
"$mirshi" "$fix/statbad"; rc=$?
ck "statbad: stat nonexistent -> agnos -1 (rc 7)" test "$rc" -eq 7

# --- listdir (ls): open(O_DIRECTORY) + getdents loop -> the dirent repack ---
mkdir -p "$sbox/ldir"
printf 'x' > "$sbox/ldir/alpha"; printf 'y' > "$sbox/ldir/beta"; mkdir "$sbox/ldir/sub"
cat > "$fix/listdir.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var p = "$sbox/ldir";
    var fd = sys_open(p, strlen(p), AO_RDONLY | AO_DIRECTORY);
    if (fd < 0) { return 1; }
    var buf[1024];
    while (1 == 1) {
        var n = sys_getdents(fd, &buf, 1024);
        if (n <= 0) { sys_close(fd); return 0; }
        var off = 0;
        while (off < n) {
            var reclen = load16(&buf + off + 0);
            var dtype = load8(&buf + off + 2);
            var namelen = load8(&buf + off + 3);
            if (dtype == 2) { sys_write(1, "d ", 2); } else { sys_write(1, "f ", 2); }
            sys_write(1, &buf + off + 8, namelen);
            sys_write(1, "\n", 1);
            off = off + reclen;
        }
    }
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix listdir >/dev/null
got="$("$mirshi" "$fix/listdir" | sort)"; rc="${PIPESTATUS[0]}"
ck "listdir rc==0" test "$rc" -eq 0
ck "listdir lists alpha (file)"  bash -c "printf '%s' \"\$1\" | grep -qx 'f alpha'" _ "$got"
ck "listdir lists beta (file)"   bash -c "printf '%s' \"\$1\" | grep -qx 'f beta'" _ "$got"
ck "listdir lists sub (dir type)" bash -c "printf '%s' \"\$1\" | grep -qx 'd sub'" _ "$got"
ck "listdir lists . and .. (dirs)" bash -c "printf '%s\n' \"\$1\" | grep -qx 'd .' && printf '%s\n' \"\$1\" | grep -qx 'd ..'" _ "$got"

if [ "$fail" -ne 0 ]; then
    echo "M2 fs integration test: FAILED" >&2
    exit 1
fi
echo "OK: M2 fs integration test — open/read/write/close/lseek/dup/cp/mkdir/rmdir/rename/link/unlink/stat/getdents under real translation"
