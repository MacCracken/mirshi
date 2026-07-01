#!/usr/bin/env bash
# scripts/it/alloc_clean.sh — 0.8.0 gate: the supervisor's per-syscall hot path is
# ALLOCATION-CLEAN (zero heap alloc per translated syscall). mirshi's bump allocator
# never frees, so ANY per-call alloc() manifests as linear RSS growth under a syscall
# storm — the same failure mode as the pre-0.6.0 per-call-timespec leak (docs/adr/0008).
# This gate storms the two dispatch classes NOT already RSS-gated by
# supervisor_hardening.sh (which gates the EMULATE path via an uptime#40 storm):
#
#   (1) EXECUTE pass-through — a time_unix#46 storm (bufferless; getpid#2 became EMULATE in
#       v1.5.0). The dominant hot path: the enter-stop renumber + the 0.8.0 single-register
#       exit stop (PTRACE_PEEKUSER read, no write-back on success). Touches NO staging buffer,
#       so mirshi's RSS must be FLAT — zero heap alloc, ever, per call.
#   (2) fs path-staging — a stat#33 storm on "/". The alloc-heaviest path: stage_at ->
#       _m2_init (the _m2_pathbuf / _m2_linbuf / _m2_agnbuf buffers) + the exit-stop
#       144->48 repack (pvm_read/write into those buffers). They are LAZY-ONCE
#       (allocated on the first call, reused after), so RSS bumps once at startup then
#       stays flat. A regressed per-call alloc on this path grows RSS by megabytes.
#
# Run under --no-seccomp to isolate the translate/dispatch heap from the bounding filter
# (the seccomp skip-sentinel survival is separately gated by supervisor_hardening.sh).
# Same same-uid ptrace requirement as the M0/M1/M2 integration tests (no extra privilege
# on ubuntu-latest; in a container: --cap-add=SYS_PTRACE --security-opt seccomp=unconfined).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0
rss() { awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null || true; }

# Storm an agnos fixture (loop body in $2) under mirshi --no-seccomp and assert mirshi's
# own RSS is FLAT (delta < 1024 kB) between a 1 s and a 6 s sample — i.e. no per-call
# alloc. A real per-call alloc leaks ~MBs over this window (~33k calls/s × the alloc
# size); flat is ~0. The fixture always declares sb[]/p so the same template serves a
# bufferless call (getpid) and a path call (stat) — an unused decl is harmless.
storm_flat() { # name  loop-body
    local name="$1" body="$2"
    cat > "$sbox/$name.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var sb[64];
    var p = "/";
    var i = 0;
    while (i < 100000000) { $body i = i + 1; }
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$sbox/$name.cyr" "$sbox/$name" >/dev/null 2>&1
    "$mirshi" --no-seccomp "$sbox/$name" >/dev/null 2>&1 &
    local mp=$! r1 r2 delta
    sleep 1; r1="$(rss "$mp")"
    sleep 5; r2="$(rss "$mp")"
    kill -9 "$mp" 2>/dev/null || true; wait "$mp" 2>/dev/null || true
    if [ -z "${r1:-}" ] || [ -z "${r2:-}" ]; then
        echo "FAIL: alloc-clean[$name] — could not sample mirshi VmRSS (mirshi exited early?)" >&2; fail=1; return
    fi
    delta=$(( r2 - r1 ))
    if [ "$delta" -gt 1024 ]; then
        echo "FAIL: alloc-clean[$name] — mirshi RSS grew ${delta} kB under the storm (per-syscall alloc regressed; want <1024)" >&2; fail=1
    else
        echo "OK: alloc-clean[$name] — mirshi RSS flat under the storm (delta=${delta} kB)"
    fi
}

storm_flat timestorm   'syscall(46);'                      # EXECUTE pass-through (time_unix#46, bufferless)
storm_flat statstorm   'syscall(33, p, strlen(p), &sb);'   # fs path-staging + exit repack (stat#33)

if [ "$fail" -ne 0 ]; then echo "alloc-clean: FAILED" >&2; exit 1; fi
echo "OK: alloc-clean — supervisor hot path allocates nothing per translated syscall (execute + fs paths)"
