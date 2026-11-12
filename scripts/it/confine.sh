#!/usr/bin/env bash
# scripts/it/confine.sh — 0.7.1 path-confinement gate (docs/audit/2026-06-30-audit.md
# class-c). Under `--root <dir>`, mirshi rewrites every open#7 to openat2 anchored at a
# per-child rootfd with RESOLVE_IN_ROOT, so the kernel CLAMPS escapes to the root:
# absolute host paths, `..` traversal, and symlink targets all resolve INSIDE the root
# (the host file is unreachable), while legitimate in-root paths still work.
#
# Self-validating: it first proves WITHOUT --root the escape SUCCEEDS (the documented
# footgun — the container mount NS is the only boundary then), so the WITH --root
# "DENIED" results genuinely gate the confinement, not some unrelated failure.
#
# Same same-uid ptrace requirements as the M0/M1/M2 integration tests.
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root_dir"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root_dir/build/mirshi"

sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
jail="$sbox/jail"; mkdir -p "$jail"
fix="$sbox/fix"; mkdir -p "$fix"
fail=0

echo "IN-ROOT-OK" > "$jail/data.txt"                       # a legit in-root file
secret="$sbox/hostsecret.txt"; echo "HOST-SECRET" > "$secret"  # OUTSIDE the jail
ln -sf "$secret" "$jail/escape_link"                       # in-jail symlink -> host secret

