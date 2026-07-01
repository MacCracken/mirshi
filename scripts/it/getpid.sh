#!/usr/bin/env bash
# scripts/it/getpid.sh — v1.5.0 getpid#2 gate (BITE 9). getpid#2 is now EMULATE, returning the
# CALLER's coined agnos pid (not the host getpid#39): the ROOT sees 1, and a spawn#3 child sees its
# own coined pid (2 for the first spawn) — proving the per-child pid model is coherent (each process
# sees ITS agnos pid, matching what spawn returns to the parent). Needs the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

# the spawned child: its getpid must be 2 (first coined child pid); marker + exit 0 on match.
cat > "$sbox/gp_child.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    if (sys_getpid() != 2) { return 7; }        # child's coined agnos pid
    var m = "CHILD-PID-2-OK\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/gp_child.cyr" "$sbox/gp_child" >/dev/null 2>&1

# the parent (root): its getpid must be 1; spawn the child + waitpid it (must exit 0).
cat > "$sbox/gp_parent.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    if (sys_getpid() != 1) { return 8; }        # the root's coined agnos pid
    var path = "$sbox/gp_child";
    var fd = sys_open(path, strlen(path), 0);
    if (fd < 0) { return 3; }
    var buf = alloc(1048576);
    var total = 0;
    var rgo = 1;
    while (rgo == 1) {
        var n = sys_read(fd, buf + total, 1048576 - total);
        if (n <= 0) { rgo = 0; } else { total = total + n; }
    }
    sys_close(fd);
    if (total <= 0) { return 4; }
    var pid = sys_spawn(buf, total);
    if (pid < 0) { return 2; }
    var code = sys_waitpid(pid);
    if (code != 0) { return 9; }                 # child asserted its own pid==2 (else 7)
    var m = "PARENT-PID-1-OK\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/gp_parent.cyr" "$sbox/gp_parent" >/dev/null 2>&1

set +e; out="$(timeout 25 "$mirshi" "$sbox/gp_parent" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "PARENT-PID-1-OK" && printf '%s' "$out" | grep -q "CHILD-PID-2-OK"; then
    echo "OK: getpid#2 EMULATE — root sees agnos pid 1, spawned child sees its own coined pid 2"
else
    echo "FAIL: getpid rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')' (8=root!=1, 7/9=child!=2, 2=spawn)" >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "getpid: FAILED" >&2; exit 1; fi
echo "OK: getpid — per-child coined agnos pid (root=1, spawned child=2)"
