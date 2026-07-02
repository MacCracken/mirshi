#!/usr/bin/env bash
# scripts/it/epoll_wait.sh — v1.7.0 epoll_wait#21 keystone gate (BITE 5). The heterogeneous readiness
# engine: one epoll set watching a TIMERFD (supervisor deadline) AND a SIGNALFD (supervisor mask) wakes on
# whichever fires, returning the RAW watched id in the packed 12 B event {u32 mask=EPOLLIN; u64 data}. This
# is the roadmap gate ("an agnos event loop waits on an epoll set + a timerfd"). epoll_wait is a BOUNDED
# YIELD (never a park) — nothing ready returns 0 and the caller re-polls. Part 2 (--net) proves best-effort
# socket-watching: a server epolls its LISTEN socket and wakes on an inbound connection. Same-uid ptrace req.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

# ---- (1) heterogeneous timerfd + signalfd wake (fully correct, no --net) ----------------------
cat > "$sbox/ew.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    var ep = sys_epoll_create();
    if (ep < 0) { return 2; }
    var tfd = sys_timerfd_create(); if (tfd < 0) { return 3; }
    var m = sigset_new(); sigset_add(m, 10);              # watch SIGUSR1 (10)
    var sfd = sys_signalfd(0 - 1, m, 0); if (sfd < 0) { return 4; }
    if (sys_epoll_ctl(ep, 1, tfd) != 0) { return 5; }
    if (sys_epoll_ctl(ep, 1, sfd) != 0) { return 6; }
    var evbuf = alloc(192);                                # up to 16 events x 12 B
    # (A) nothing armed/pending -> epoll_wait returns 0 (bounded yield, non-blocking)
    if (sys_epoll_wait(ep, evbuf, 16) != 0) { return 7; }
    # (B) arm the timerfd (initial=1s, one-shot); poll until epoll reports IT ready, by its raw id
    var val = alloc(24); store64(val + 0, 0); store64(val + 8, 0); store64(val + 16, 1);
    if (sys_timerfd_settime(tfd, 0, val) != 0) { return 8; }
    var iters = 0;
    var gotT = 0;
    while (gotT == 0) {
        var n = sys_epoll_wait(ep, evbuf, 16);
        var i = 0;
        while (i < n) {
            if (load32(evbuf + i * 12) != 1) { return 20; }         # event mask must be EPOLLIN=1
            if (load64(evbuf + i * 12 + 4) == tfd) { gotT = 1; }
            i = i + 1;
        }
        if (gotT == 0) { iters = iters + 1; if (iters > 5000) { return 9; } }   # ~5s ceiling (fires ~1s)
    }
    var tb[8]; sys_read(tfd, &tb, 8);                     # consume (disarms the one-shot)
    # (C) kill self with SIGUSR1 -> epoll reports the SIGNALFD ready (and the timerfd is now quiet)
    if (sys_kill(1, 10) != 0) { return 10; }
    var n2 = sys_epoll_wait(ep, evbuf, 16);
    if (n2 < 1) { return 11; }
    var gotS = 0;
    var j = 0;
    while (j < n2) { if (load64(evbuf + j * 12 + 4) == sfd) { gotS = 1; } j = j + 1; }
    if (gotS == 0) { return 12; }
    var ok = "EPOLLWAIT-OK\n";
    sys_write(1, ok, strlen(ok));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/ew.cyr" "$sbox/ew" >/dev/null 2>&1
set +e; out="$(timeout 40 "$mirshi" "$sbox/ew" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "EPOLLWAIT-OK"; then
    echo "OK: epoll_wait#21 — heterogeneous timerfd + signalfd wake (roadmap gate), EPOLLIN + raw id, bounded yield"
else
    echo "FAIL: epoll_wait rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')' (7=nonzero-when-idle, 9=timer-never-woke, 12=signal-not-woke, 20=bad-mask)" >&2
    fail=1
fi

# ---- (2) best-effort socket-watching: a server epolls its LISTEN socket, wakes on an inbound conn ----
# Needs --net + python3. The server tags the bare listen_id as AGNOS_SOCK_TAG|lid (the watchable socket
# form); since lid is the mirshi conn slot, `tagged & 7 == lid` resolves EXACTLY here (the sequential
# server case where the guest/mirshi slot maps coincide — the best-effort path's correct regime).
if command -v python3 >/dev/null; then
    cat > "$sbox/client.py" <<'PY'
import socket, sys, time
port = int(sys.argv[1]); out = sys.argv[2]
deadline = time.time() + 15; data = b""
while time.time() < deadline:
    try:
        c = socket.create_connection(("127.0.0.1", port), timeout=2)
        c.settimeout(5)
        while True:
            b = c.recv(64)
            if not b: break
            data += b
        c.close(); break
    except OSError:
        time.sleep(0.1)
open(out, "wb").write(data)
PY
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    cat > "$sbox/ews.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var lid = sys_sock_listen($port);
    if (lid < 0) { return 1; }
    var tagged = 0x40000000 | lid;                       # AGNOS_SOCK_TAG | listen_id = the watchable form
    var ep = sys_epoll_create();
    if (ep < 0) { sys_sock_close(lid); return 2; }
    if (sys_epoll_ctl(ep, 1, tagged) != 0) { sys_sock_close(lid); return 3; }
    var evbuf = alloc(192);
    var iters = 0;
    var got = 0;
    while (got == 0) {
        var n = sys_epoll_wait(ep, evbuf, 16);           # bounded-yield ppoll of the listen host fd
        var i = 0;
        while (i < n) { if (load64(evbuf + i * 12 + 4) == tagged) { got = 1; } i = i + 1; }
        if (got == 0) { iters = iters + 1; if (iters > 8000) { sys_sock_close(lid); return 4; } }
    }
    var c = sys_sock_accept(lid);                         # epoll said readable -> the accept must succeed
    if (c < 0) { sys_sock_close(lid); return 5; }
    var resp = "EPOLL-SOCK-OK";
    sys_sock_send(c, resp, strlen(resp));
    sys_sock_close(lid);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$sbox/ews.cyr" "$sbox/ews" >/dev/null 2>&1
    "$mirshi" --net "$sbox/ews" >/dev/null 2>&1 &
    mp=$!
    rm -f "$sbox/got"
    set +e; timeout 25 python3 "$sbox/client.py" "$port" "$sbox/got"; wait "$mp"; src=$?; set -e
    if grep -q "EPOLL-SOCK-OK" "$sbox/got" 2>/dev/null && [ "$src" -eq 0 ]; then
        echo "OK: epoll_wait#21 socket — server epoll-woke on an inbound connection (best-effort, listener case)"
    else
        echo "FAIL: epoll_wait socket — got='$(head -c 40 "$sbox/got" 2>/dev/null)' srv_exit=$src (4=never-woke, 5=accept-failed)" >&2
        fail=1
    fi
else
    echo "SKIP: epoll_wait socket sub-test — python3 not available"
fi

if [ "$fail" -ne 0 ]; then echo "epoll_wait: FAILED" >&2; exit 1; fi
echo "OK: epoll_wait — timerfd+signalfd + best-effort socket readiness (v1.7.0 BITE 5)"
