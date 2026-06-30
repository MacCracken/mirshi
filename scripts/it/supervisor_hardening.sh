#!/usr/bin/env bash
# scripts/it/supervisor_hardening.sh — 0.6.0 hardening: the SUPERVISOR's own
# robustness against a hung / abusive agnos child. Two checks:
#
#   (1) supervisor-heap bound — a child that loops an emulated timer (uptime_ms#40)
#       must NOT grow mirshi's heap without bound. The dispatcher used to alloc() a
#       16-byte timespec PER emulated-timer call against the never-freeing bump
#       allocator, so a looping child drove mirshi's RSS up by megabytes (a child-
#       driven supervisor-OOM — the supervisor DoS'd by the child it contains). Fixed
#       with a one-time static buffer (docs/adr/0008). With the fix mirshi's RSS is
#       FLAT under the storm; the leak grew it ~MBs over this window. NOTE: uptime_ms#40
#       is an EMULATE/skip call, so this storm also gates that the skip sentinel
#       (orig_rax=-1, nr 0xFFFFFFFF) survives the bounding seccomp filter under the
#       default bound — a broken x32/skip guard SIGSYS-kills the child here.
#
#   (2) hung-child cleanup — when mirshi is terminated while the child is stuck
#       (spinning / blocked), PTRACE_O_EXITKILL must leave NO orphan and NO zombie
#       ("do not die with the child stuck"). A hung child is correct block-mirroring
#       (the supervisor needs no internal watchdog — a watchdog would wrongly kill a
#       legitimately long-running tool); the kernel reaps the child on tracer death.
#
# Same same-uid ptrace requirements as the M0/M1/M2 integration tests (no extra
# privilege on ubuntu-latest; in a container: --cap-add=SYS_PTRACE
# --security-opt seccomp=unconfined).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"

sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fix="$sbox/fix"; mkdir -p "$fix"
fail=0
rss() { awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null || true; }

# --- (1) supervisor-heap bound under an emulated-timer storm -----------------
cat > "$fix/uptimestorm.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { var i = 0; while (i < 100000000) { syscall(40); i = i + 1; } return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/uptimestorm.cyr" "$fix/uptimestorm" >/dev/null 2>&1
"$mirshi" "$fix/uptimestorm" >/dev/null 2>&1 &
mp=$!
sleep 1; r1="$(rss "$mp")"
sleep 6; r2="$(rss "$mp")"
kill -9 "$mp" 2>/dev/null || true; wait "$mp" 2>/dev/null || true
if [ -z "${r1:-}" ] || [ -z "${r2:-}" ]; then
    echo "FAIL: heap-bound — could not sample mirshi VmRSS (mirshi exited early?)" >&2; fail=1
else
    delta=$(( r2 - r1 ))
    # Fixed: ~0 kB (one-time buffer). The pre-fix per-call alloc leaked ~MBs over this
    # window (measured ~2.4 MB / 5s on the dev box). Threshold sized for a normal CI
    # runner with wide margin both ways: flat is flat, a regressed leak is megabytes.
    if [ "$delta" -gt 1024 ]; then
        echo "FAIL: heap-bound — mirshi RSS grew ${delta} kB under an uptime#40 storm (leak regressed; want <1024)" >&2; fail=1
    else
        echo "OK: heap-bound — mirshi RSS flat under an uptime#40 storm (delta=${delta} kB)"
    fi
fi

# --- (2) hung-child cleanup: terminate mirshi mid-hang, assert no orphan/zombie ---
cat > "$fix/spinloop.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { var i = 0; while (i < 1000000000000) { i = i + 1; } return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/spinloop.cyr" "$fix/spinloop" >/dev/null 2>&1
"$mirshi" "$fix/spinloop" >/dev/null 2>&1 &
mp=$!
sleep 1
# mirshi is launched directly here (no `timeout` wrapper), so the agnos child is a
# direct child of $mp — scope the match by parent to avoid any host-wide ambiguity.
child="$(pgrep -x -P "$mp" spinloop | head -1 || true)"
if [ -z "$child" ]; then
    echo "FAIL: hung-cleanup — spinloop child never started" >&2; fail=1
    kill -9 "$mp" 2>/dev/null || true; wait "$mp" 2>/dev/null || true
else
    kill -TERM "$mp" 2>/dev/null || true
    if wait "$mp"; then :; fi   # mirshi dies on SIGTERM (143); EXITKILL reaps the child
    sleep 0.3
    orphan=no; [ -d "/proc/$child" ] && orphan=yes
    zomb="$(ps -eo stat=,comm= 2>/dev/null | awk '$1 ~ /^Z/ && $2=="spinloop"{c++} END{print c+0}')"
    if [ "$orphan" = yes ]; then
        echo "FAIL: hung-cleanup — child orphaned (still alive) after mirshi was terminated" >&2; fail=1
    elif [ "${zomb:-0}" -ne 0 ]; then
        echo "FAIL: hung-cleanup — ${zomb} zombie(s) left after mirshi was terminated" >&2; fail=1
    else
        echo "OK: hung-cleanup — EXITKILL left no orphan, no zombie when mirshi was terminated mid-hang"
    fi
fi

if [ "$fail" -ne 0 ]; then echo "supervisor-hardening: FAILED" >&2; exit 1; fi
echo "OK: supervisor-hardening — heap bounded under emulate-storm + clean cleanup on terminate-mid-hang"
