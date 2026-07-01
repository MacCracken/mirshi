#!/usr/bin/env bash
# scripts/it/cli.sh — 0.9.0 CLI freeze: pin the frozen command-line contract
# (docs/reference/cli.md). Asserts the misuse/usage behavior + the EXECVE_FAILED exit
# code — the stable CLI surface NOT already covered by the mode-specific ITs (m0_trap.sh
# = --selftest-trace, m1_run.sh = exit-code propagation + the no-root warning, confine.sh
# = --root). Same same-uid ptrace requirement as the other integration tests (assertion 3
# forks a child).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

# Run mirshi capturing stderr (-> $err) + exit code (-> $rc); never aborts the script.
run() { set +e; err="$("$mirshi" "$@" 2>&1 >/dev/null)"; rc=$?; set -e; }

# (1) no args -> usage on stderr + exit 2.
run
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q "usage:"; then
    echo "OK: no-args -> usage + exit 2"
else
    echo "FAIL: no-args -> rc=$rc (want 2) / stderr missing 'usage:'" >&2; fail=1
fi

# (2) --root without a <dir> -> usage + exit 2 (the flag needs an argument).
run --root
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q "usage:"; then
    echo "OK: --root (no dir) -> usage + exit 2"
else
    echo "FAIL: --root no-dir -> rc=$rc (want 2)" >&2; fail=1
fi

# (3) a missing / non-ELF target -> execve fails -> EXECVE_FAILED (127). --no-seccomp so
#     execve itself runs and fails ENOENT (not any filter path).
run --no-seccomp "$sbox/nope-no-such-elf"
if [ "$rc" -eq 127 ]; then
    echo "OK: missing target -> EXECVE_FAILED exit 127"
else
    echo "FAIL: missing target -> rc=$rc (want 127)" >&2; fail=1
fi

# (4) malformed --net-allow -> FAIL-CLOSED usage + exit 2 (never run with a broken egress
#     policy; the v1.1.0 net band, docs/adr/0012). The policy is validated before fork.
run --net-allow "not-a-cidr" "$sbox/x"
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q "malformed"; then
    echo "OK: malformed --net-allow -> fail-closed exit 2"
else
    echo "FAIL: malformed --net-allow -> rc=$rc (want 2) / stderr missing 'malformed'" >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "cli: FAILED" >&2; exit 1; fi
echo "OK: cli — frozen CLI contract (usage on misuse + exit-code map)"
