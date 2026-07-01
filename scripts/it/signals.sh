#!/usr/bin/env bash
# scripts/it/signals.sh — v1.6.0 signal band gate (BITE 1: kill#16 + pause#14). agnos signals are
# supervisor-emulated over the v1.5.0 record table: kill#16 sets a `1<<sig` pending bit on the target
# (self / direct-child scope, pid 0 protected, sig validated); pause#14 is a BOUNDED YIELD (returns 0,
# never wedges the recv poll loop). Delivery (a process OBSERVING a pending signal) needs signalfd#18
# (BITE 3), so this gate proves the kill SCOPE + return codes (both directions) and that pause yields.
# Needs the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

# the child: a child CANNOT kill its parent (root pid 1) — not self, not its own child -> -1; then it
# pause#14-yields a few times (must return, not hang) and exits clean.
cat > "$sbox/sig_child.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    if (sys_kill(1, 15) != (0 - 1)) { return 7; }   # child kills parent (SIGTERM=15) -> denied -1
    var i = 0;
    while (i < 5) { sys_pause(); i = i + 1; }        # bounded-yield pause returns each time
    var m = "SIG-CHILD-OK\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/sig_child.cyr" "$sbox/sig_child" >/dev/null 2>&1

# the parent (root pid 1): spawn the child, then exercise kill scope + validation while it's alive.
cat > "$sbox/sig_parent.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var path = "$sbox/sig_child";
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
    if (sys_kill(pid, 15) != 0) { return 20; }          # kill a DIRECT child (SIGTERM) -> 0
    if (sys_kill(0, 15) != (0 - 1)) { return 21; }      # pid 0 protected -> -1
    if (sys_kill(pid, 0) != (0 - 1)) { return 22; }     # invalid signal number -> -1
    if (sys_kill(99999, 15) != (0 - 1)) { return 23; }  # unknown pid -> -1
    if (sys_kill(1, 15) != 0) { return 24; }            # self (root) -> 0
    if (sys_waitpid(pid) != 0) { return 9; }            # the child asserted its own checks
    var m = "SIG-PARENT-OK\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/sig_parent.cyr" "$sbox/sig_parent" >/dev/null 2>&1

set +e; out="$(timeout 25 "$mirshi" "$sbox/sig_parent" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "SIG-PARENT-OK" && printf '%s' "$out" | grep -q "SIG-CHILD-OK"; then
    echo "OK: kill#16 scope (self/child 0, pid0/badsig/unknown/cross-tree -1) + pause#14 bounded yield"
else
    echo "FAIL: signals rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')' (20-24=kill scope wrong, 7=child killed parent, 9=child assert)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "signals: FAILED" >&2; exit 1; fi
echo "OK: signals — kill#16 scope/validation + pause#14 bounded-yield (BITE 1)"
