#!/usr/bin/env bash
# scripts/it/edges.sh — 1.12.3 gate: the kernel's answers at the edges of the fs / process / time calls,
# through the real trace path (raw syscall numbers, so no stdlib wrapper answers first).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

cat > "$sbox/edges.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var buf[64];
    if (syscall(45, &buf, 0 - 1, 0) != 0) { return 10; }          # getrandom len < 0 -> 0
    if (syscall(45, &buf, 0, 0) != 0) { return 11; }              # len 0 -> 0
    if (syscall(45, &buf, 16, 6) != 16) { return 12; }            # flags ignored
    if (syscall(41, 0 - 5) != (0 - 1)) { return 13; }             # sleep_ms < 0 -> -1
    if (syscall(41, 0) != 0) { return 14; }
    if (syscall(8, 1) != 1) { return 15; }                        # dup is the identity
    if (syscall(8, 29) != 29) { return 16; }
    if (syscall(6, 31) != 0) { return 17; }                       # close of a free fd < 32 -> 0
    if (syscall(6, 40) != (0 - 1)) { return 18; }                 # fd >= 32 -> -1
    var p = "$sbox/f";
    var f = syscall(7, p, strlen(p), 0x102);
    if (f < 0) { return 19; }
    if (syscall(58, f, 0, 3) != (0 - 1)) { return 20; }           # lseek whence 3 -> -1
    if (syscall(58, f, 0, 0) != 0) { return 21; }
    if (syscall(7, "$sbox/f", 0, 0) != (0 - 1)) { return 22; }    # open with length 0 -> -1
    var q = "$sbox/f";
    var ql = strlen(q) + 1;                                        # the length takes in the NUL
    if (syscall(7, q, ql, 0) != (0 - 1)) { return 23; }            # interior NUL -> -1
    var m = syscall(27, 0);                                        # mmap length 0 -> one 2 MB unit
    if (m == 0) { return 24; }
    store8(m + 2097151, 7);                                        # the last byte of the unit is mapped
    var d = "$sbox";
    var df = syscall(7, d, strlen(d), 0x800);
    if (df < 0) { return 25; }
    if (syscall(29, df, &buf, 0 - 1) != (0 - 1)) { return 26; }   # getdents bufsize < 0 -> -1
    if (syscall(29, df, &buf, 4) != (0 - 1)) { return 27; }       # too small for one record -> -1
    syscall(1, 1, "EDGES-OK\n", 9);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/edges.cyr" "$sbox/edges" >/dev/null 2>&1 || { echo "FAIL: edges fixture did not build" >&2; exit 1; }
set +e; out="$(timeout 25 "$mirshi" "$sbox/edges" </dev/null 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q EDGES-OK; then
    echo "OK: edges — getrandom / sleep_ms / dup / close / lseek / open / mmap / getdents edge answers match the kernel"
else
    echo "FAIL: edges rc=$rc (see the fixture's return codes)" >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "edges: FAILED" >&2; exit 1; fi
echo "OK: edges (1.12.3)"
