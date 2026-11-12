#!/usr/bin/env bash
# scripts/it/churn.sh — 1.12.3 gate: the supervisor stays clean across many short-lived children.
#   (1) a child's host sockets are closed when it dies: 40 children in turn each bind the SAME UDP port
#       and exit — every bind must succeed, which it cannot if an earlier child's socket is still open;
#   (2) records no one can wait for are reaped: 30 rounds of a middle process that spawns a leaf and
#       exits without waiting for it — afterwards a spawn must still succeed (MAX_CHILDREN = 16 slots).
# Uses spawn_path#43 + waitpid#4. Needs python3 (a free port) and the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
command -v python3 >/dev/null || { echo "SKIP: churn — python3 not available"; exit 0; }
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0
uport="$(python3 -c 'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

bld() { cyrius build --agnos "$sbox/$1.cyr" "$sbox/$1" >/dev/null 2>&1 || { echo "FAIL: $1 fixture did not build" >&2; exit 1; }; }

cat > "$sbox/binder.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 { if (sys_udp_bind($uport) < 0) { return 3; } return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
bld binder

cat > "$sbox/leaf.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { syscall(41, 20); return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
bld leaf

cat > "$sbox/mid.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var p = "$sbox/leaf";
    if (sys_spawn_path(p, strlen(p)) < 0) { return 5; }   # spawn a leaf, exit without waiting for it
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
bld mid

cat > "$sbox/churn.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var b = "$sbox/binder";
    var i = 0;
    while (i < 40) {
        var pid = sys_spawn_path(b, strlen(b));
        if (pid < 0) { return 10; }
        if (sys_waitpid(pid) != 0) { return 11; }       # the bind failed: an earlier socket is still open
        i = i + 1;
    }
    var m = "$sbox/mid";
    var j = 0;
    while (j < 30) {
        var mp = sys_spawn_path(m, strlen(m));
        if (mp < 0) { return 20; }                       # the record table filled up with orphans
        if (sys_waitpid(mp) != 0) { return 21; }        # its leaf spawn failed: no slot left
        j = j + 1;
    }
    syscall(41, 200);                                    # let the last leaves finish
    var l = "$sbox/leaf";
    var lp = sys_spawn_path(l, strlen(l));
    if (lp < 0) { return 22; }
    if (sys_waitpid(lp) != 0) { return 23; }
    syscall(1, 1, "CHURN-OK\n", 9);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
bld churn

set +e; out="$(timeout 120 "$mirshi" --net-allow 127.0.0.1/32 "$sbox/churn" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q CHURN-OK; then
    echo "OK: churn — 40 children re-bound one UDP port (sockets closed at death); 30 orphaning rounds left the table usable"
else
    echo "FAIL: churn rc=$rc (10/11 = a dead child's socket stayed open; 20-23 = orphaned records filled the table)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "churn: FAILED" >&2; exit 1; fi
echo "OK: churn — child release + orphan reaping (1.12.3)"
