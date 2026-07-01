#!/usr/bin/env bash
# scripts/it/spawn_storm.sh — v1.5.0 multi-process edge gates (BITE 10, milestone close-out):
#   (1) FORK-STORM BOUND: a parent that spawn#3's without waiting is capped at MAX_CHILDREN=16 total
#       processes (root + 15), so the 16th+ spawn returns agnos -1 — re-closing the ADR 0006 process-
#       storm vector that flipping spawn#3 to EMULATE reopens (the supervisor forks, so the child
#       seccomp bound can't bound process count; the MAX_CHILDREN cap does). No host process leak.
#   (2) GRANDCHILD DEPTH: root -> child -> grandchild, a 3-level process tree under ONE supervisor,
#       proving the FLAT record table needs no special nesting handling (each grandchild is just
#       another record parented to its spawner). Needs the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

read_elf() { # emit the shared "read $1 into buf" prologue with a 1 MB buffer
  cat <<EOF
    var path = "$1";
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
EOF
}

# ---- (1) FORK-STORM BOUND -------------------------------------------------------------------
cat > "$sbox/storm_child.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 { return 0; }
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/storm_child.cyr" "$sbox/storm_child" >/dev/null 2>&1

cat > "$sbox/storm_parent.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
$(read_elf "$sbox/storm_child")
    var ok = 0;
    var hit_cap = 0;
    var i = 0;
    while (i < 25) {                                  # try to over-spawn the 16-slot table
        var pid = sys_spawn(buf, total);
        if (pid < 0) { hit_cap = 1; } else { ok = ok + 1; }
        i = i + 1;
    }
    if (hit_cap != 1) { return 8; }                  # cap NEVER hit -> unbounded fork (bug)
    if (ok != 15) { return 9; }                      # expect exactly MAX_CHILDREN-1 (root takes 1)
    var m = "STORM-CAPPED-OK\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/storm_parent.cyr" "$sbox/storm_parent" >/dev/null 2>&1

set +e; out="$(timeout 30 "$mirshi" "$sbox/storm_parent" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "STORM-CAPPED-OK"; then
    echo "OK: fork-storm bound — 15 spawns succeed, the 16th+ returns agnos -1 (MAX_CHILDREN cap)"
else
    echo "FAIL: storm rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')' (8=uncapped, 9=wrong count)" >&2; fail=1
fi
# no host process leak: after mirshi exits, EXITKILL + init-reap should leave no storm_child alive.
# (pgrep exits 1 when nothing matches — the GOOD case — so guard it against set -e/pipefail.)
sleep 0.5
set +e; leak="$(pgrep -f "$sbox/storm_child" | wc -l | tr -d ' ')"; set -e
if [ "$leak" = "0" ]; then echo "OK: no host process leak after the storm (EXITKILL reaped all)"
else echo "FAIL: $leak orphaned storm_child processes leaked" >&2; fail=1; fi

# ---- (2) GRANDCHILD DEPTH (root -> child -> grandchild) -------------------------------------
cat > "$sbox/gkid.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    var m = "GRANDCHILD-OK\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/gkid.cyr" "$sbox/gkid" >/dev/null 2>&1

cat > "$sbox/kid.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
$(read_elf "$sbox/gkid")
    var pid = sys_spawn(buf, total);                 # the CHILD spawns a GRANDCHILD
    if (pid < 0) { return 2; }
    if (sys_waitpid(pid) != 0) { return 9; }
    var m = "CHILD-OK\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/kid.cyr" "$sbox/kid" >/dev/null 2>&1

cat > "$sbox/depth_parent.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
$(read_elf "$sbox/kid")
    var pid = sys_spawn(buf, total);                 # ROOT spawns the CHILD
    if (pid < 0) { return 2; }
    if (sys_waitpid(pid) != 0) { return 9; }
    var m = "PARENT-OK\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/depth_parent.cyr" "$sbox/depth_parent" >/dev/null 2>&1

set +e; out2="$(timeout 30 "$mirshi" "$sbox/depth_parent" 2>/dev/null)"; rc2=$?; set -e
if [ "$rc2" -eq 0 ] \
   && printf '%s' "$out2" | grep -q "GRANDCHILD-OK" \
   && printf '%s' "$out2" | grep -q "CHILD-OK" \
   && printf '%s' "$out2" | grep -q "PARENT-OK"; then
    echo "OK: grandchild depth — root -> child -> grandchild, 3-level tree under one supervisor"
else
    echo "FAIL: depth rc=$rc2 out='$(printf '%s' "$out2" | tr '\n' '|')'" >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "spawn_storm: FAILED" >&2; exit 1; fi
echo "OK: spawn_storm — MAX_CHILDREN cap + no leak + 3-level process-tree depth"
