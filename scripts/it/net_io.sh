#!/usr/bin/env bash
# scripts/it/net_io.sh — v1.1.0 net band send/recv gate + the MVP demo (docs/adr/0012).
# An agnos "httpget" does a full TCP round-trip under mirshi: sock_connect#47, sock_send#48
# (the GET request), sock_recv#49 in a loop until EOF — exercising the INVERTED recv-EOF
# convention (0=WOULD_BLOCK -> sleep+retry, -1=EOF -> stop) — then sock_close#50, against a
# local HTTP server; the response body comes back on stdout. Proves the emulated send/recv
# path + net_recv_to_agnos end-to-end. Needs python3 + the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
command -v python3 >/dev/null || { echo "SKIP: net_io — python3 not available"; exit 0; }
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; srv=""
trap 'if [ -n "$srv" ]; then kill "$srv" 2>/dev/null || true; fi; rm -rf "$sbox"' EXIT
fail=0
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

# a tiny HTTP server: read the request, send a fixed body with a marker, close (-> EOF).
python3 - "$port" "$sbox/ready" <<'PY' &
import socket, sys
port = int(sys.argv[1]); ready = sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(8)
open(ready, "w").close()
try:
    while True:
        c, _ = s.accept()
        try: c.recv(4096)
        except Exception: pass
        c.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 15\r\n\r\nHELLO-AGNOS-NET")
        c.close()
except Exception:
    pass
PY
srv=$!
for _ in $(seq 1 50); do [ -f "$sbox/ready" ] && break; sleep 0.1; done
[ -f "$sbox/ready" ] || { echo "FAIL: test server never came up" >&2; exit 1; }

# agnos httpget: connect -> send GET -> recv loop (0=WOULD_BLOCK sleep+retry, -1=EOF stop) -> close.
cat > "$sbox/httpget.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var c = sys_sock_connect(0x7F000001, $port, 0);
    if (c < 0) { return 1; }
    var req = "GET / HTTP/1.0\r\nHost: t\r\n\r\n";
    sys_sock_send(c, req, strlen(req));
    var buf[512];
    var got = 0;
    while (1 == 1) {
        var n = sys_sock_recv(c, &buf, 512);
        if (n == (0 - 1)) { break; }              # agnos EOF
        if (n > 0) { sys_write(1, &buf, n); got = got + n; }
        else { syscall(41, 2); }                  # WOULD_BLOCK (0) -> sleep 2ms, retry
    }
    sys_sock_close(c);
    if (got > 0) { return 0; }
    return 2;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/httpget.cyr" "$sbox/httpget" >/dev/null 2>&1

out="$(timeout 30 "$mirshi" --net-allow "127.0.0.1/32" "$sbox/httpget" 2>/dev/null || true)"
if printf '%s' "$out" | grep -q "HELLO-AGNOS-NET"; then
    echo "OK: agnos httpget -> connect+send+recv(loop,EOF)+close -> response body received"
else
    echo "FAIL: httpget response missing marker; got: $(printf '%s' "$out" | head -c 200)" >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "net_io: FAILED" >&2; exit 1; fi
echo "OK: net_io — send/recv + inverted-EOF proven end-to-end (agnos HTTP GET round-trip)"
