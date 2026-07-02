#!/usr/bin/env bash
# scripts/it/info.sh — v1.8.0 info-getters gate (BITE 2: uname#34; sysinfo#35 added in BITE 3). agnos
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
fn main(): i64 {
    var buf = alloc(64);
    if (syscall(SYS_UNAME, buf, 64) != 0) { return 2; }
    if (feq(buf +  0, "AGNOS") == 0) { return 3; }         # sysname
    if (feq(buf + 16, "agnos") == 0) { return 4; }         # nodename (kernel default)
    if (feq(buf + 32, "mirshi") == 0) { return 5; }        # release (marks the shim)
    if (feq(buf + 48, "x86_64") == 0) { return 6; }        # machine
    if (syscall(SYS_UNAME, buf, 32) != (0 - 1)) { return 7; }   # len < 64 -> hard -1 (no partial fill)
    var ok = "UNAME-OK\n";
    sys_write(1, ok, strlen(ok));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/un.cyr" "$sbox/un" >/dev/null 2>&1

set +e; out="$(timeout 25 "$mirshi" "$sbox/un" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "UNAME-OK"; then
    echo "OK: uname#34 -> agnos-native struct (sysname=AGNOS / nodename=agnos / release=mirshi / machine=x86_64) + len<64 -> -1"
else
    echo "FAIL: uname rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')' (3-6=field mismatch, 7=short-len not -1)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "info: FAILED" >&2; exit 1; fi
echo "OK: info — uname#34 (v1.8.0 BITE 2)"
