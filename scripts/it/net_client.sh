#!/usr/bin/env bash
# scripts/it/net_client.sh — v1.1.0 net band TCP-client gate (docs/adr/0012). mirshi's
# supervisor-EMULATED sock_connect#47 / sock_close#50 establish + tear down a REAL TCP
# connection to a local server, and the --net-allow egress policy is enforced end-to-end:
#   (1) an allowed dst connects (agnos conn_id >= 0);
#   (2) an un-allowed dst is DENIED before a socket exists (agnos -1);
#   (3) with no --net the band is ENOSYS (agnos -1).
# Runs under the DEFAULT seccomp bound (the realistic path): ptrace rewrites #47 -> the -1
# skip sentinel BEFORE seccomp, and the supervisor's own socket()/connect() are unfiltered,
# so no allowlist change is needed (ADR 0004). Needs python3 + the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
command -v python3 >/dev/null || { echo "SKIP: net_client — python3 not available"; exit 0; }
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"
srv=""
trap 'if [ -n "$srv" ]; then kill "$srv" 2>/dev/null || true; fi; rm -rf "$sbox"' EXIT
fail=0

# a free loopback port (for the server) + a second free-then-closed port (no listener)
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
closed_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

# a TCP server on that port: accept connections (close each), signal ready via a file.
python3 - "$port" "$sbox/ready" <<'PY' &
import socket, sys
port = int(sys.argv[1]); ready = sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(8)
open(ready, "w").close()
try:
    while True:
        c, _ = s.accept(); c.close()
except Exception:
    pass
PY
srv=$!
for _ in $(seq 1 50); do [ -f "$sbox/ready" ] && break; sleep 0.1; done
[ -f "$sbox/ready" ] || { echo "FAIL: test server never came up" >&2; exit 1; }

# agnos fixture: connect to 127.0.0.1:$port (kernel-ip4 0x7F000001), close, exit 0; c<0 -> exit 1.
cat > "$sbox/nc.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var c = sys_sock_connect(0x7F000001, $port, 0);
    if (c < 0) { return 1; }
    sys_sock_close(c);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/nc.cyr" "$sbox/nc" >/dev/null 2>&1

# same fixture, but to the closed port (no listener) — exercises the connect-failure path.
sed "s/$port/$closed_port/" "$sbox/nc.cyr" > "$sbox/ncx.cyr"
cyrius build --agnos "$sbox/ncx.cyr" "$sbox/ncx" >/dev/null 2>&1

runrc() { set +e; "$mirshi" "$@" >/dev/null 2>&1; rc=$?; set -e; }

# (1) allowed: --net-allow 127.0.0.1/32 (loopback needs a /8+ allow) -> connect succeeds.
runrc --net-allow "127.0.0.1/32" "$sbox/nc"
if [ "$rc" -eq 0 ]; then echo "OK: connect+close allowed (127.0.0.1/32) -> conn established"
else echo "FAIL: allowed connect -> rc=$rc (want 0)" >&2; fail=1; fi

# (2) egress denied: 10.0.0.0/8 does NOT cover loopback -> connect denied -> agnos -1.
runrc --net-allow "10.0.0.0/8" "$sbox/nc"
if [ "$rc" -eq 1 ]; then echo "OK: egress-denied dst -> agnos -1 (policy enforced)"
else echo "FAIL: denied connect -> rc=$rc (want 1)" >&2; fail=1; fi

# (3) band off (no --net): sock_connect#47 is ENOSYS -> agnos -1.
runrc "$sbox/nc"
if [ "$rc" -eq 1 ]; then echo "OK: no --net -> net band ENOSYS (-1)"
else echo "FAIL: no --net -> rc=$rc (want 1)" >&2; fail=1; fi

# (4) allowed dst but NO listener -> connect refused -> agnos -1 (the SO_ERROR + fd-cleanup path).
runrc --net-allow "127.0.0.1/32" "$sbox/ncx"
if [ "$rc" -eq 1 ]; then echo "OK: connect to closed port -> agnos -1 (connect-failure path)"
else echo "FAIL: closed-port connect -> rc=$rc (want 1)" >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "net_client: FAILED" >&2; exit 1; fi
echo "OK: net_client — TCP connect/close emulated + --net-allow egress enforced"
