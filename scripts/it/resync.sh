#!/usr/bin/env bash
# scripts/it/resync.sh — 1.13.0 gate: the agnos ABI re-sync's cheap band, through the real trace path (raw
# syscall numbers, so no stdlib wrapper answers first). Each call's answers and record layouts are checked
# against the kernel's (agnos aef48206, kernel/core/syscall.cyr):
#   (1) unconfined: klug#36, sched_yield#44, readdir#81 (records, flags, the UTF-8 cut, -1/-2/-4),
#       readdir_at#101 (a batched walk that sees every entry once, the cursor protocol), proclist#99 (with a
#       spawned child alive, then reaped), sched_yield_to#108 (self / child / parent / stranger, from both
#       sides), lstat#102 vs stat#33, statfs#103, mountlist#104, spawn_limits#107, fsync#115 — and no
#       `ENOSYS` line for any of them;
#   (2) under --root: readdir / readdir_at / lstat / stat / statfs resolve inside the root — `..` and an
#       absolute symlink are clamped, an escape symlink lists nothing of the host;
#   (3) --net: sock_peer#106 packs (ip << 16) | port for a caller's live conn and refuses everything else;
#       icmp_echo_ex#100 answers a loopback echo and gives up on an unanswered one within its own timeout
#       (SKIPs where unprivileged ICMP is unavailable).
# Needs python3 for (3) + the same-uid ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; srv=""
trap 'if [ -n "$srv" ]; then kill "$srv" 2>/dev/null || true; fi; rm -rf "$sbox"' EXIT
fail=0

# Fixture helpers shared by every fixture (string compare, copy into a zeroed 512-byte window — readdir
# reads a 256-byte window from its path pointer — and record lookups).
helpers='
fn seq(a, b): i64 {
    var i = 0;
    while (1 == 1) {
        var x = load8(a + i);
        if (x != load8(b + i)) { return 0; }
        if (x == 0) { return 1; }
        i = i + 1;
    }
    return 0;
}
fn fill(p, n, v): i64 { var i = 0; while (i < n) { store8(p + i, v); i = i + 1; } return 0; }
fn cp(dst, src): i64 { fill(dst, 512, 0); var i = 0; while (load8(src + i) != 0) { store8(dst + i, load8(src + i)); i = i + 1; } return i; }
fn rd_find(buf, n, name): i64 {
    var i = 0;
    while (i < n) { if (seq(buf + i * 64, name) == 1) { return load8(buf + i * 64 + 63); } i = i + 1; }
    return 0 - 1;
}
fn pl_find(buf, n, pid): i64 {
    var i = 0;
    while (i < n) { if (load64(buf + i * 64) == pid) { return buf + i * 64; } i = i + 1; }
    return 0;
}
'

# ---- (1) unconfined ------------------------------------------------------------------------------------
d="$sbox/d"; mkdir -p "$d/sub"
: > "$d/a.txt"
ln -s sub "$d/lnk"
x62="$(printf 'x%.0s' $(seq 1 62))"
u61="$(printf 'u%.0s' $(seq 1 61))"
: > "$d/${x62}xxxxxxxx"                              # 70 bytes: cut to 62, RD_CUT
: > "$d/${u61}$(printf '\xc3\xa9')"                  # 61 + a 2-byte character: cut to 61, never mid-character
flag="$sbox/flag"

