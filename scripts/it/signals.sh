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
    if (sys_kill(pid, 0) != 0) { return 22; }           # 1.12.3: signal 0 is the kernel's probe -> 0
    if (sys_kill(pid, 64) != (0 - 1)) { return 28; }    # invalid signal number -> -1
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

# ---- (2) sigprocmask#17 — the blocked-mask oldset round-trip (directly observable) ----------
cat > "$sbox/sigmask.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    var m15 = sigset_new(); sigset_add(m15, 15);   # SIGTERM
    var m2 = sigset_new(); sigset_add(m2, 2);       # SIGINT
    var empty = sigset_new();
    var old = sigset_new();
    var cur = sigset_new();
    # SETMASK to {SIGTERM}; oldset must be the initial mask (0)
    if (sys_sigprocmask(2, m15, old) != 0) { return 30; }
    if (load64(old) != 0) { return 31; }
    # BLOCK {SIGINT}; oldset must be {SIGTERM}; current must be {SIGTERM,SIGINT}
    if (sys_sigprocmask(0, m2, old) != 0) { return 32; }
    if (load64(old) != (1 << 15)) { return 33; }
    if (sys_sigprocmask(0, empty, cur) != 0) { return 34; }        # BLOCK empty = no-op, cur = current
    if (load64(cur) != ((1 << 15) | (1 << 2))) { return 35; }
    # UNBLOCK {SIGTERM}; oldset must be {SIGTERM,SIGINT}; current must be {SIGINT}
    if (sys_sigprocmask(1, m15, old) != 0) { return 36; }
    if (load64(old) != ((1 << 15) | (1 << 2))) { return 37; }
    if (sys_sigprocmask(0, empty, cur) != 0) { return 38; }
    if (load64(cur) != (1 << 2)) { return 39; }
    # 1.12.2, the kernel's edges: a NULL set is -1 with nothing changed; how >= 3 stores the set verbatim
    if (sys_sigprocmask(0, 0, cur) != (0 - 1)) { return 40; }
    if (sys_sigprocmask(0, empty, cur) != 0) { return 41; }
    if (load64(cur) != (1 << 2)) { return 42; }                    # unchanged by the refused call
    if (sys_sigprocmask(3, m15, old) != 0) { return 43; }
    if (load64(old) != (1 << 2)) { return 44; }
    if (sys_sigprocmask(0, empty, cur) != 0) { return 45; }
    if (load64(cur) != (1 << 15)) { return 46; }                   # how 3 -> the set, verbatim
    var msg = "SIGMASK-OK\n";
    sys_write(1, msg, strlen(msg));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/sigmask.cyr" "$sbox/sigmask" >/dev/null 2>&1
set +e; out2="$(timeout 20 "$mirshi" "$sbox/sigmask" 2>/dev/null)"; rc2=$?; set -e
if [ "$rc2" -eq 0 ] && printf '%s' "$out2" | grep -q "SIGMASK-OK"; then
    echo "OK: sigprocmask#17 — BLOCK/UNBLOCK/SETMASK + oldset round-trips the previous mask"
else
    echo "FAIL: sigprocmask rc=$rc2 out='$(printf '%s' "$out2")' (30-39 = wrong mask/oldset at that step, 40-42 = NULL set accepted, 43-46 = how 3 not verbatim)" >&2
    fail=1
fi

