#!/usr/bin/env bash
# scripts/it/send_dl.sh — 1.12.1 gate for sock_send_dl#109 (agnos 1.57.13): sock_send#48 with a caller
# ceiling, supervisor-EMULATE in the net band. Proves, through the real ptrace path:
#   (1) the kernel's argument order: a LIVE conn answers the cyrius stdlib's support probe #109(c, buf, 0, 0)
#       with 0, a dead or foreign conn with -1 even for len 0; timeout 0 (= #48), > 0 and < 0 all send;
#   (2) the ceiling: against a peer that stops reading, timeout < 0 answers 0 at once and a 250 ms ceiling
#       answers 0 after ~250 ms — not -1, and not after #48's ~8 s window; plain #48 there waits that window
#       and then answers 0, the committed count (1.12.2);
#   (3) the stdlib's OWN write path (POSIX socket adapter: sys_socket/sys_connect/sys_write, whose first
#       write probes #109) delivers its bytes with no `ENOSYS agnos#109` line on stderr.
# Needs python3 + the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
command -v python3 >/dev/null || { echo "SKIP: send_dl — python3 not available"; exit 0; }
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; srv=""
trap 'if [ -n "$srv" ]; then kill "$srv" 2>/dev/null || true; fi; rm -rf "$sbox"' EXIT
fail=0
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

# Connection 1 is read promptly and its bytes are logged; connection 2 is accepted and NEVER read (with a
# tiny receive buffer), so the client's send buffer fills and its sends stall; connection 3 is logged too.
python3 - "$port" "$sbox/ready" "$sbox/got" <<'PY' &
import socket, sys, threading, time
port = int(sys.argv[1]); ready = sys.argv[2]; got = sys.argv[3]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
s.bind(("127.0.0.1", port)); s.listen(8)
open(ready, "w").close()
held = []
def drain(c):
    data = b""
    try:
        while True:
            b = c.recv(65536)
            if not b:
                break
            data += b
    except Exception:
        pass
    with open(got, "ab") as f:
        f.write(data + b"\n")
n = 0
try:
    while True:
        c, _ = s.accept()
        n += 1
        if n == 2:
            held.append(c)          # never read: the client's sends must stall
        else:
            threading.Thread(target=drain, args=(c,), daemon=True).start()
except Exception:
    pass
PY
srv=$!
for _ in $(seq 1 50); do [ -f "$sbox/ready" ] && break; sleep 0.1; done
[ -f "$sbox/ready" ] || { echo "FAIL: test server never came up" >&2; exit 1; }

