#!/usr/bin/env bash
# scripts/it/info.sh — v1.8.0 info-getters gate (BITE 2: uname#34; sysinfo#35 added in BITE 3; 1.11.3: the
# sysinfo#35 40/104/200/208 length tiers + uptime_us#95). agnos
# uname#34 is EMULATE: mirshi writes the agnos-NATIVE 64-byte identity struct — four 16-byte NUL-padded
# fields at 0/16/32/48 = sysname/nodename/release/machine (NOT Linux utsname). This gate proves the exact
# field layout + values and that a too-small len is hard-rejected (-1, no partial fill). Same-uid ptrace req.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

cat > "$sbox/un.cyr" <<'EOF'
include "lib/syscalls.cyr"
# compare a 16-byte NUL-padded field `a` against the NUL-terminated expected string `b`.
fn feq(a, b): i64 {
    var i = 0;
    while (i < 16) {
        var bc = load8(b + i);
        if (load8(a + i) != bc) { return 0; }
        if (bc == 0) { return 1; }
        i = i + 1;
    }
    return 1;
}
# sysinfo#35 into a 0xAA-filled 320-byte `tb` with caller len `len`; 0 when rc == 0 and bytes
# [expect, 320) are all still 0xAA (nothing past the tier written) and [0, expect) are not all 0xAA.
fn tier(tb, len, expect): i64 {
    var i = 0;
    while (i < 320) { store8(tb + i, 0xAA); i = i + 1; }
    if (syscall(SYS_SYSINFO, tb, len) != 0) { return 1; }
    i = expect;
    while (i < 320) { if (load8(tb + i) != 0xAA) { return 2; } i = i + 1; }
    var w = 0;
    i = expect - 8;
    while (i < expect) { if (load8(tb + i) != 0xAA) { w = 1; } i = i + 1; }
    if (w == 0) { return 3; }                            # the tier's last u64 was not written
    return 0;
}
fn main(): i64 {
    var buf = alloc(64);
    if (syscall(SYS_UNAME, buf, 64) != 0) { return 2; }
    if (feq(buf +  0, "AGNOS") == 0) { return 3; }         # sysname
    if (feq(buf + 16, "agnos") == 0) { return 4; }         # nodename (kernel default)
    if (feq(buf + 32, "mirshi") == 0) { return 5; }        # release (marks the shim)
    if (feq(buf + 48, "x86_64") == 0) { return 6; }        # machine
    if (syscall(SYS_UNAME, buf, 32) != (0 - 1)) { return 7; }   # len < 64 -> hard -1 (no partial fill)
    # --- sysinfo#35: 5×u64 LE at 0/8/16/24/32 = uptime_secs / totalram / freeram / procs / cpus. Live
    # host values, so check plausible RANGES (not exact). ---
    var si = alloc(40);
    if (syscall(SYS_SYSINFO, si, 40) != 0) { return 10; }
    if (load64(si +  0) < 0) { return 11; }                # uptime_secs >= 0
    if (load64(si +  8) <= 0) { return 12; }               # totalram > 0
    if (load64(si + 16) <= 0) { return 13; }               # freeram > 0
    if (load64(si + 16) > load64(si + 8)) { return 14; }   # freeram <= totalram
    if (load64(si + 24) < 1) { return 15; }                # procs >= 1 (at least this process)
    if (load64(si + 32) < 1) { return 16; }                # cpus >= 1
    if (syscall(SYS_SYSINFO, si, 24) != (0 - 1)) { return 17; }   # len < 40 -> hard -1
    # --- sysinfo#35 TAIL TIERS (1.11.3): the kernel writes exactly 40/104/200/208 bytes by caller len.
    # A 0xAA sentinel past the tier proves nothing beyond it is written; inside it every byte is set. ---
    var tb = alloc(320);
    if (tier(tb, 104, 104) != 0) { return 20; }         # +40 per-core band written, +104.. untouched
    var u0 = load64(tb + 40);
    var k0 = load64(tb + 48);
    if (u0 + k0 <= 0) { return 21; }                     # slot 0 (a usable CPU) carries host ticks
    if (load64(tb + 32) < 4) {                           # slots past `cpus` read ZERO, as on the kernel
        var c = load64(tb + 32);
        while (c < 4) {
            if (load64(tb + 40 + c * 16) != 0) { return 22; }
            if (load64(tb + 48 + c * 16) != 0) { return 22; }
            c = c + 1;
        }
    }
    if (tier(tb, 150, 104) != 0) { return 23; }         # between tiers -> the lower one
    if (tier(tb, 200, 200) != 0) { return 24; }         # +104 BLK-tag band (zero: no agnos disks)
    var bi = 104;
    while (bi < 200) { if (load8(tb + bi) != 0) { return 25; } bi = bi + 1; }
    if (tier(tb, 208, 208) != 0) { return 26; }         # +200 sched_kicks (zero)
    if (load64(tb + 200) != 0) { return 27; }
    if (tier(tb, 300, 208) != 0) { return 28; }         # len > 208 still writes exactly 208
    if (tier(tb, 40, 40) != 0) { return 29; }           # len 40 byte-identical to 1.11.2: 40, no more
    # --- uptime_us#95 (1.11.3): emulated from CLOCK_MONOTONIC, monotonic, same epoch as uptime_ms#40.
    var t1 = syscall(SYS_UPTIME_US);
    var ms = syscall(SYS_UPTIME_MS);
    var t2 = syscall(SYS_UPTIME_US);
    if (t1 <= 0) { return 30; }                          # never -1 / 0 under mirshi (was ENOSYS -1)
    if (t2 < t1) { return 31; }                          # monotonic
    if (ms < t1 / 1000) { return 32; }                   # one epoch: t1 <= ms <= t2 (in ms)
    if (ms > t2 / 1000 + 1) { return 33; }
    var ok = "INFO-OK\n";
    sys_write(1, ok, strlen(ok));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/un.cyr" "$sbox/un" >/dev/null 2>&1

set +e; out="$(timeout 25 "$mirshi" "$sbox/un" 2>"$sbox/err")"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "INFO-OK"; then
    echo "OK: uname#34 (AGNOS/agnos/mirshi/x86_64 + len<64->-1) + sysinfo#35 (uptime/ram/procs/cpus plausible + len<40->-1 + the 40/104/200/208 tiers) + uptime_us#95"
else
    echo "FAIL: info rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')' (3-7=uname, 12/13/14=ram, 15/16=procs/cpus, 17=short-len, 20-29=sysinfo tiers, 30-33=uptime_us#95)" >&2
    fail=1
fi
# uptime_us#95 must be EMULATED, not ENOSYS'd (1.11.3): up to 1.11.2 every call printed this line.
if grep -q "ENOSYS agnos#95" "$sbox/err"; then
    echo "FAIL: uptime_us#95 still reaches mirshi's ENOSYS fallthrough" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "info: FAILED" >&2; exit 1; fi
echo "OK: info — uname#34 + sysinfo#35 (v1.8.0 BITE 2+3)"
