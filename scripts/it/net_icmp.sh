#!/usr/bin/env bash
# scripts/it/net_icmp.sh — v1.4.0 net band ICMP gate (docs/adr/0012). An agnos client under mirshi
# does icmp_echo#55(127.0.0.1) and prints a marker if the RTT is >=0 — proving the supervisor's
# UNPRIVILEGED ping path (SOCK_DGRAM+IPPROTO_ICMP, never SOCK_RAW/CAP_NET_RAW), the bounded
# ppoll(POLLIN) reply wait, and per-destination egress. Unprivileged ICMP is environment-sensitive
# (net.ipv4.ping_group_range), so we SKIP gracefully where the kernel forbids it. Needs python3 +
# the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
command -v python3 >/dev/null || { echo "SKIP: net_icmp — python3 not available"; exit 0; }
# Preflight: can THIS environment open the exact socket mirshi will? (ping_group_range / sandbox.)
python3 -c 'import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP).close()' 2>/dev/null \
    || { echo "SKIP: net_icmp — unprivileged ICMP socket unavailable (ping_group_range / sandbox)"; exit 0; }
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

# agnos client: ping 127.0.0.1, print a marker on RTT >= 0, else exit 1 (timeout / denied).
cat > "$sbox/pingc.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    var rtt = sys_icmp_echo(0x7F000001);   # ping 127.0.0.1 (agnos kernel-ip4 form)
    if (rtt < 0) { return 1; }             # timeout / host down / no permission
    var ok = "PING-AGNOS-OK";
    sys_write(1, ok, strlen(ok));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/pingc.cyr" "$sbox/pingc" >/dev/null 2>&1

# loopback ping allowed: --net-allow covers 127.0.0.1 -> RTT >= 0, marker printed, rc 0.
set +e; out="$(timeout 20 "$mirshi" --net-allow "127.0.0.1/32" "$sbox/pingc" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "PING-AGNOS-OK"; then
    echo "OK: agnos icmp_echo(127.0.0.1) round-trip -> RTT >= 0"
else
    echo "FAIL: icmp round-trip rc=$rc out='$(printf '%s' "$out" | head -c 40)'" >&2; fail=1
fi

# egress denied: loopback not covered by --net-allow 10/8 -> icmp_echo -1 (the fixture returns 1).
set +e; "$mirshi" --net-allow "10.0.0.0/8" "$sbox/pingc" >/dev/null 2>&1; rc2=$?; set -e
if [ "$rc2" -eq 1 ]; then echo "OK: icmp_echo egress-denied (loopback not in 10/8) -> agnos -1"
else echo "FAIL: icmp egress-deny rc=$rc2 (want 1)" >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "net_icmp: FAILED" >&2; exit 1; fi
echo "OK: net_icmp — unprivileged icmp_echo RTT + per-destination egress"
