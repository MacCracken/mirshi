#!/usr/bin/env bash
# scripts/it/net_server.sh — v1.2.0 net band TCP-SERVER gate (docs/adr/0012). An agnos server runs
# under mirshi — sock_listen#56 (loopback bind by default), sock_accept#57 the incoming connection,
# sock_recv#49 the request, sock_send#48 a marker response, sock_close#50 the LISTENER (which REAPS
# the still-open accepted conn) — and a python client gets the marker back. Both bind modes are
# exercised (loopback default + --net-listen-any). Needs python3 + the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
command -v python3 >/dev/null || { echo "SKIP: net_server — python3 not available"; exit 0; }
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"; jobs -p | xargs -r kill 2>/dev/null || true' EXIT
fail=0

# python client: retry-connect to 127.0.0.1:$port, send PING, recv-to-EOF, write the bytes to $2.
cat > "$sbox/client.py" <<'PY'
import socket, sys, time
port = int(sys.argv[1]); out = sys.argv[2]
deadline = time.time() + 15; data = b""
while time.time() < deadline:
    try:
        c = socket.create_connection(("127.0.0.1", port), timeout=2)
        c.sendall(b"PING"); c.settimeout(5)
        while True:
            b = c.recv(256)
            if not b: break
            data += b
        c.close(); break
    except OSError:
        time.sleep(0.1)
open(out, "wb").write(data)
PY

# One server case: build the agnos server on a fresh port, launch mirshi (bg) with the given flags,
# run the client, assert the client got the marker AND mirshi's server exited 0.
server_case() { # label  mirshi-flags...
    local label="$1"; shift
    local port; port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    cat > "$sbox/srv.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var lid = sys_sock_listen($port);
    if (lid < 0) { return 1; }
    var c = 0 - 1;
    var t = 0;
    while (t < 5000) {
        c = sys_sock_accept(lid);
        if (c >= 0) { t = 5000; } else { syscall(41, 2); t = t + 1; }   # -1 = WOULD_BLOCK, retry
    }
    if (c < 0) { sys_sock_close(lid); return 2; }
    var buf[256];
    var rt = 0;
    while (rt < 5000) {
        var n = sys_sock_recv(c, &buf, 256);
        if (n > 0) { rt = 5000; } else { if (n == (0 - 1)) { rt = 5000; } else { syscall(41, 2); rt = rt + 1; } }
    }
    var resp = "SERVER-AGNOS-OK";
    sys_sock_send(c, resp, strlen(resp));
    sys_sock_close(lid);              # close the LISTENER -> reaps the still-open accepted conn
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$sbox/srv.cyr" "$sbox/srv" >/dev/null 2>&1
    "$mirshi" "$@" "$sbox/srv" >/dev/null 2>&1 &
    local mp=$!
    rm -f "$sbox/got"
    set +e; timeout 20 python3 "$sbox/client.py" "$port" "$sbox/got"; wait "$mp"; local src=$?; set -e
    if grep -q "SERVER-AGNOS-OK" "$sbox/got" 2>/dev/null && [ "$src" -eq 0 ]; then
        echo "OK: $label — agnos server accepted + replied; listener-close reaped the conn (srv exit 0)"
    else
        echo "FAIL: $label — got='$(head -c 40 "$sbox/got" 2>/dev/null)' srv_exit=$src" >&2; fail=1
    fi
}

server_case "loopback-default (bind 127.0.0.1)" --net
server_case "--net-listen-any (bind 0.0.0.0)"   --net-listen-any

if [ "$fail" -ne 0 ]; then echo "net_server: FAILED" >&2; exit 1; fi
echo "OK: net_server — TCP server (listen/accept/recv/send) + close-reaps-children"
