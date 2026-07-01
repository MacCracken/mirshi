#!/usr/bin/env bash
# scripts/it/waitpid.sh — v1.5.0 multi-process waitpid#4 gate (BITE 8, the MILESTONE completion). An
# agnos parent under mirshi sys_spawn#3's a child that exits 42 and sys_waitpid#4's it, receiving the
# child's EXACT exit code — exercising BOTH paths:
#   A) park+wake: spawn then immediately waitpid (child still running) -> the parent is PARKED (left
#      stopped, NOT blocking the supervisor), the child runs to exit, then the parent wakes with 42.
#   B) zombie fast-path: spawn, yield until the child has exited, then waitpid -> claim the retained
#      code (42) directly. Path A is the deterministic parent-waits-for-child flow (no yield hack).
# Needs the same-uid ptrace requirement as the other gates.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

# the spawned child: exit with code 42 (no output — the test checks the waitpid RETURN).
cat > "$sbox/wait_child.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { return 42; }
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/wait_child.cyr" "$sbox/wait_child" >/dev/null 2>&1

# the parent: spawn+waitpid twice (park+wake, then zombie fast-path); both must return 42.
cat > "$sbox/wait_parent.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var path = "$sbox/wait_child";
    var fd = sys_open(path, strlen(path), 0);       # AO_RDONLY
    if (fd < 0) { return 3; }
    var buf = alloc(1048576);
    if (buf == 0) { sys_close(fd); return 5; }
    var total = 0;
    var rgo = 1;
    while (rgo == 1) {
        var n = sys_read(fd, buf + total, 1048576 - total);
        if (n <= 0) { rgo = 0; } else { total = total + n; }
    }
    sys_close(fd);
    if (total <= 0) { return 4; }

    # A) park+wake: spawn, then immediately waitpid while the child is still running.
    var pidA = sys_spawn(buf, total);
    if (pidA < 0) { return 2; }
    var codeA = sys_waitpid(pidA);
    if (codeA != 42) { return 60; }                 # wrong code from the park+wake path

    # B) zombie fast-path: spawn, yield until the child exits, then waitpid.
    var pidB = sys_spawn(buf, total);
    if (pidB < 0) { return 6; }
    var i = 0;
    while (i < 60) { sys_getpid(); i = i + 1; }      # let child B run to exit
    var codeB = sys_waitpid(pidB);
    if (codeB != 42) { return 70; }                 # wrong code from the fast path

    # waiting on an unknown / already-reaped pid returns -1
    if (sys_waitpid(pidA) != (0 - 1)) { return 80; }
    # self-wait (agnos pid 1 = the root itself) is a deadlock — must break gracefully to -1, NOT
    # wedge the single-threaded supervisor (a hostile/buggy child can't hang the sandbox deputy).
    if (sys_waitpid(1) != (0 - 1)) { return 90; }

    var m = "WAIT-OK-42-BOTH\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/wait_parent.cyr" "$sbox/wait_parent" >/dev/null 2>&1

set +e; out="$(timeout 25 "$mirshi" "$sbox/wait_parent" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "WAIT-OK-42-BOTH"; then
    echo "OK: agnos parent spawn#3 + waitpid#4 — exact exit code (42) via park+wake AND fast-path"
else
    echo "FAIL: waitpid rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')'" >&2
    echo "  (rc 60=park+wake wrong, 70=fast-path wrong, 80=reaped-pid not -1, 2/6=spawn failed)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "waitpid: FAILED" >&2; exit 1; fi
echo "OK: waitpid — spawn#3 + waitpid#4 exit-code round-trip (park+wake, fast-path, reaped -> -1)"
