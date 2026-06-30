#!/usr/bin/env bash
# scripts/it/groupstop.sh — 0.6.0 hardening: the roadmap's "supervisor signal
# handling — don't die with the child stuck". An external SIGSTOP to the agnos child
# (which CANNOT self-kill — `kill` is not in the seccomp allowlist, so the stop must
# come from outside) surfaces to mirshi as a ptrace GROUP-STOP. The supervisor must
# leave the child runnable: it discriminates the group-stop (PTRACE_GETSIGINFO
# -EINVAL) and resumes with no signal, so the child runs to completion and mirshi
# exits cleanly (no hang).
#
# Scope note (honest): this gates the REQUIREMENT (child not left stuck), not the
# suppress-vs-re-inject implementation detail. On Linux a group-stopped tracee runs
# whether the stop signal is suppressed or blindly re-injected (the kernel discards a
# re-injected stop), so the pre-fix code also passes here — verified. The test still
# earns its keep: it catches a regression that genuinely strands the child (a
# mis-wired PTRACE_LISTEN, a crash in the group-stop path, or a stricter kernel/config).
# The discriminator's CORRECTNESS — PTRACE_GETSIGINFO=0x4202 returning 0 at a
# delivery stop and -EINVAL at a group-stop — is verified by direct instrumentation
# recorded in docs/adr/0007; a behavioral end-to-end test cannot distinguish it on a
# lenient kernel (an early miswiring of the request as 4=POKETEXT shipped green here).
#
# This needs a SAME-UID ptrace child (no extra privilege on ubuntu-latest; in a
# container: --cap-add=SYS_PTRACE --security-opt seccomp=unconfined), like the
# M0/M1/M2 integration tests.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"

sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fix="$sbox/fix"; mkdir -p "$fix"

# A spinner that runs long enough (a getpid#2 loop, ~seconds under ptrace) to be
# caught mid-run and SIGSTOP'd, then prints a sentinel and exits 0.
cat > "$fix/spinner.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    var i = 0;
    while (i < 80000) { syscall(SYS_GETPID); i = i + 1; }   # agnos getpid#2 spin (signal window)
    syscall(SYS_WRITE, 1, "spun\n", 5);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$fix/spinner.cyr" "$fix/spinner" >/dev/null 2>&1

out="$sbox/out"
timeout 30 "$mirshi" "$fix/spinner" >"$out" 2>/dev/null &
mpid=$!

# Wait for the agnos child to appear, then SIGSTOP it from OUTSIDE while it spins.
# Match by exact comm (spinner) host-wide: we cannot scope by parent pid here — the
# `timeout` wrapper sits between $mpid and mirshi, so the spinner is a great-grandchild
# of this script ($mpid -> timeout -> mirshi -> spinner), not a child of $mpid. On the
# configured CI (ephemeral single-job ubuntu-latest) no foreign "spinner" can exist;
# the supervisor's comm is "mirshi", never matched by -x spinner.
child=""
for _ in $(seq 1 300); do
    child="$(pgrep -x spinner 2>/dev/null | head -1 || true)"
    [ -n "$child" ] && break
    sleep 0.02
done
if [ -z "$child" ]; then
    echo "FAIL: groupstop — spinner child never started" >&2
    kill "$mpid" 2>/dev/null || true; wait "$mpid" 2>/dev/null || true; exit 1
fi

# Guard the timing: the child must STILL be running when we stop it, else the
# group-stop path was never exercised and a green result would be a silent false pass
# (child finished before the SIGSTOP landed). Fail loudly so a too-fast runner / too-
# short spin is caught as "window too small", not passed.
if [ ! -d "/proc/$child" ]; then
    echo "FAIL: groupstop — child exited before SIGSTOP (window too small; re-tune the spin)" >&2
    wait "$mpid" 2>/dev/null || true; exit 1
fi

# Fire the external stop, and deliberately send NO SIGCONT. mirshi resumes the
# group-stopped child itself (with no signal), so it continues without one. Omitting
# SIGCONT is what makes the check meaningful: a SIGCONT would end the group-stop on
# its own and let the child finish regardless of the supervisor, masking a regression
# that strands the child. With no SIGCONT, only a supervisor whose loop resumes the
# group-stopped tracee at all (pre- or post-fix — Linux discards a re-injected stop)
# lets it reach the "spun" sentinel; a stranding regression makes `wait` below time out.
kill -STOP "$child" 2>/dev/null || true

# The supervisor must FINISH (not hang). If mirshi wedged, timeout(1) kills it at 30s
# and `wait` reports 124.
if wait "$mpid"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 124 ]; then
    echo "FAIL: groupstop — mirshi HUNG after SIGSTOP (group-stop wedged the supervisor)" >&2; exit 1
fi
if [ "$rc" -ne 0 ]; then
    echo "FAIL: groupstop — mirshi exited $rc after the group-stop (expected 0)" >&2; exit 1
fi
if ! grep -q "spun" "$out"; then
    echo "FAIL: groupstop — child did not run to completion (no 'spun' sentinel)" >&2; exit 1
fi
echo "OK: groupstop — supervisor resumed the child after an external SIGSTOP, ran to completion"
