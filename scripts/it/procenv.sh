#!/usr/bin/env bash
# scripts/it/procenv.sh — 1.13.1 gate: the process environment (agnos 1.57.18), through the real trace path.
# Checked against the kernel at agnos aef48206 (kernel/core/syscall.cyr sys_chdir / sys_getcwd /
# spawn_load_child, elf.cyr's init env, proc.cyr's redir_*):
#   (1) the root child starts in mirshi's working directory with HOME=/ and PWD=<it>; getcwd#113 never cuts;
#   (2) chdir#112: relative, absolute, `..` cleaned lexically, a symlink kept as its own path; a missing
#       path, a file, length 0 and an interior NUL are -1 with the cwd unchanged;
#   (3) every path call resolves a relative path from the cwd (open / stat / lstat / mkdir / rename /
#       readdir / statfs / symlink — whose TARGET stays text — / readlink / unlink / rmdir);
#   (4) spawn_path#43's env: the default (HOME=/, PWD=<the caller's cwd>), a caller blob replacing it, its
#       PWD= seeding the child's cwd (a relative PWD= ignored), a bad blob falling back (unflagged) or
#       refused -6 (flagged);
#   (5) exec failures: -4 (missing, not executable), -5 (not an ELF), -6 (a resolved path over 255 bytes),
#       -1 from execwait#37 and spawn#3;
#   (6) the creator's fd table: inherited, scrubbed by SPAWN_F_CLEANFD except a redirect source, and
#       inherited by spawn#3 too;
#   (7) exec_redirect#62 pairs in arm order (`2>&1`), consumed by every #43 return — a failed one included;
#   (8) under --root: "/" to start, chdir clamped in the root (an escape link refused), relative paths and
#       spawns resolved inside it.
# Same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0
R="$sbox/run"; mkdir -p "$R/bin" "$R/d/sub"
: > "$R/file.txt"
printf 'not an elf\n' > "$R/notelf"; chmod +x "$R/notelf"
ln -s d "$R/lnk"
long="$(printf 'a%.0s' $(seq 1 250))"

helpers='
fn seq(a, b): i64 {
    if (a == 0) { return 0; }
    var i = 0;
    while (1 == 1) {
        var x = load8(a + i);
        if (x != load8(b + i)) { return 0; }
        if (x == 0) { return 1; }
        i = i + 1;
    }
    return 0;
}
fn say(fd, s): i64 { return syscall(1, fd, s, strlen(s)); }
fn cwd_is(want): i64 {
    var b[4200];
    var n = syscall(113, &b, 4200);
    if (n != strlen(want)) { return 0; }
    return seq(&b, want);
}
'

