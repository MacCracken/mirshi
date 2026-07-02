#!/usr/bin/env bash
# scripts/it/epoll.sh — v1.7.0 epoll create/ctl/close gate (BITE 4; epoll_wait#21 lands in BITE 5). agnos
# epoll#19/#20 are supervisor-emulated: epoll_create#19 hands out an opaque EPOLL_BASE+slot id backed by a
# per-child instance slot holding up to 8 watched RAW agnos ids; epoll_ctl#20 (op 1=ADD dedup+8-cap, op
# 2=CLEAR fd-ignored) mutates that watch list; close#6 frees the instance slot. This gate proves the
# create/ctl/close semantics WITHOUT epoll_wait (readiness is BITE 5). Needs the same-uid ptrace req.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

cat > "$sbox/ep.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    # (1) create an epoll instance
    var ep = sys_epoll_create();
    if (ep < 0) { return 2; }
    # (2) ADD 8 distinct watched ids -> OK; the 9th -> -1 (the frozen 8-watch cap). The ids are stored
    # verbatim (BITE 4 doesn't resolve them; that's epoll_wait in BITE 5), so arbitrary ids are fine.
    var i = 0;
    while (i < 8) {
        if (sys_epoll_ctl(ep, 1, 100 + i) != 0) { return 3; }     # op 1 = ADD
        i = i + 1;
    }
    if (sys_epoll_ctl(ep, 1, 200) != (0 - 1)) { return 4; }        # 9th watch -> full -> -1
    # (3) dedup: re-ADD an existing id -> 0, consuming no new slot (still full afterwards)
    if (sys_epoll_ctl(ep, 1, 100) != 0) { return 5; }             # already watched -> 0
    if (sys_epoll_ctl(ep, 1, 201) != (0 - 1)) { return 6; }        # dedup freed nothing -> still full
    # (4) CLEAR (op 2, fd ignored) wipes all watches; then a fresh ADD has room again
    if (sys_epoll_ctl(ep, 2, 0) != 0) { return 7; }
    if (sys_epoll_ctl(ep, 1, 300) != 0) { return 8; }             # room again -> 0
    # (5) unknown op -> -1; (6) bad epfd -> -1
    if (sys_epoll_ctl(ep, 9, 1) != (0 - 1)) { return 9; }
    if (sys_epoll_ctl(999, 1, 1) != (0 - 1)) { return 10; }        # 999 is not an epoll id
    # (7) instance cap: EPOLL_SLOTS=4. We hold 1 (ep); 3 more -> OK; the 5th -> -1.
    var e2 = sys_epoll_create(); if (e2 < 0) { return 11; }
    var e3 = sys_epoll_create(); if (e3 < 0) { return 12; }
    var e4 = sys_epoll_create(); if (e4 < 0) { return 13; }
    if (sys_epoll_create() >= 0) { return 14; }                    # 5th instance -> full -> -1
    # (8) close frees an instance slot -> a new create succeeds (slot recycled, no leak)
    if (sys_close(e2) != 0) { return 15; }
    var e5 = sys_epoll_create(); if (e5 < 0) { return 16; }
    var ok = "EPOLL-OK\n";
    sys_write(1, ok, strlen(ok));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/ep.cyr" "$sbox/ep" >/dev/null 2>&1

set +e; out="$(timeout 25 "$mirshi" "$sbox/ep" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "EPOLL-OK"; then
    echo "OK: epoll#19/#20 — create + ADD(dedup,8-cap) + CLEAR + bad-op/epfd -1 + instance cap + close recycle"
else
    echo "FAIL: epoll rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')' (4=8-cap, 6=dedup, 8=clear, 14=inst-cap, 16=close-recycle)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "epoll: FAILED" >&2; exit 1; fi
echo "OK: epoll — epoll_create#19 + epoll_ctl#20 + close#6 divert (v1.7.0 BITE 4)"
