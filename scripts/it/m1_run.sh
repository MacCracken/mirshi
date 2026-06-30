#!/usr/bin/env bash
# scripts/it/m1_run.sh — M1 integration test: agnos binaries actually RUN under
# mirshi's real syscall translation (no --selftest-trace, no QEMU).
#
# The pure translation arithmetic is unit-tested under `cyrius test`; this script
# is the end-to-end gate — a live fork+exec+PTRACE_SYSCALL child whose agnos
# syscalls are translated to their Linux peers and executed in the child. It
# proves the M1 acceptance: an agnos hello + a stdin cat run correctly and exit
# codes propagate. Same ptrace requirements as m0_trap.sh (x86_64, same-uid
# child; in a container: --cap-add=SYS_PTRACE --security-opt seccomp=unconfined).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

mkdir -p build/fixtures
cyrius build src/main.cyr build/mirshi
for f in hello cat exit42 heapuser; do
    cyrius build --agnos "tests/fixtures/$f.cyr" "build/fixtures/$f"
done

# Past the build: the fixtures legitimately exit non-zero (exit42 -> 42), and we
# assert rc explicitly, so do NOT let set -e abort on a non-zero child.
set +e

fail=0
check() { # name expected_stdout expected_rc actual_stdout actual_rc
    local name="$1" exp_out="$2" exp_rc="$3" got_out="$4" got_rc="$5"
    if [ "$got_out" = "$exp_out" ] && [ "$got_rc" -eq "$exp_rc" ]; then
        echo "OK: $name"
    else
        echo "FAIL: $name (rc got=$got_rc want=$exp_rc)" >&2
        diff -u <(printf '%s' "$exp_out") <(printf '%s' "$got_out") >&2 || true
        fail=1
    fi
}

# 1. hello — write#1 + exit#0(0). $() strips the trailing newline.
got="$(./build/mirshi build/fixtures/hello)"; rc=$?
check "hello write+exit" "hello, agnos" 0 "$got" "$rc"

# 2. exit42 — non-zero exit-code propagation (agnos exit#0(42) -> rc 42).
./build/mirshi build/fixtures/exit42; rc=$?
check "exit-code propagation" "" 42 "" "$rc"

# 3. cat — read#5 -> write#1 round trip, small multi-line payload.
payload="$(printf 'line one\nline two')"
got="$(printf '%s' "$payload" | ./build/mirshi build/fixtures/cat)"; rc=$?
check "cat small echo" "$payload" 0 "$got" "$rc"

# 4. cat — >256B payload to exercise the read loop + EOF across buffer fills.
big="$(head -c 700 /dev/zero | tr '\0' 'x')"
got="$(printf '%s' "$big" | ./build/mirshi build/fixtures/cat)"; rc=$?
check "cat 700B loop+EOF" "$big" 0 "$got" "$rc"

# 5. heapuser — the M0->M1 mmap regression gate: alloc_init's mmap#27 is really
#    executed in-child, so the heap works and the program does NOT segfault (139).
got="$(./build/mirshi build/fixtures/heapuser)"; rc=$?
check "heapuser mmap (no segfault)" "heap ok" 0 "$got" "$rc"

if [ "$fail" -ne 0 ]; then
    echo "M1 run integration test: FAILED" >&2
    exit 1
fi
echo "OK: M1 run integration test — hello/cat/exit-propagation/heap under real translation"
