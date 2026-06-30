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

#   (b) a `..` mutation path is REJECTED by the sanitizer, and does not escape the root.
cat > "$fix/mktrav.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { var r = syscall(9, "../escaped", 10); if (r == 0 - 1) { syscall(1,1,"DENIED\n",7); } return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/mktrav.cyr" "$fix/mktrav" >/dev/null 2>&1
ck ".. mutation rejected" "DENIED" "$(timeout 15 "$mirshi" --root "$jail" "$fix/mktrav" 2>/dev/null)"
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

if [ "$fail" -ne 0 ]; then echo "confine: FAILED" >&2; exit 1; fi
echo "OK: confine — --root clamps open + mutation escapes (abs/traversal/symlink), in-root ops work"