# The child: `kid env` prints its cwd and env; `kid fd3` / `kid fd5` write to that fd (exit 9 if it is
# closed); `kid out` writes to stdout and stderr; no argument (spawn#3) writes to fd 3.
cat > "$sbox/kid.cyr" <<EOF
include "lib/syscalls.cyr"
$helpers
fn show(k): i64 {
    var v = getenv(k);
    say(1, k); say(1, "=");
    if (v != 0) { say(1, v); } else { say(1, "<none>"); }
    say(1, "\n");
    return 0;
}
fn main(): i64 {
    if (argc() < 2) { if (syscall(1, 3, "S3\n", 3) == 3) { return 0; } return 9; }
    var m = argv(1);
    if (seq(m, "env") == 1) {
        var b[4200];
        var n = syscall(113, &b, 4200);
        say(1, "cwd="); syscall(1, 1, &b, n); say(1, "\n");
        show("PWD"); show("HOME"); show("X");
        return 0;
    }
    if (seq(m, "fd3") == 1) { if (syscall(1, 3, "FD3\n", 4) == 4) { return 0; } return 9; }
    if (seq(m, "fd5") == 1) { if (syscall(1, 5, "FD5\n", 4) == 4) { return 0; } return 9; }
    if (seq(m, "out") == 1) { say(1, "OUT\n"); say(2, "ERR\n"); return 0; }
    return 1;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/kid.cyr" "$R/bin/kid" >/dev/null 2>&1 || { echo "FAIL: kid fixture did not build" >&2; exit 1; }

# ---- (1)-(7) unconfined, run from $R ---------------------------------------------------------------------
cat > "$sbox/pe.cyr" <<EOF
include "lib/syscalls.cyr"
$helpers
fn run(line, n, flags): i64 {
    var c = syscall(43, line, n | flags, 0, 0);
    if (c < 0) { return 100 - c; }
    return syscall(4, c);
}
fn main(): i64 {
    var b[4200];
    # (1) where the root starts, and its env
    if (cwd_is("$R") != 1) { return 10; }
    if (seq(getenv("HOME"), "/") != 1) { return 11; }
    if (seq(getenv("PWD"), "$R") != 1) { return 12; }
    var L = strlen("$R");
    store8(&b, 0x55);
    if (syscall(113, &b, L) != (0 - 1)) { return 13; }              # cap L: -1, never cut
    if (load8(&b) != 0x55) { return 14; }                           # ...nothing written
    if (syscall(113, &b, L + 1) != L) { return 15; }
    # (2) chdir
    if (syscall(112, "d", 1) != 0) { return 20; }
    if (cwd_is("$R/d") != 1) { return 21; }
    if (syscall(112, "sub/../..", 9) != 0) { return 22; }           # lexical: back to $R
    if (cwd_is("$R") != 1) { return 23; }
    if (syscall(112, "lnk", 3) != 0) { return 24; }
    if (cwd_is("$R/lnk") != 1) { return 25; }                        # the link's path is kept
    if (syscall(112, "/", 1) != 0) { return 26; }
    if (cwd_is("/") != 1) { return 27; }
    if (syscall(112, "$R", L) != 0) { return 28; }
    if (syscall(112, "nope", 4) != (0 - 1)) { return 29; }
    if (syscall(112, "file.txt", 8) != (0 - 1)) { return 30; }
    if (syscall(112, "d", 0) != (0 - 1)) { return 31; }
    if (syscall(112, "d\0x", 3) != (0 - 1)) { return 32; }
    if (cwd_is("$R") != 1) { return 33; }                            # ...none of them moved it
    # (3) relative path calls, from $R/d
    syscall(112, "d", 1);
    var f = syscall(7, "new.txt", 7, 0x101);
    if (f < 0) { return 40; }
    syscall(1, f, "x", 1);
    syscall(6, f);
    var st[48];
    if (syscall(33, "new.txt", 7, &st) != 0) { return 41; }
    if (syscall(102, "../lnk", 6, &st) != 0) { return 42; }
    if ((load64(&st) & 0xF000) != 0xA000) { return 43; }
    if (syscall(9, "m", 1) != 0) { return 44; }
    if (syscall(31, "new.txt", 7, "m/moved.txt", 11) != 0) { return 45; }
    var pb[512];
    var k = 0;
    while (k < 512) { store8(&pb + k, 0); k = k + 1; }
    store8(&pb, 109);                                                  # "m"
    var rb[640];
    if (syscall(81, &pb, &rb, 10) != 1) { return 46; }
    if (seq(&rb, "moved.txt") != 1) { return 47; }
    var sf[32];
    if (syscall(103, "m", 1, &sf) != 0) { return 48; }
    if (syscall(63, "rel/target", 10, "sl", 2) != 0) { return 49; }
    var lk[64];
    if (syscall(70, "sl", 2, &lk, 64) != 10) { return 50; }          # the target text, verbatim
    if (syscall(30, "m/moved.txt", 11) != 0) { return 51; }
    if (syscall(10, "m", 1) != 0) { return 52; }
    # (4) spawn_path#43's env + the child's cwd (still in $R/d)
    say(1, "A\n");
    if (run("../bin/kid env", 14, 0) != 0) { return 60; }
    var e1 = "PWD=$R/d/sub\0X=1\0";
    say(1, "B\n");
    var c1 = syscall(43, "../bin/kid env", 14, e1, strlen("$R/d/sub") + 9);
    if (c1 < 0) { return 61; }
    if (syscall(4, c1) != 0) { return 62; }
    say(1, "C\n");
    var c2 = syscall(43, "../bin/kid env", 14, "PWD=sub\0X=2\0", 12);
    if (c2 < 0) { return 63; }
    if (syscall(4, c2) != 0) { return 64; }
    say(1, "D\n");
    var c3 = syscall(43, "../bin/kid env", 14, "X=3", 3);           # no final NUL: the default env
    if (c3 < 0) { return 65; }
    if (syscall(4, c3) != 0) { return 66; }
    if (syscall(43, "../bin/kid env", 14 | 0x20000, "X=3", 3) != (0 - 6)) { return 67; }   # flagged: refused
    syscall(112, "$R", L);
    # (5) exec failures
    if (syscall(43, "nope", 4, 0, 0) != (0 - 4)) { return 70; }
    if (syscall(43, "file.txt", 8, 0, 0) != (0 - 4)) { return 71; }  # not executable
    if (syscall(43, "notelf", 6, 0, 0) != (0 - 5)) { return 72; }
    if (syscall(37, "nope", 4, 0, 0) != (0 - 1)) { return 73; }
    var lb = "$long\0";
    if (syscall(43, lb, 251 | 0x10000, 0, 0) != (0 - 6)) { return 74; }   # 251 resolved past 255
    var g[256];
    k = 0;
    while (k < 256) { store8(&g + k, 0); k = k + 1; }
    if (syscall(3, &g, 256) != (0 - 1)) { return 75; }
    # (6) the creator's fd table
    var f3 = syscall(7, "$R/fd.txt", strlen("$R/fd.txt"), 0x101);
    if (f3 != 3) { return 80; }
    if (run("bin/kid fd3", 11, 0) != 0) { return 81; }              # inherited
    if (run("bin/kid fd3", 11, 0x20000) != 9) { return 82; }        # CLEANFD: fd 3 is gone
    if (syscall(62, 5, 3) != 0) { return 83; }
    if (run("bin/kid fd5", 11, 0x20000) != 0) { return 84; }        # ...but a redirect source stays
    var kp = "$R/bin/kid";
    var kf = syscall(7, kp, strlen(kp), 0);
    var img = alloc(1048576);
    var got = 0;
    while (1 == 1) { var nr = syscall(5, kf, img + got, 65536); if (nr <= 0) { break; } got = got + nr; }
    syscall(6, kf);
    var s3 = syscall(3, img, got);                                   # spawn#3 inherits the table too
    if (s3 < 0) { return 85; }
    if (syscall(4, s3) != 0) { return 86; }
    # (7) redirects
    var o = syscall(7, "$R/out.txt", strlen("$R/out.txt"), 0x101);
    if (syscall(62, 1, o) != 0) { return 90; }
    if (syscall(62, 0x100 | 2, 1) != 0) { return 91; }              # 2>&1
    if (run("bin/kid out", 11, 0) != 0) { return 92; }
    say(1, "F\n");
    if (run("bin/kid out", 11, 0) != 0) { return 93; }              # consumed: back on the real stdio
    if (syscall(62, 1, o) != 0) { return 94; }
    if (syscall(43, "nope", 4, 0, 0) != (0 - 4)) { return 95; }      # a failed #43 consumes it too
    say(1, "G\n");
    if (run("bin/kid out", 11, 0) != 0) { return 96; }
    say(1, "PROCENV-OK\n");
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/pe.cyr" "$sbox/pe" >/dev/null 2>&1 || { echo "FAIL: pe fixture did not build" >&2; exit 1; }
set +e; out="$(cd "$R" && timeout 60 "$mirshi" "$sbox/pe" </dev/null 2>"$sbox/err")"; rc=$?; set -e
expect() { # label  expected-line  after-marker
    if printf '%s\n' "$out" | sed -n "/^$3\$/,\$p" | grep -qxF -- "$2"; then :; else
        echo "FAIL: $1 — no line '$2' after marker $3" >&2; fail=1; fi
}
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q PROCENV-OK; then
    echo "OK: root cwd + env, getcwd, chdir, relative path calls, exec failures, fd inheritance, redirects"
else
    echo "FAIL: unconfined rc=$rc (see the fixture's return codes)" >&2; fail=1
fi
expect "default env"            "cwd=$R/d"      A; expect "default PWD" "PWD=$R/d" A; expect "default HOME" "HOME=/" A
expect "blob PWD seeds the cwd"  "cwd=$R/d/sub"  B; expect "blob replaces the env" "HOME=<none>" B; expect "blob X" "X=1" B
expect "relative PWD ignored"    "cwd=$R/d"      C; expect "...but carried" "PWD=sub" C; expect "blob X" "X=2" C
expect "bad blob -> default env" "HOME=/"        D; expect "...its PWD" "PWD=$R/d" D
expect "consumed redirect"       "OUT"           F; expect "failed #43 consumed it" "OUT" G
if [ "$(cat "$R/fd.txt" 2>/dev/null)" = "$(printf 'FD3\nFD5\nS3')" ]; then echo "OK: fd table inherited (#43, CLEANFD + redirect source, spawn#3)"
else echo "FAIL: fd.txt = '$(cat "$R/fd.txt" 2>/dev/null)'" >&2; fail=1; fi
if [ "$(cat "$R/out.txt" 2>/dev/null)" = "$(printf 'OUT\nERR')" ]; then echo "OK: exec_redirect pairs in arm order (2>&1), one child only"
else echo "FAIL: out.txt = '$(cat "$R/out.txt" 2>/dev/null)'" >&2; fail=1; fi
if [ "$(readlink "$R/d/sl" 2>/dev/null)" = "rel/target" ]; then echo "OK: symlink's link path resolved from the cwd, its target kept as text"
else echo "FAIL: \$R/d/sl -> '$(readlink "$R/d/sl" 2>/dev/null)'" >&2; fail=1; fi
if grep -q 'ENOSYS agnos#11[23] ' "$sbox/err"; then echo "FAIL: an ENOSYS line for chdir / getcwd" >&2; fail=1; fi

# ---- (8) under --root -------------------------------------------------------------------------------------
J="$sbox/jail"; mkdir -p "$J/bin" "$J/sub" "$sbox/hostdir"
cp "$R/bin/kid" "$J/bin/kid"
ln -s "$sbox/hostdir" "$J/esc"
cat > "$sbox/pr.cyr" <<EOF
include "lib/syscalls.cyr"
$helpers
fn main(): i64 {
    if (cwd_is("/") != 1) { return 10; }
    if (seq(getenv("PWD"), "/") != 1) { return 11; }
    if (syscall(112, "sub", 3) != 0) { return 12; }
    if (cwd_is("/sub") != 1) { return 13; }
    if (syscall(112, "..", 2) != 0) { return 14; }
    if (cwd_is("/") != 1) { return 15; }
    if (syscall(112, "/../../..", 9) != 0) { return 16; }
    if (cwd_is("/") != 1) { return 17; }
    if (syscall(112, "esc", 3) != (0 - 1)) { return 18; }           # the host directory is not in the root
    if (syscall(112, "/bin/kid", 8) != (0 - 1)) { return 19; }
    syscall(112, "sub", 3);
    var f = syscall(7, "x.txt", 5, 0x101);
    if (f < 0) { return 20; }
    syscall(6, f);
    var st[48];
    if (syscall(33, "x.txt", 5, &st) != 0) { return 21; }
    say(1, "A\n");
    var c = syscall(43, "../bin/kid env", 14, 0, 0);
    if (c < 0) { return 22; }
    if (syscall(4, c) != 0) { return 23; }
    if (syscall(43, "nope", 4, 0, 0) != (0 - 4)) { return 24; }
    say(1, "PROCENV-ROOT-OK\n");
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/pr.cyr" "$sbox/pr" >/dev/null 2>&1 || { echo "FAIL: pr fixture did not build" >&2; exit 1; }
set +e; out="$(timeout 30 "$mirshi" --root "$J" "$sbox/pr" </dev/null 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q PROCENV-ROOT-OK; then
    echo "OK: --root — the cwd starts at /, chdir is clamped in the root, relative paths and spawns resolve inside it"
else
    echo "FAIL: --root rc=$rc (see the fixture's return codes)" >&2; fail=1
fi
expect "--root child's cwd" "cwd=/sub" A; expect "--root child's PWD" "PWD=/sub" A
if [ -e "$J/sub/x.txt" ]; then echo "OK: a relative create under --root landed in the jail's /sub"
else echo "FAIL: \$J/sub/x.txt missing" >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "procenv: FAILED" >&2; exit 1; fi
echo "OK: procenv (1.13.1)"
