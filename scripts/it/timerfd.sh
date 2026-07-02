#!/usr/bin/env bash
# scripts/it/timerfd.sh — v1.7.0 timerfd band gate (BITE 3). agnos timerfd#22/#23 are supervisor-emulated
# as a stored DEADLINE (no real Linux timerfd fd): timerfd_create#22 hands out an opaque TIMERFD_BASE+slot
# id; timerfd_settime#23 arms it (seconds granularity, CLOCK_MONOTONIC); read#5 on the id delivers the u64
# expiration count once the deadline passes (non-blocking -> agnos -1 until then, the poll-with-pause#14
# idiom). This gate proves: a disarmed read -> -1; a one-shot fires after ~1s with count>=1 then disarms;
# a periodic timer re-arms (two fires); close frees the slot (no leak). Needs the same-uid ptrace req.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

cat > "$sbox/tfd.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    var buf[8];
    # (1) create + a read while disarmed -> -1
    var tfd = sys_timerfd_create();
    if (tfd < 0) { return 2; }
    if (sys_read(tfd, &buf, 8) != (0 - 1)) { return 3; }      # disarmed -> -1
    # (2) one-shot: initial=1s, interval=0. Fires after ~1s (count>=1), then disarms. Val is
    # {u64 interval_sec@0; _@8; u64 initial_sec@16}, 24 B.
    var val = alloc(24);
    store64(val + 0, 0);                                       # interval_sec = 0 (one-shot)
    store64(val + 8, 0);
    store64(val + 16, 1);                                      # initial_sec = 1
    if (sys_timerfd_settime(tfd, 0, val) != 0) { return 4; }
    if (sys_read(tfd, &buf, 8) != (0 - 1)) { return 5; }       # not expired yet -> -1
    var iters = 0;
    var fired = 0;
    while (fired == 0) {
        var n = sys_read(tfd, &buf, 8);
        if (n == 8) { fired = 1; }
        else {
            sys_pause();                                       # bounded 1ms yield; time advances
            iters = iters + 1;
            if (iters > 5000) { return 6; }                    # ~5s ceiling (fires ~1s)
        }
    }
    if (load64(&buf) < 1) { return 7; }                        # expiration count >= 1
    if (sys_read(tfd, &buf, 8) != (0 - 1)) { return 8; }       # one-shot disarmed after delivery -> -1
    # (3) periodic: initial=1s, interval=1s. Two fires prove the re-arm.
    store64(val + 0, 1);                                       # interval_sec = 1
    store64(val + 16, 1);                                      # initial_sec = 1
    if (sys_timerfd_settime(tfd, 0, val) != 0) { return 10; }
    var fires = 0;
    var pit = 0;
    while (fires < 2) {
        var m = sys_read(tfd, &buf, 8);
        if (m == 8) { fires = fires + 1; }
        else {
            sys_pause();
            pit = pit + 1;
            if (pit > 10000) { return 11; }                    # ~10s ceiling (two ~1s fires)
        }
    }
    # (3.5) out-of-contract seconds are rejected BEFORE the *1000/deadline math (no i64 overflow ->
    # wrong timer). A negative sec -> -1, leaving the slot untouched (the periodic timer above survives).
    store64(val + 0, 0);
    store64(val + 16, 0 - 1);                                  # initial_sec = -1 -> reject
    if (sys_timerfd_settime(tfd, 0, val) != (0 - 1)) { return 16; }
    store64(val + 0, 0 - 1);                                   # interval_sec = -1 -> reject
    store64(val + 16, 1);
    if (sys_timerfd_settime(tfd, 0, val) != (0 - 1)) { return 17; }
    # (4) close frees the slot; a create/close loop recycles it (no leak)
    if (sys_close(tfd) != 0) { return 12; }
    var k = 0;
    var firstfd = 0 - 1;
    while (k < 20) {
        var f2 = sys_timerfd_create();
        if (f2 < 0) { return 13; }
        if (k == 0) { firstfd = f2; }
        if (f2 != firstfd) { return 14; }                      # slot recycled -> no leak
        if (sys_close(f2) != 0) { return 15; }
        k = k + 1;
    }
    var ok = "TIMERFD-OK\n";
    sys_write(1, ok, strlen(ok));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/tfd.cyr" "$sbox/tfd" >/dev/null 2>&1

set +e; out="$(timeout 40 "$mirshi" "$sbox/tfd" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "TIMERFD-OK"; then
    echo "OK: timerfd#22/#23 — one-shot fires ~1s (count>=1, then disarms) + periodic re-arms + close no leak"
else
    echo "FAIL: timerfd rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')' (3=disarmed-read, 6=never fired, 8=not-disarmed, 11=no-rearm, 14=leak)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "timerfd: FAILED" >&2; exit 1; fi
echo "OK: timerfd — timerfd#22/#23 + read#5 expiration delivery (v1.7.0 BITE 3)"
