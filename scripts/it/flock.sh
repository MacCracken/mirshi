#!/usr/bin/env bash
# scripts/it/flock.sh — v1.8.0 info-getters + advisory-locks gate (BITE 1). getuid#15 is EMULATE -> 0 (the
# agnos environment is always root — mirshi returns 0, never the host uid); flock#59 is EXECUTE-in-child
# (renumbered to Linux flock(73); op codes identical SH=1/EX=2/UN=8/+NB=4). This gate proves getuid/geteuid
# return 0 and that flock is a real inode-keyed advisory lock: two separate OFDs to the same file CONTEND
# (LOCK_EX then LOCK_EX|NB -> -1), and unlocking releases it. Needs the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

cat > "$sbox/fl.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    # (1) getuid / geteuid -> 0 (always root; never the host uid)
    if (sys_getuid() != 0) { return 2; }
    if (sys_geteuid() != 0) { return 3; }
    # (2) flock contention across two OFDs to the same file (flock is OFD-scoped, so two open()s in one
    # process contend). LOCK_EX=2, LOCK_UN=8, LOCK_NB=4.
    var path = "$sbox/lockfile";
    var fd1 = sys_open(path, strlen(path), AO_RDWR | AO_CREAT);
    if (fd1 < 0) { return 4; }
    var fd2 = sys_open(path, strlen(path), AO_RDONLY);
    if (fd2 < 0) { return 5; }
    if (sys_flock(fd1, 2) != 0) { return 6; }               # fd1 LOCK_EX -> 0
    if (sys_flock(fd2, 2 | 4) != (0 - 1)) { return 7; }     # fd2 LOCK_EX|NB -> contends -> -1
    if (sys_flock(fd1, 8) != 0) { return 8; }               # fd1 LOCK_UN -> 0
    if (sys_flock(fd2, 2 | 4) != 0) { return 9; }           # fd2 LOCK_EX|NB -> now free -> 0
    if (sys_flock(fd2, 8) != 0) { return 10; }              # fd2 LOCK_UN -> 0
    sys_close(fd1);
    sys_close(fd2);
    var ok = "FLOCK-OK\n";
    sys_write(1, ok, strlen(ok));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/fl.cyr" "$sbox/fl" >/dev/null 2>&1

set +e; out="$(timeout 25 "$mirshi" "$sbox/fl" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "FLOCK-OK"; then
    echo "OK: getuid#15 -> 0 (always root) + flock#59 execute-in-child (two-OFD LOCK_EX contention + release)"
else
    echo "FAIL: flock rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')' (2/3=getuid!=0, 7=no-contention, 9=not-released)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "flock: FAILED" >&2; exit 1; fi
echo "OK: flock — getuid#15 + flock#59 (v1.8.0 BITE 1)"
