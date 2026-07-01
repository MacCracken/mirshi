#!/usr/bin/env bash
# scripts/it/spawn.sh — v1.5.0 multi-process spawn#3 gate (BITE 7). An agnos PARENT under mirshi reads
# a child ELF file into memory and sys_spawn#3's it (in-memory ELF -> a new TRACED grandchild via the
# supervisor's fork + memfd + execveat), and BOTH run under one supervisor: the parent prints its
# marker, the spawned child prints its own, and the root exits cleanly. waitpid#4 is not wired yet
# (BITE 8), so the parent YIELDS (a getpid loop — each is a syscall-stop the demux uses to interleave
# the child) rather than blocking on it. Needs the same-uid ptrace requirement as the other gates.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

# the spawned child: write a marker + exit 0.
cat > "$sbox/spawn_child.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    var m = "SPAWN-CHILD-OK\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/spawn_child.cyr" "$sbox/spawn_child" >/dev/null 2>&1

# the parent: read the child ELF into memory, sys_spawn it, print a marker, yield, exit.
cat > "$sbox/spawn_parent.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var path = "$sbox/spawn_child";
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
    var pid = sys_spawn(buf, total);
    if (pid < 0) { return 2; }
    var pm = "SPAWN-PARENT-OK\n";
    sys_write(1, pm, strlen(pm));
    var i = 0;
    while (i < 60) { sys_getpid(); i = i + 1; }      # yield: let the demux service the child
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/spawn_parent.cyr" "$sbox/spawn_parent" >/dev/null 2>&1

set +e; out="$(timeout 25 "$mirshi" "$sbox/spawn_parent" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "SPAWN-PARENT-OK" && printf '%s' "$out" | grep -q "SPAWN-CHILD-OK"; then
    echo "OK: agnos parent spawn#3'd a child ELF — BOTH ran under one supervisor, root exited clean"
else
    echo "FAIL: spawn rc=$rc parent=$(printf '%s' "$out" | grep -c SPAWN-PARENT-OK) child=$(printf '%s' "$out" | grep -c SPAWN-CHILD-OK)" >&2
    printf '  out: %s\n' "$(printf '%s' "$out" | tr '\n' '|')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "spawn: FAILED" >&2; exit 1; fi
echo "OK: spawn — spawn#3 in-memory ELF -> traced grandchild (parent + child both run)"