# ---- (1) + (2): raw #109 against a live, a dead and a stalled conn.
cat > "$sbox/sdl.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var c = sys_sock_connect(0x7F000001, $port, 0);
    if (c < 0) { return 1; }
    var m = "SDL-A";
    if (syscall(109, c, m, 0, 0) != 0) { return 10; }        # the stdlib's support probe: a live conn -> 0
    if (syscall(109, 7, m, 0, 0) != (0 - 1)) { return 11; }  # a dead conn -> -1, even for len 0
    if (syscall(109, c, m, 0 - 5, 0) != 0) { return 12; }    # len <= 0 on a live conn -> 0
    if (syscall(109, c, m, 5, 0) != 5) { return 13; }        # timeout 0 = #48
    if (syscall(109, c, "SDL-B", 5, 1000000) != 5) { return 14; }   # a 1 s ceiling, space available
    if (syscall(109, c, "SDL-C", 5, 0 - 1) != 5) { return 15; }     # no wait, space available
    sys_sock_close(c);
    if (syscall(109, c, m, 5, 0) != (0 - 1)) { return 16; }  # a closed conn -> -1
    # a peer that stops reading: fill the send buffer with no-wait sends until one commits nothing
    var s = sys_sock_connect(0x7F000001, $port, 0);
    if (s < 0) { return 20; }
    var big = alloc(4096);
    # fill until a no-wait send commits nothing, then let loopback settle (segments in flight still land in
    # the peer's queue and free send space) and fill again — stalled only once a send AFTER the settle is 0
    var rounds = 0;
    var stalled = 0;
    while (stalled == 0) {
        var i = 0;
        var go = 1;
        while (go == 1) {
            var r = syscall(109, s, big, 4096, 0 - 1);
            if (r < 0) { return 21; }                         # -1 is a dead conn, never "no space"
            if (r == 0) { go = 0; }
            i = i + 1;
            if (i > 40000) { return 22; }                     # the buffer never filled
        }
        if (i == 1) { if (rounds > 0) { stalled = 1; } }      # nothing went out after a settle: stalled
        rounds = rounds + 1;
        if (rounds > 20) { return 22; }
        if (stalled == 0) { syscall(41, 300); }               # settle
    }
    var t0 = syscall(40);                                      # uptime_ms
    var w = syscall(109, s, big, 4096, 250000);                # a 250 ms ceiling
    var dt = syscall(40) - t0;
    if (w < 0) { return 26; }                                  # -1 is never the ceiling's answer
    if (w != 0) { return 23; }                                 # the ceiling fired with nothing sent -> 0
    if (dt < 200) { return 24; }                               # it really waited...
    if (dt > 3000) { return 25; }                              # ...but not for #48's ~8 s window
    # 1.12.2: plain #48 on the same stalled conn waits its ~8 s window, then answers 0 — not -1
    var t1 = syscall(40);
    var w48 = syscall(48, s, big, 4096);
    var dt48 = syscall(40) - t1;
    if (w48 < 0) { return 27; }                                # -1 is a dead conn only
    if (w48 != 0) { return 28; }
    if (dt48 < 7000) { return 29; }                            # it did wait the window
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/sdl.cyr" "$sbox/sdl" >/dev/null 2>&1 || { echo "FAIL: sdl fixture did not build" >&2; exit 1; }
set +e; timeout 60 "$mirshi" --net-allow "127.0.0.1/32" "$sbox/sdl" >/dev/null 2>"$sbox/sdl.err"; rc=$?; set -e
if [ "$rc" -eq 0 ]; then
    echo "OK: sock_send_dl#109 — probe/len/dead-conn order; timeout 0/>0/<0 send; a 250 ms ceiling answers 0 on time"
else
    echo "FAIL: sock_send_dl raw rc=$rc (see the fixture's return codes)" >&2; fail=1
fi

# ---- (3) the stdlib's own socket write path: no ENOSYS line, and the bytes arrive.
cat > "$sbox/posix.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var fd = sys_socket(2, 1, 0);                              # AF_INET, SOCK_STREAM
    if (fd < 0) { return 1; }
    var sa[16];
    store64(&sa, 0);
    store64(&sa + 8, 0);
    store16(&sa, 2);                                           # sin_family = AF_INET
    store8(&sa + 2, ($port >> 8) & 0xFF);                      # sin_port, network order
    store8(&sa + 3, $port & 0xFF);
    store8(&sa + 4, 127);                                      # 127.0.0.1
    store8(&sa + 7, 1);
    if (sys_connect(fd, &sa, 16) != 0) { return 2; }
    var m = "POSIX-WRITE-OK";
    if (sys_write(fd, m, strlen(m)) != strlen(m)) { return 3; }
    sys_close(fd);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/posix.cyr" "$sbox/posix" >/dev/null 2>&1 || { echo "FAIL: posix fixture did not build" >&2; exit 1; }
set +e; timeout 30 "$mirshi" --net-allow "127.0.0.1/32" "$sbox/posix" >/dev/null 2>"$sbox/posix.err"; rc=$?; set -e
for _ in $(seq 1 30); do grep -q "POSIX-WRITE-OK" "$sbox/got" 2>/dev/null && break; sleep 0.1; done
if [ "$rc" -ne 0 ]; then
    echo "FAIL: stdlib socket write rc=$rc" >&2; fail=1
elif ! grep -q "POSIX-WRITE-OK" "$sbox/got" 2>/dev/null; then
    echo "FAIL: stdlib socket write — the server never got the bytes" >&2; fail=1
elif grep -q "ENOSYS agnos#109" "$sbox/posix.err"; then
    echo "FAIL: the stdlib's #109 probe still reached ENOSYS" >&2; fail=1
else
    echo "OK: stdlib sys_write on a socket — #109 probe answered, bytes delivered, no ENOSYS line"
fi
if grep -q "ENOSYS agnos#109" "$sbox/sdl.err" 2>/dev/null; then
    echo "FAIL: raw #109 reached the ENOSYS path" >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "send_dl: FAILED" >&2; exit 1; fi
echo "OK: send_dl — sock_send_dl#109 (1.12.1)"
