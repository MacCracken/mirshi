#!/usr/bin/env bash
# scripts/it/net_udp.sh — v1.3.0 net band UDP gate (docs/adr/0012). An agnos UDP client under
# mirshi does udp_bind#51 (loopback), udp_send#52 a datagram (egress-checked) to a local UDP echo
# server, udp_recv#53 the reply WITH the sender addr_out {ip@0, port@8}, and udp_unbind#54 — proving
# the listener-table model, the packed (sport<<16)|dport, the addr_out repack, and per-datagram
# egress. Needs python3 + the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
command -v python3 >/dev/null || { echo "SKIP: net_udp — python3 not available"; exit 0; }
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; srv=""
trap 'if [ -n "$srv" ]; then kill "$srv" 2>/dev/null || true; fi; rm -rf "$sbox"' EXIT
fail=0
freeudp() { python3 -c 'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
dport="$(freeudp)"; sport="$(freeudp)"

# a UDP echo server on dport: recvfrom one datagram, send a marker back to the sender.
python3 - "$dport" "$sbox/ready" <<'PY' &
import socket, sys
port = int(sys.argv[1]); ready = sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", port)); open(ready, "w").close()
try:
    data, addr = s.recvfrom(4096)
    s.sendto(b"UDP-AGNOS-OK", addr)
except Exception:
    pass
PY
srv=$!
for _ in $(seq 1 50); do [ -f "$sbox/ready" ] && break; sleep 0.1; done
[ -f "$sbox/ready" ] || { echo "FAIL: udp server never came up" >&2; exit 1; }

# agnos client: bind sport, send "DNSQ" to 127.0.0.1:dport, recv the reply + sender addr, verify both.
cat > "$sbox/udpc.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var lid = sys_udp_bind($sport);
    if (lid < 0) { return 1; }
    var q = "DNSQ";
    var packed = ($sport * 65536) + $dport;         # (sport<<16)|dport
    var s = sys_udp_send(0x7F000001, packed, q, strlen(q));
    if (s < 0) { sys_udp_unbind(lid); return 2; }
    var buf[256];
    var addr[16];
    var n = 0;
    var t = 0;
    while (t < 5000) {
        n = sys_udp_recv(lid, &buf, 256, &addr);
        if (n > 0) { t = 5000; } else { if (n < 0) { t = 5000; } else { syscall(41, 2); t = t + 1; } }
    }
    sys_udp_unbind(lid);
    if (n <= 0) { return 3; }
    sys_write(1, &buf, n);                            # the reply -> stdout
    if (load64(&addr) != 0x7F000001) { return 4; }    # sender ip@0 = 127.0.0.1 (kernel-ip4)
    if (load64(&addr + 8) != $dport) { return 5; }    # sender port@8 = the server port
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/udpc.cyr" "$sbox/udpc" >/dev/null 2>&1

set +e; out="$(timeout 25 "$mirshi" --net-allow "127.0.0.1/32" "$sbox/udpc" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "UDP-AGNOS-OK"; then
    echo "OK: agnos udp bind/send/recv round-trip + addr_out {ip,port} verified"
else
    echo "FAIL: udp round-trip rc=$rc out='$(printf '%s' "$out" | head -c 40)'" >&2; fail=1
fi

# egress denied: a dst not covered by --net-allow -> udp_send -1 (the fixture returns 2).
set +e; "$mirshi" --net-allow "10.0.0.0/8" "$sbox/udpc" >/dev/null 2>&1; rc2=$?; set -e
if [ "$rc2" -eq 2 ]; then echo "OK: udp_send egress-denied (loopback not in 10/8) -> agnos -1"
else echo "FAIL: udp egress-deny rc=$rc2 (want 2)" >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "net_udp: FAILED" >&2; exit 1; fi
echo "OK: net_udp — UDP bind/send/recv/unbind + addr_out + per-datagram egress"
