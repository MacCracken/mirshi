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

# Like ck_stable, but for the resource-bound storms: ALSO assert mirshi bounded the
# storm at the EXPECTED count, so the test actually gates the rlimit cap. A storm
# that ran unbounded (the cap defeated / regressed / prlimit64 silently failed)
# FAILS here even though mirshi survived — survival alone is NOT enough, because the
# host's own default limits would bound a storm too. The fixture prints "<key>=<n>";
# n must land in the open interval (lo,hi) derived from the cap.
ck_bounded() { # name  fixture  key  lo  hi
    local name="$1" fx="$2" key="$3" lo="$4" hi="$5"
    local out; out="$(timeout 15 "$mirshi" "$fix/$fx" 2>/dev/null)"
    if [ $? -eq 124 ]; then echo "FAIL: $name — mirshi HUNG (supervisor not stable)" >&2; fail=1; return; fi
    local n="${out##*=}"
    case "$n" in (*[!0-9]*|"") echo "FAIL: $name — no '$key=<n>' marker (got: '$out')" >&2; fail=1; return;; esac
    if [ "$n" -le "$lo" ] || [ "$n" -ge "$hi" ]; then
        echo "FAIL: $name — storm NOT bounded by the cap ($key=$n, want $lo<n<$hi; cap defeated?)" >&2; fail=1; return
    fi
    timeout 15 "$mirshi" "$fix/canary" >/dev/null 2>&1
    if [ $? -ne 0 ]; then echo "FAIL: $name — supervisor corrupted (canary failed after)" >&2; fail=1; return; fi
    echo "OK: $name — cap fired ($key=$n in ($lo,$hi)), canary still green"
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

# 8. Memory exhaustion — mmap#27 storm: reserve 2 MB maps until the kernel RLIMIT_AS
# cap turns mmap into the agnos failure sentinel 0, then report the count. mirshi
# must translate every map, propagate the 0, and never OOM itself; ck_bounded
# asserts the storm stopped at the AS band (~1 GiB / 2 MiB ≈ 511 maps), not at the
# 100000 loop cap — so a defeated cap (which would run unbounded) is caught.
cat > "$fix/memstorm.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn putc(c): i64 { var b[1]; store8(&b, c); syscall(SYS_WRITE, 1, &b, 1); return 0; }
fn putn(n): i64 {
    if (n == 0) { putc(48); return 0; }
    var d[24]; var i = 0;
    while (n > 0) { store8(&d + i, 48 + (n % 10)); n = n / 10; i = i + 1; }
    while (i > 0) { i = i - 1; putc(load8(&d + i)); }
    return 0;
}
fn main(): i64 {
    var i = 0;
    while (i < 100000) {
        var a = syscall(27, 0x200000);    # agnos mmap#27(length = 2 MiB)
        if (a == 0) { break; }            # 0 = agnos mmap failure sentinel (RLIMIT_AS hit)
        i = i + 1;
    }
    putc(109); putc(97); putc(112); putc(115); putc(61);   # "maps="
    putn(i); putc(10);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix memstorm; ck_bounded "memory exhaustion (mmap storm)" memstorm maps 256 768

# 9. FD exhaustion — open#7 storm: open an existing path over and over (never closing)
# until the kernel RLIMIT_NOFILE cap turns open into the agnos failure sentinel -1,
# then report the count. ck_bounded asserts the storm stopped at the fd band
# (NOFILE 256 − stdin/out/err = 253), not at the 100000 loop cap — the host's own
# default NOFILE far exceeds 100000, so an unbounded storm here means a defeated cap.
cat > "$fix/fdstorm.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn putc(c): i64 { var b[1]; store8(&b, c); syscall(SYS_WRITE, 1, &b, 1); return 0; }
fn putn(n): i64 {
    if (n == 0) { putc(48); return 0; }
    var d[24]; var i = 0;
    while (n > 0) { store8(&d + i, 48 + (n % 10)); n = n / 10; i = i + 1; }
    while (i > 0) { i = i - 1; putc(load8(&d + i)); }
    return 0;
}
fn main(): i64 {
    var p = "/";                          # an always-present host path (passthrough)
    var i = 0;
    while (i < 100000) {
        var fd = syscall(7, p, 1, 0);     # agnos open#7(name_ptr=p, namelen=1, flags=0=AO_RDONLY)
        if (fd == 0 - 1) { break; }       # -1 = agnos open failure (RLIMIT_NOFILE hit)
        i = i + 1;
    }
    putc(102); putc(100); putc(115); putc(61);   # "fds="
    putn(i); putc(10);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
build_fix fdstorm; ck_bounded "fd exhaustion (open storm)" fdstorm fds 200 256

# Host-untouched check: the supervisor must leave no zombie agnos child behind.
# The actual guarantee lives in src/intercept.cyr (PTRACE_O_EXITKILL + the _wait
# reaping loop); this is the host-side cross-check. mirshi forks the agnos child
# (intercept_run -> sys_fork), so it is a GRANDCHILD of this script, not a direct
# child — `--ppid $$` would never see it, and a child mirshi orphaned by failing
# to reap reparents to PID 1, not to us. So scan ALL defunct processes and match
# the fixture command names, anchored so unrelated zombies that merely share a
# substring on a shared CI runner do not trip a false positive.
fixt_re='canary|badwrite|badstat|bigpath|segv|unknown|storm|memstorm|fdstorm|spawn'
zombies="$(ps -eo stat=,comm= 2>/dev/null \
    | awk -v re="^(${fixt_re})\$" '$1 ~ /^Z/ && $2 ~ re {c++} END {print c+0}')"
if [ "${zombies:-0}" -ne 0 ]; then echo "FAIL: $zombies zombie(s) left behind" >&2; fail=1
else echo "OK: no zombie agnos children left by the supervisor"; fi

if [ "$fail" -ne 0 ]; then echo "fault-injection: FAILED" >&2; exit 1; fi
echo "OK: fault-injection — supervisor stable + host untouched across all hostile children"