cat > "$sbox/rsk.cyr" <<EOF
include "lib/syscalls.cyr"
$helpers
fn main(): i64 {
    var st[64];
    var i = 0;
    while (syscall(33, "$flag", strlen("$flag"), &st) != 0) {     # wait until the parent has looked
        syscall(44);
        i = i + 1;
        if (i > 3000000) { return 30; }
    }
    var me = syscall(2);
    if (syscall(108, me) != 0) { return 31; }                     # self
    if (syscall(108, 1) != 0) { return 32; }                      # the live direct parent
    if (syscall(108, 1000) != (0 - 1)) { return 33; }             # a stranger
    var pl[1024];
    var n = syscall(99, &pl, 16);
    if (n != 2) { return 34; }
    var mr = pl_find(&pl, n, me);
    if (mr == 0) { return 35; }
    if (load64(mr + 8) != 2) { return 36; }                       # the caller is "running"
    if (load64(mr + 16) != 1) { return 37; }
    if (seq(mr + 24, "rsk") != 1) { return 38; }
    var p = pl_find(&pl, n, 1);
    if (p == 0) { return 39; }
    var ps = load64(p + 8);
    if (ps != 1) { if (ps != 6) { return 40; } }                  # the parent: ready, or parked in waitpid
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF

cat > "$sbox/rsx.cyr" <<EOF
include "lib/syscalls.cyr"
$helpers
fn main(): i64 {
    var pb[512];
    var rb[2048];
    var st[64];
    var cur[8];
    var kb[64];
    # klug#36 / sched_yield#44 / spawn_limits#107
    if (syscall(36, &kb, 64) != 0) { return 10; }
    if (syscall(36, &kb, 0 - 1) != (0 - 1)) { return 11; }
    if (syscall(44) != 0) { return 12; }
    if (syscall(107, 0, 0) != (0 - 1)) { return 13; }
    if (syscall(107, 512, 100) != (0 - 1)) { return 14; }
    # readdir#81
    cp(&pb, "$d");
    fill(&rb, 2048, 0xFF);
    if (syscall(81, &pb, &rb, 16) != 5) { return 20; }
    if (rd_find(&rb, 5, "a.txt") != 0) { return 21; }
    if (rd_find(&rb, 5, "sub") != 1) { return 22; }                # RD_DIR
    if (rd_find(&rb, 5, "lnk") != 0) { return 23; }                # a symlink is never RD_DIR
    if (rd_find(&rb, 5, "$x62") != 2) { return 24; }               # RD_CUT at 62 bytes
    if (rd_find(&rb, 5, "$u61") != 2) { return 25; }               # RD_CUT before the 2-byte character
    var k = 0;
    while (k < 5) {                                                # every record is zero past its name's NUL
        var rec = &rb + k * 64;
        var j = strlen(rec) + 1;
        while (j < 63) { if (load8(rec + j) != 0) { return 26; } j = j + 1; }
        k = k + 1;
    }
    if (syscall(81, &pb, &rb, 2) != 2) { return 27; }
    if (syscall(81, &pb, &rb, 0) != 0) { return 28; }
    if (syscall(81, &pb, &rb, 0 - 3) != 0) { return 29; }
    if (syscall(81, &pb, &rb, 16777217) != (0 - 1)) { return 30; }
    cp(&pb, "$sbox/nope");
    if (syscall(81, &pb, &rb, 4) != (0 - 2)) { return 31; }
    cp(&pb, "$d/a.txt");
    if (syscall(81, &pb, &rb, 4) != (0 - 4)) { return 32; }
    cp(&pb, "$d/a.txt/x");
    if (syscall(81, &pb, &rb, 4) != (0 - 2)) { return 33; }        # a middle component that is a file
    cp(&pb, "");
    if (syscall(81, &pb, &rb, 4) != (0 - 2)) { return 34; }        # the empty path
    if (syscall(81, &pb, &rb, 0) != 0) { return 35; }              # ...after the max check
    fill(&pb, 300, 120);
    if (syscall(81, &pb, &rb, 4) != (0 - 1)) { return 36; }        # no NUL in the 256-byte window
    if (syscall(81, 16, &rb, 4) != (0 - 1)) { return 37; }         # an unreadable path
    # readdir_at#101: batches of 2 see every entry exactly once, then -1
    cp(&pb, "$d");
    fill(&rb, 2048, 0);
    store64(&cur, 0);
    var total = 0;
    var calls = 0;
    while (load64(&cur) != (0 - 1)) {
        var got = syscall(101, &pb, &rb + total * 64, 2, &cur);
        if (got < 0) { return 40; }
        if (got > 2) { return 41; }
        total = total + got;
        calls = calls + 1;
        if (calls > 8) { return 42; }
    }
    if (total != 5) { return 43; }
    if (rd_find(&rb, 5, "a.txt") != 0) { return 44; }
    if (rd_find(&rb, 5, "sub") != 1) { return 45; }
    if (rd_find(&rb, 5, "lnk") != 0) { return 46; }
    if (rd_find(&rb, 5, "$x62") != 2) { return 47; }
    if (rd_find(&rb, 5, "$u61") != 2) { return 48; }
    if (syscall(101, &pb, &rb, 2, &cur) != 0) { return 49; }       # exhausted: 0, the cursor stays -1
    if (load64(&cur) != (0 - 1)) { return 50; }
    store64(&cur, 0 - 7);
    if (syscall(101, &pb, &rb, 2, &cur) != 0) { return 51; }       # any negative: a no-op
    if (load64(&cur) != (0 - 7)) { return 52; }
    store64(&cur, 0);
    if (syscall(101, &pb, &rb, 16, &cur) != 5) { return 53; }
    if (load64(&cur) != (0 - 1)) { return 54; }
    if (syscall(101, &pb, &rb, 2, 16) != (0 - 1)) { return 55; }   # an unreadable cursor
    store64(&cur, 0);
    if (syscall(101, &pb, &rb, 0, &cur) != 0) { return 56; }
    cp(&pb, "$sbox/nope");
    if (syscall(101, &pb, &rb, 2, &cur) != (0 - 2)) { return 57; }
    store64(&cur, 0 - 1);
    if (syscall(101, &pb, &rb, 2, &cur) != 0) { return 58; }       # the cursor is checked before the path resolves
    # lstat#102 vs stat#33
    var lp = "$d/lnk";
    if (syscall(102, lp, strlen(lp), &st) != 0) { return 60; }
    if ((load64(&st) & 0xF000) != 0xA000) { return 61; }           # the link itself
    if (syscall(33, lp, strlen(lp), &st) != 0) { return 62; }
    if ((load64(&st) & 0xF000) != 0x4000) { return 63; }           # stat follows it to sub/
    var ap = "$d/a.txt";
    if (syscall(102, ap, strlen(ap), &st) != 0) { return 64; }
    if ((load64(&st) & 0xF000) != 0x8000) { return 65; }
    var np = "$sbox/nope";
    if (syscall(102, np, strlen(np), &st) != (0 - 1)) { return 66; }
    if (syscall(102, ap, 0, &st) != (0 - 1)) { return 67; }
    if (syscall(102, ap, strlen(ap), 16) != (0 - 1)) { return 68; }
    # statfs#103
    var sf[64];
    var sp = "$sbox";
    if (syscall(103, sp, strlen(sp), &sf) != 0) { return 70; }
    if (load64(&sf + 0) <= 0) { return 71; }
    if (load64(&sf + 8) <= 0) { return 72; }
    if (load64(&sf + 16) > load64(&sf + 8)) { return 73; }
    if (load64(&sf + 24) > load64(&sf + 8)) { return 74; }
    if (syscall(103, np, strlen(np), &sf) != (0 - 1)) { return 75; }
    if (syscall(103, sp, 0, &sf) != (0 - 1)) { return 76; }
    if (syscall(103, sp, strlen(sp), 16) != (0 - 1)) { return 77; }
    # mountlist#104
    var ml[160];
    fill(&ml, 160, 0xFF);
    if (syscall(104, &ml, 1) != 1) { return 80; }
    if (load64(&ml + 0) != 1) { return 81; }
    if (load64(&ml + 8) != 1) { return 82; }
    if (load8(&ml + 16) != 47) { return 83; }
    var m = 17;
    while (m < 80) { if (load8(&ml + m) != 0) { return 84; } m = m + 1; }
    if (load8(&ml + 80) != 0xFF) { return 85; }                    # exactly one record written
    if (syscall(104, &ml, 0) != (0 - 1)) { return 86; }
    if (syscall(104, &ml, 13421773) != (0 - 1)) { return 87; }
    if (syscall(104, &ml, 2) != 1) { return 88; }
    # fsync#115
    var fp = "$sbox/fs";
    var f = syscall(7, fp, strlen(fp), 0x101);
    if (f < 0) { return 90; }
    syscall(1, f, "data", 4);
    if (syscall(115, f) != 0) { return 91; }
    if (syscall(115, 0 - 1) != (0 - 1)) { return 92; }
    if (syscall(115, 32) != (0 - 1)) { return 93; }
    if (syscall(115, 100) != (0 - 1)) { return 94; }               # ROOTFD's number is outside the table
    if (syscall(115, 31) != (0 - 1)) { return 95; }                # a closed fd
    # proclist#99 + sched_yield_to#108, alone and then with a live child
    var pl[1024];
    if (syscall(99, &pl, 16) != 1) { return 100; }
    if (load64(&pl + 0) != 1) { return 101; }
    if (load64(&pl + 8) != 2) { return 102; }
    if (load64(&pl + 16) != 0) { return 103; }
    if (seq(&pl + 24, "rsx") != 1) { return 104; }
    if (load64(&pl + 56) != 0) { return 105; }
    if (syscall(99, &pl, 0) != (0 - 1)) { return 106; }
    if (syscall(99, &pl, 16777217) != (0 - 1)) { return 107; }
    if (syscall(108, 1) != 0) { return 108; }                      # self
    if (syscall(108, 0) != (0 - 1)) { return 109; }                # the root's parent: none
    var kp = "$sbox/rsk";
    var c = syscall(43, kp, strlen(kp));
    if (c < 2) { return 110; }
    var n = syscall(99, &pl, 16);
    if (n != 2) { return 111; }
    var cr = pl_find(&pl, n, c);
    if (cr == 0) { return 112; }
    if (load64(cr + 8) != 1) { return 113; }
    if (load64(cr + 16) != 1) { return 114; }
    if (seq(cr + 24, "rsk") != 1) { return 115; }
    if (syscall(99, &pl, 1) != 1) { return 116; }                  # max is honored
    if (syscall(108, c) != 0) { return 117; }                      # a live direct child
    if (syscall(108, 12345) != (0 - 1)) { return 118; }
    var g = syscall(7, "$flag", strlen("$flag"), 0x101);
    if (g < 0) { return 119; }
    syscall(6, g);
    var code = syscall(4, c);
    if (code != 0) { return 120 + code; }                          # the child's own checks (30..40)
    if (syscall(99, &pl, 16) != 1) { return 170; }                 # reaped: gone from the list
    if (syscall(108, c) != (0 - 1)) { return 171; }
    syscall(1, 1, "RESYNC-OK\n", 10);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
for fx in rsk rsx; do
    cyrius build --agnos "$sbox/$fx.cyr" "$sbox/$fx" >/dev/null 2>&1 || { echo "FAIL: $fx fixture did not build" >&2; exit 1; }
done
set +e; out="$(timeout 60 "$mirshi" "$sbox/rsx" </dev/null 2>"$sbox/err")"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q RESYNC-OK; then
    echo "OK: unconfined — klug / sched_yield / readdir / readdir_at / proclist / sched_yield_to / lstat / statfs / mountlist / spawn_limits / fsync"
else
    echo "FAIL: unconfined rc=$rc (see the fixture's return codes)" >&2; fail=1
fi
if grep -Eq 'ENOSYS agnos#(36|44|81|99|101|102|103|104|107|108|115) ' "$sbox/err"; then
    echo "FAIL: an ENOSYS line for a 1.13.0 call: $(grep ENOSYS "$sbox/err" | head -3)" >&2; fail=1
else
    echo "OK: no ENOSYS line for any of them"
fi

# ---- (2) under --root -----------------------------------------------------------------------------------
jail="$sbox/jail"; mkdir -p "$jail/sub" "$sbox/hostdir"
: > "$jail/f.txt"; : > "$jail/sub/inner"; : > "$sbox/hostdir/h1"; : > "$sbox/hostdir/h2"
ln -s /sub "$jail/abs"                               # absolute: resolves to the jail's /sub
ln -s "$sbox/hostdir" "$jail/esc"                    # a host path: must resolve inside the jail (nothing there)
cat > "$sbox/rsr.cyr" <<EOF
include "lib/syscalls.cyr"
$helpers
fn main(): i64 {
    var pb[512];
    var rb[2048];
    var st[64];
    var cur[8];
    cp(&pb, "/");
    if (syscall(81, &pb, &rb, 16) != 4) { return 10; }
    if (rd_find(&rb, 4, "f.txt") != 0) { return 11; }
    if (rd_find(&rb, 4, "sub") != 1) { return 12; }
    if (rd_find(&rb, 4, "abs") != 0) { return 13; }
    if (rd_find(&rb, 4, "esc") != 0) { return 14; }
    cp(&pb, "/../../..");
    if (syscall(81, &pb, &rb, 16) != 4) { return 15; }             # .. is clamped at the root
    cp(&pb, "/abs");
    if (syscall(81, &pb, &rb, 16) != 1) { return 16; }             # the absolute link stays in the jail
    if (rd_find(&rb, 1, "inner") != 0) { return 17; }
    cp(&pb, "/esc");
    if (syscall(81, &pb, &rb, 16) != (0 - 2)) { return 18; }       # the host directory is not reachable
    cp(&pb, "sub");
    if (syscall(81, &pb, &rb, 16) != 1) { return 19; }             # relative, from the root
    cp(&pb, "/f.txt");
    if (syscall(81, &pb, &rb, 16) != (0 - 4)) { return 20; }
    cp(&pb, "/");
    store64(&cur, 0);
    var total = 0;
    var calls = 0;
    while (load64(&cur) != (0 - 1)) {
        var got = syscall(101, &pb, &rb + total * 64, 1, &cur);
        if (got < 0) { return 21; }
        total = total + got;
        calls = calls + 1;
        if (calls > 8) { return 22; }
    }
    if (total != 4) { return 23; }
    if (rd_find(&rb, 4, "sub") != 1) { return 24; }
    if (rd_find(&rb, 4, "esc") != 0) { return 25; }
    if (syscall(102, "/abs", 4, &st) != 0) { return 30; }
    if ((load64(&st) & 0xF000) != 0xA000) { return 31; }
    if (syscall(33, "/abs", 4, &st) != 0) { return 32; }
    if ((load64(&st) & 0xF000) != 0x4000) { return 33; }
    if (syscall(102, "/esc", 4, &st) != 0) { return 34; }           # the link itself is in the jail
    if (syscall(33, "/esc", 4, &st) != (0 - 1)) { return 35; }      # its target is not
    if (syscall(102, "/nope", 5, &st) != (0 - 1)) { return 36; }
    var sf[64];
    if (syscall(103, "/", 1, &sf) != 0) { return 40; }
    if (load64(&sf) <= 0) { return 41; }
    if (syscall(103, "/sub/inner", 10, &sf) != 0) { return 42; }
    if (syscall(103, "/esc/h1", 7, &sf) != (0 - 1)) { return 43; }
    var pl[256];
    if (syscall(99, &pl, 4) != 1) { return 50; }
    if (seq(&pl + 24, "rsr") != 1) { return 51; }
    var ml[80];
    if (syscall(104, &ml, 1) != 1) { return 52; }
    var f = syscall(7, "/f.txt", 6, 1);
    if (f < 0) { return 53; }
    if (syscall(115, f) != 0) { return 54; }
    syscall(1, 1, "RESYNC-ROOT-OK\n", 15);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/rsr.cyr" "$sbox/rsr" >/dev/null 2>&1 || { echo "FAIL: rsr fixture did not build" >&2; exit 1; }
set +e; out="$(timeout 30 "$mirshi" --root "$jail" "$sbox/rsr" </dev/null 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q RESYNC-ROOT-OK; then
    echo "OK: --root — readdir / readdir_at / lstat / stat / statfs resolve inside the root (.. and links clamped)"
else
    echo "FAIL: --root rc=$rc (see the fixture's return codes)" >&2; fail=1
fi

# ---- (3) --net: sock_peer#106 + icmp_echo_ex#100 ----------------------------------------------------------
if command -v python3 >/dev/null; then
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    lport="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    python3 - "$port" "$sbox/ready" <<'PY' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(4)
open(sys.argv[2], "w").close()
held = []
while True:
    c, _ = s.accept(); held.append(c)
PY
    srv=$!
    for _ in $(seq 1 50); do [ -f "$sbox/ready" ] && break; sleep 0.1; done
    cat > "$sbox/rsn.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var c = sys_sock_connect(0x7F000001, $port, 0);
    if (c < 0) { return 1; }
    var p = syscall(106, c);
    if (p != ((0x7F000001 << 16) | $port)) { return 10; }
    if (syscall(106, 7) != (0 - 1)) { return 11; }                 # a free slot
    if (syscall(106, 8) != (0 - 1)) { return 12; }                 # out of range
    if (syscall(106, 0 - 1) != (0 - 1)) { return 13; }
    var l = syscall(56, $lport);
    if (l < 0) { return 14; }
    if (syscall(106, l) != (0 - 1)) { return 15; }                 # a listener has no peer
    sys_sock_close(c);
    if (syscall(106, c) != (0 - 1)) { return 16; }                 # a closed conn
    syscall(1, 1, "RESYNC-NET-OK\n", 14);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$sbox/rsn.cyr" "$sbox/rsn" >/dev/null 2>&1 || { echo "FAIL: rsn fixture did not build" >&2; exit 1; }
    set +e; out="$(timeout 30 "$mirshi" --net-allow "127.0.0.1/32" "$sbox/rsn" </dev/null 2>/dev/null)"; rc=$?; set -e
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q RESYNC-NET-OK; then
        echo "OK: sock_peer — (ip << 16) | port for a live conn; -1 for free / out-of-range / listener / closed"
    else
        echo "FAIL: sock_peer rc=$rc (see the fixture's return codes)" >&2; fail=1
    fi

    if python3 -c 'import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP).close()' 2>/dev/null; then
        cat > "$sbox/rsi.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    if (syscall(100, 0x7F000001, 0) < 0) { return 10; }            # 0 = the default timeout
    if (syscall(100, 0x7F000001, 1000) < 0) { return 11; }
    var t0 = syscall(40);
    var rr = syscall(100, 0xC0000201, 300);                        # 192.0.2.1 (TEST-NET-1): no reply
    var dt = syscall(40) - t0;
    if (rr != (0 - 1)) { return 12; }
    if (dt > 2000) { return 13; }                                  # its own 300 ms, not #55's 3 s
    if (syscall(100, 0x08080808, 100) != (0 - 1)) { return 14; }   # egress-denied
    syscall(1, 1, "RESYNC-ICMP-OK\n", 15);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
        cyrius build --agnos "$sbox/rsi.cyr" "$sbox/rsi" >/dev/null 2>&1 || { echo "FAIL: rsi fixture did not build" >&2; exit 1; }
        set +e; out="$(timeout 30 "$mirshi" --net-allow "127.0.0.1/32,192.0.2.1/32" "$sbox/rsi" </dev/null 2>/dev/null)"; rc=$?; set -e
        if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q RESYNC-ICMP-OK; then
            echo "OK: icmp_echo_ex — loopback RTT >= 0; an unanswered echo gives up within its own timeout; egress-denied -1"
        else
            echo "FAIL: icmp_echo_ex rc=$rc (see the fixture's return codes)" >&2; fail=1
        fi
    else
        echo "SKIP: icmp_echo_ex — unprivileged ICMP socket unavailable (ping_group_range / sandbox)"
    fi
else
    echo "SKIP: sock_peer / icmp_echo_ex — python3 not available"
fi

if [ "$fail" -ne 0 ]; then echo "resync: FAILED" >&2; exit 1; fi
echo "OK: resync (1.13.0)"
