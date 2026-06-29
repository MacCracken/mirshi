#!/usr/bin/env bash
# scripts/it/m0_trap.sh — M0 integration test: the REAL fork+execve+PTRACE_SYSEMU
# path end-to-end against a live agnos-target child.
#
# The pure decode/format logic is unit-tested hermetically under `cyrius test`
# (tests/mirshi.tcyr). This script proves the one thing a pure-cyrius .tcyr can
# NOT express: that mirshi actually fork+execs an agnos ELF, traps its complete
# syscall stream via ptrace, and logs the expected events in order. That is the
# M0 acceptance gate.
#
# Requirements: x86_64 Linux + ptrace of a same-uid DIRECT child. This works on
# stock GitHub ubuntu-latest with no extra privilege (Yama ptrace_scope=1 permits
# tracing your own descendant; mirshi never attaches to a foreign pid, so no
# CAP_SYS_PTRACE is needed). Inside a locked-down container, run with:
#   docker run --cap-add=SYS_PTRACE --security-opt seccomp=unconfined ...
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

mkdir -p build/fixtures
cyrius build src/main.cyr build/mirshi
cyrius build --agnos tests/fixtures/hi.cyr build/fixtures/hi

# The trapped stream is hermetic by construction: pointer args render as <ptr>
# and the (nondeterministic) pid is never logged, so a plain string compare is
# stable — no sed normalization needed.
got="$(./build/mirshi --selftest-trace build/fixtures/hi)"
want="$(cat tests/fixtures/hi.expected.log)"

if [ "$got" != "$want" ]; then
    echo "FAIL: M0 trapped stream did not match tests/fixtures/hi.expected.log" >&2
    diff -u <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
    exit 1
fi

echo "OK: M0 trap integration test — 3 agnos syscalls trapped + logged in order"