# ---- (3) signalfd#18 + read#5 delivery — the full kill -> observe chain ----------------------
cat > "$sbox/sigfd.cyr" <<'EOF'
include "lib/syscalls.cyr"
# read the signalfd into an 8-byte buffer pre-filled with 0xFF; returns the read's answer, and the
# record (the low 4 bytes) through `out` — the high 4 must be untouched: the kernel's record is 4 bytes
fn rd(sfd, out): i64 {
    var buf[8];
    store64(&buf, 0 - 1);
    var n = sys_read(sfd, &buf, 8);
    store64(out, load32(&buf) & 0xFFFFFFFF);
    if (n == 4) { if ((load32(&buf + 4) & 0xFFFFFFFF) != 0xFFFFFFFF) { return 99; } }
    return n;
}
fn main(): i64 {
    var m = sigset_new(); sigset_add(m, 10);        # watch SIGUSR1 (10)
    var sfd = sys_signalfd(0 - 1, m, 0);            # new signalfd
    if (sfd < 0) { return 30; }
    var v[8];
    if (rd(sfd, &v) != 0) { return 31; }            # nothing pending -> 0 (the kernel's "nothing yet")
    if (sys_kill(1, 10) != 0) { return 32; }        # kill self (root) with SIGUSR1 -> pending
    if (rd(sfd, &v) != 4) { return 33; }            # deliver: a 4-byte record
    if (load64(&v) != 10) { return 34; }            # ...the raw signal number 10
    if (rd(sfd, &v) != 0) { return 35; }            # bit consumed -> 0 again
    if (sys_kill(1, 15) != 0) { return 36; }        # SIGTERM pending but NOT watched by this signalfd
    if (rd(sfd, &v) != 0) { return 37; }            # ...so not delivered -> 0
    # a FAILED delivery (bad buffer) must NOT consume the pending bit -> the signal is not lost
    if (sys_kill(1, 10) != 0) { return 40; }        # SIGUSR1 pending again
    if (sys_read(sfd, 0, 8) != (0 - 1)) { return 41; }      # NULL buffer -> -1
    var small[8];
    if (sys_read(sfd, &small, 3) != (0 - 1)) { return 44; } # a count below 4 -> -1, nothing consumed
    if (rd(sfd, &v) != 4) { return 42; }            # signal preserved -> now delivered
    if (load64(&v) != 10) { return 43; }
    # the BLOCKED mask is not consulted: a consumer blocks its signals first, and reads exactly those
    var blk = sigset_new(); sigset_add(blk, 10);
    if (sys_sigprocmask(0, blk, 0) != 0) { return 50; }     # SIG_BLOCK SIGUSR1
    if (sys_kill(1, 10) != 0) { return 51; }
    if (rd(sfd, &v) != 4) { return 52; }            # blocked AND watched -> still readable
    if (load64(&v) != 10) { return 53; }
    # every call makes a NEW signalfd (the kernel ignores the fd argument), and close#6 frees the slot
    var s2 = sys_signalfd(sfd, m, 0);
    if (s2 < 0) { return 60; }
    if (s2 == sfd) { return 61; }                   # not an update of the old one
    var s3 = sys_signalfd(0 - 1, m, 0 - 1);         # flags -1 must not free the slot
    if (s3 < 0) { return 62; }
    if (sys_signalfd(0 - 1, m, 0) == s3) { return 63; }
    var k = 0;
    var last = 0 - 1;
    while (k < 8) {                                 # fill the 8-slot table
        var t = sys_signalfd(0 - 1, m, 0);
        if (t >= 0) { last = t; }
        k = k + 1;
    }
    if (sys_signalfd(0 - 1, m, 0) != (0 - 1)) { return 64; }   # full
    if (sys_close(last) != 0) { return 65; }        # close frees the slot...
    if (sys_close(last) != 0) { return 66; }        # ...and a second close is 0, the kernel's close of a free slot
    if (sys_signalfd(0 - 1, m, 0) < 0) { return 67; }          # ...so a new one fits
    var msg = "SIGNALFD-OK\n";
    sys_write(1, msg, strlen(msg));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/sigfd.cyr" "$sbox/sigfd" >/dev/null 2>&1
set +e; out3="$(timeout 20 "$mirshi" "$sbox/sigfd" 2>/dev/null)"; rc3=$?; set -e
if [ "$rc3" -eq 0 ] && printf '%s' "$out3" | grep -q "SIGNALFD-OK"; then
    echo "OK: signalfd#18 + read#5 — the kernel's 4-byte record, 0 when empty, blocked still readable, new fd per call, close frees"
else
    echo "FAIL: signalfd rc=$rc3 out='$(printf '%s' "$out3")' (31/35/37=empty not 0, 33/34/99=record, 44=short count, 52=blocked unreadable, 61=updated in place, 62-63=flags freed the slot, 64-67=close)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "signals: FAILED" >&2; exit 1; fi
echo "OK: signals — kill#16 + pause#14 + sigprocmask#17 + signalfd#18 read delivery (v1.6.0 complete)"