# Build an open#7(path) RDONLY fixture: prints "DENIED" on -1, else the file content.
mkfix() { # name  path
    cat > "$fix/$1.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var p = "$2";
    var fd = syscall(7, p, ${#2}, 0);
    if (fd == 0 - 1) { syscall(1, 1, "DENIED\n", 7); return 0; }
    var b[64]; var n = syscall(5, fd, &b, 64); syscall(1, 1, &b, n); return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$fix/$1.cyr" "$fix/$1" >/dev/null 2>&1
}
mkfix exfil "$secret"               # absolute host path OUTSIDE the jail
mkfix trav  "../../../../$secret"   # .. traversal toward the host secret
mkfix sym   "/escape_link"          # in-jail symlink whose target is the host secret
mkfix inroot "/data.txt"            # legit in-root absolute path (rebased to the root)

ck() { # name  expected-substring  actual
    if printf '%s' "$3" | grep -q "$2"; then echo "OK: $1 ($3)"; else
        echo "FAIL: $1 — expected '$2', got '$3'" >&2; fail=1; fi
}

# (0) Self-validation: WITHOUT --root the escape SUCCEEDS (proves --root is load-bearing).
ck "no --root -> escape leaks (footgun)" "HOST-SECRET" "$(timeout 15 "$mirshi" "$fix/exfil" 2>/dev/null)"

# (1..3) WITH --root: every escape form is CLAMPED.
ck "abs host path clamped"  "DENIED" "$(timeout 15 "$mirshi" --root "$jail" "$fix/exfil" 2>/dev/null)"
ck ".. traversal clamped"   "DENIED" "$(timeout 15 "$mirshi" --root "$jail" "$fix/trav"  2>/dev/null)"
ck "symlink target clamped" "DENIED" "$(timeout 15 "$mirshi" --root "$jail" "$fix/sym"   2>/dev/null)"
# (4) WITH --root: a legitimate in-root path still resolves.
ck "in-root path resolves"  "IN-ROOT-OK" "$(timeout 15 "$mirshi" --root "$jail" "$fix/inroot" 2>/dev/null)"

# (5) WITH --root: path-MUTATION ops are CONFINED via *at(ROOTFD, sanitized) (bite 2).
#   (a) an absolute host path unlink rebases INTO the root, so the host file is untouched.
victim="$sbox/host_victim.txt"; echo keep > "$victim"
cat > "$fix/unlinker.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 { syscall(30, "$victim", ${#victim}); return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/unlinker.cyr" "$fix/unlinker" >/dev/null 2>&1
timeout 15 "$mirshi" --root "$jail" "$fix/unlinker" >/dev/null 2>&1 || true
if [ -e "$victim" ]; then echo "OK: host-abs unlink contained under --root — host file survived"
else echo "FAIL: unlink ESCAPED under --root — host file deleted!" >&2; fail=1; fi

#   (b) a `..` mutation path is clamped AT THE ROOT (1.12.3: openat2 RESOLVE_IN_ROOT, as the kernel resolves
#   `..` never above `/`): mkdir("../escaped") creates jail/escaped, and nothing appears above the jail.
cat > "$fix/mktrav.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { var r = syscall(9, "../escaped", 10); if (r == 0) { syscall(1,1,"CLAMPED\n",8); } return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/mktrav.cyr" "$fix/mktrav" >/dev/null 2>&1
ck ".. mutation clamped at the root" "CLAMPED" "$(timeout 15 "$mirshi" --root "$jail" "$fix/mktrav" 2>/dev/null)"
if [ ! -d "$jail/escaped" ]; then echo "FAIL: .. mkdir did not land inside the jail" >&2; fail=1; fi
if [ -e "$sbox/escaped" ]; then echo "FAIL: .. mkdir ESCAPED to the sbox!" >&2; fail=1; rm -rf "$sbox/escaped"; fi

#   (c) a LEGITIMATE in-root mutation works (mkdir creates a dir inside the root).
cat > "$fix/mkin.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { var r = syscall(9, "/made", 5); if (r == 0 - 1) { syscall(1,1,"FAIL\n",5); } else { syscall(1,1,"MADE\n",5); } return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/mkin.cyr" "$fix/mkin" >/dev/null 2>&1
ck "in-root mkdir works" "MADE" "$(timeout 15 "$mirshi" --root "$jail" "$fix/mkin" 2>/dev/null)"
if [ ! -d "$jail/made" ]; then echo "FAIL: in-root mkdir did not create jail/made" >&2; fail=1; fi

#   (d) 1.12.3: path ops through an in-root symlink whose target is an absolute host directory. Every
#   confined op resolves its parent inside the root (openat2 RESOLVE_IN_ROOT in the supervisor), so the
#   host directory must come out of this unchanged, and each op must answer -1.
outdir="$sbox/outside"; mkdir -p "$outdir"
touch "$outdir/keep1" "$outdir/keep2" "$outdir/keep3"
ln -sfn "$outdir" "$jail/out"
cat > "$fix/viaslink.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn chk(r, code): i64 { if (r != (0 - 1)) { return code; } return 0; }
fn main(): i64 {
    var st[64];
    var lb[64];
    var e = 0;
    e = chk(syscall(9, "out/newdir", 10), 10); if (e != 0) { return e; }                 # mkdir
    e = chk(syscall(10, "out/keep1", 9), 11); if (e != 0) { return e; }                  # rmdir
    e = chk(syscall(30, "out/keep1", 9), 12); if (e != 0) { return e; }                  # unlink
    e = chk(syscall(31, "out/keep2", 9, "out/moved", 9), 13); if (e != 0) { return e; }  # rename
    e = chk(syscall(32, "data.txt", 8, "out/hard", 8), 14); if (e != 0) { return e; }    # link
    e = chk(syscall(33, "out/keep3", 9, &st), 15); if (e != 0) { return e; }             # stat
    e = chk(syscall(70, "out/keep3", 9, &lb, 64), 16); if (e != 0) { return e; }         # readlink
    if (syscall(33, "data.txt", 8, &st) != 0) { return 20; }                              # in-root stat works
    syscall(1, 1, "CONTAINED\n", 10);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/viaslink.cyr" "$fix/viaslink" >/dev/null 2>&1 || { echo "FAIL: viaslink fixture did not build" >&2; exit 1; }
ck "path ops via an in-root host symlink" "CONTAINED" "$(timeout 15 "$mirshi" --root "$jail" "$fix/viaslink" 2>/dev/null)"
if [ "$(ls "$outdir" | sort | tr '\n' ' ')" != "keep1 keep2 keep3 " ]; then
    echo "FAIL: the host directory behind the in-root symlink changed: $(ls "$outdir" | tr '\n' ' ')" >&2; fail=1
fi

#   (e) 1.12.3: fds the child did not open itself. mirshi closes every inherited fd >= 3 before exec, so a
#   descriptor its own parent leaked cannot be used to reach outside the root; and close#6 / dup#8 cannot
#   disturb the root anchor (fd >= 32 is refused, dup is the kernel's identity).
cat > "$fix/fdhyg.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    if (syscall(6, 100) != (0 - 1)) { return 30; }           # close of the root anchor's slot -> -1
    if (syscall(8, 5) != 5) { return 31; }                   # dup is the identity
    var st[64];
    if (syscall(111, 5) != (0 - 1)) { return 32; }           # the inherited fd 5 is gone
    if (syscall(33, "data.txt", 8, &st) != 0) { return 33; } # the root still resolves
    syscall(1, 1, "FDS-OK\n", 7);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/fdhyg.cyr" "$fix/fdhyg" >/dev/null 2>&1 || { echo "FAIL: fdhyg fixture did not build" >&2; exit 1; }
ck "inherited fds closed, root anchor protected" "FDS-OK" "$(timeout 15 "$mirshi" --root "$jail" "$fix/fdhyg" 5</ 2>/dev/null)"

#   (f) 1.12.3: execwait#37 resolves the path it is given INSIDE the root. A copy of a marker program
#   inside the jail runs; the same program named by its host path outside the jail does not.
cat > "$fix/marker.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { syscall(1, 1, "MARKER-RAN\n", 11); return 7; }
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/marker.cyr" "$fix/marker" >/dev/null 2>&1 || { echo "FAIL: marker fixture did not build" >&2; exit 1; }
mkdir -p "$jail/bin"; cp "$fix/marker" "$jail/bin/marker"
cat > "$fix/ewroot.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var inr = "/bin/marker";
    if (sys_execwait(inr, strlen(inr)) != 7) { syscall(1, 1, "INROOT-FAILED\n", 14); return 1; }
    var host = "$fix/marker";
    var rc = sys_execwait(host, strlen(host));
    if (rc == 7) { syscall(1, 1, "HOST-RAN\n", 9); return 2; }
    syscall(1, 1, "EXEC-CONFINED\n", 14);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/ewroot.cyr" "$fix/ewroot" >/dev/null 2>&1 || { echo "FAIL: ewroot fixture did not build" >&2; exit 1; }
ewout="$(timeout 20 "$mirshi" --root "$jail" "$fix/ewroot" 2>/dev/null)"
if printf '%s' "$ewout" | grep -q "EXEC-CONFINED" && [ "$(printf '%s' "$ewout" | grep -c MARKER-RAN)" -eq 1 ]; then
    echo "OK: execwait#37 under --root — the in-root program ran, the host path did not"
else
    echo "FAIL: execwait#37 under --root: $(printf '%s' "$ewout" | tr '\n' '|')" >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "confine: FAILED" >&2; exit 1; fi
echo "OK: confine — --root clamps open + mutation escapes (abs/traversal/symlink, via an in-root host symlink), inherited fds closed, in-root ops work"
