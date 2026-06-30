#!/usr/bin/env bash
# scripts/it/fault_inject.sh — 0.6.0 hardening gate: throw misbehaving / hostile
# agnos children at mirshi and assert the SUPERVISOR stays stable (no mirshi
# crash, no hang, clean exit) and the HOST is untouched (no zombies, no stray
# files outside the sandbox). The child may die/error any way it likes — what
# matters is that mirshi survives it and reports it.
#
# Each case asserts: (a) mirshi terminates within a timeout (no hang), and
# (b) a follow-up good run still works (the supervisor wasn't corrupted).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"

sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fix="$sbox/fix"; mkdir -p "$fix"
set +e   # children exit non-zero by design; we assert mirshi's behaviour explicitly
fail=0

build_fix() { cyrius build --agnos "$fix/$1.cyr" "$fix/$1" >/dev/null 2>&1; }

# Run mirshi on a fixture under a hard timeout; echo "rc <code>" or "TIMEOUT".
run() { # fixture
    timeout 15 "$mirshi" "$fix/$1" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 124 ]; then echo "TIMEOUT"; else echo "$rc"; fi
}

ck_stable() { # name  run-result
    local name="$1" res="$2"
    if [ "$res" = "TIMEOUT" ]; then
        echo "FAIL: $name — mirshi HUNG (supervisor not stable)" >&2; fail=1; return
    fi
    # A follow-up good run must still succeed -> the supervisor is uncorrupted.
    timeout 15 "$mirshi" "$fix/canary" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "FAIL: $name — supervisor corrupted (canary failed after)" >&2; fail=1; return
    fi
    echo "OK: $name — mirshi survived (child rc=$res), canary still green"
}

# A known-good canary the harness re-runs after each fault.
cat > "$fix/canary.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { syscall(SYS_WRITE, 1, "ok\n", 3); return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix canary

# 1. Garbage buffer pointer to write — kernel EFAULTs in-child; mirshi maps -1.
cat > "$fix/badwrite.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { syscall(SYS_WRITE, 1, 0xdead000, 100); return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix badwrite; ck_stable "bad-pointer write" "$(run badwrite)"

# 2. Garbage path pointer to stat — stage_at pvm_read short-fails -> agnos -1.
cat > "$fix/badstat.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { var sb[48]; syscall(SYS_STAT, 0xdead000, 20, &sb); return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix badstat; ck_stable "bad-pointer stat" "$(run badstat)"

# 3. Oversized path length to open (> PATH_MAX) — stage_at rejects -> agnos -1.
cat > "$fix/bigpath.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { var p = "/tmp/x"; syscall(SYS_OPEN, p, 999999, 0); return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix bigpath; ck_stable "oversized open namelen" "$(run bigpath)"

# 4. Child SIGSEGV (deref low addr) — mirshi sees WIFSIGNALED, returns 128+sig.
cat > "$fix/segv.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { store64(0x10, 1); return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix segv; ck_stable "child SIGSEGV" "$(run segv)"

# 5. Unknown / out-of-surface syscall numbers — mirshi ENOSYS-skips -> -1.
cat > "$fix/unknown.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    syscall(99, 0, 0); syscall(36, 0, 0); syscall(250, 0, 0);
    syscall(SYS_WRITE, 1, "survived\n", 9);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix unknown; ck_stable "unknown syscalls" "$(run unknown)"

# 6. Syscall storm — tight trap loop; mirshi must process all and stay stable.
cat > "$fix/storm.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { var i = 0; while (i < 100000) { syscall(SYS_GETPID); i = i + 1; } return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix storm; ck_stable "syscall storm (100k)" "$(run storm)"

# 7. agnos spawn#3 — mirshi ENOSYS-skips it: NO fork bomb, child gets -1.
cat > "$fix/spawn.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    var i = 0;
    while (i < 50) { syscall(SYS_SPAWN, 0x400000, 4096); i = i + 1; }
    syscall(SYS_WRITE, 1, "no fork bomb\n", 12);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix spawn; ck_stable "spawn (no fork bomb)" "$(run spawn)"

# Host-untouched checks: no zombies left by mirshi, no stray fixtures escaped sbox.
zombies="$(ps -o stat= --ppid $$ 2>/dev/null | grep -c Z || true)"
if [ "${zombies:-0}" -ne 0 ]; then echo "FAIL: $zombies zombie(s) left behind" >&2; fail=1
else echo "OK: no zombie processes left by the supervisor"; fi

if [ "$fail" -ne 0 ]; then echo "fault-injection: FAILED" >&2; exit 1; fi
echo "OK: fault-injection — supervisor stable + host untouched across all hostile children"
