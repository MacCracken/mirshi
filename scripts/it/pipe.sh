#!/usr/bin/env bash
# scripts/it/pipe.sh — v1.7.0 pipe#25 gate (BITE 2). agnos pipe#25 is EXECUTE-in-child: mirshi rewrites
# it to Linux pipe2(scratch, O_CLOEXEC) run IN the child, then at the exit stop widens the two i32 host
# fds into the agnos {u64 read; u64 write} at the caller's fds buffer. The read/write ends are REAL child
# fds, so sys_read/sys_write/sys_close on them ride the existing execute-in-child path. This gate proves
# (1) a pipe round-trips intra-process (write N -> read N, same bytes — the roadmap's "a pipe round-trips")
# and (2) a create/close loop recycles the fds (close frees them; a leak would climb). Needs the same-uid
# ptrace requirement.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

cat > "$sbox/pipe_rt.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    var fds = alloc(16);
    # (1) round-trip: pipe -> write 8 bytes -> read 8 back -> compare (intra-process, write before read
    # so the in-child read never blocks the single-threaded supervisor).
    if (sys_pipe(fds) != 0) { return 2; }
    var rfd = load64(fds);
    var wfd = load64(fds + 8);
    if (rfd < 0) { return 3; }
    if (wfd < 0) { return 4; }
    if (rfd == wfd) { return 5; }                       # the two ends are distinct fds
    var msg = "PIPEDATA";                                # exactly 8 bytes
    var mlen = strlen(msg);
    if (sys_write(wfd, msg, mlen) != mlen) { return 6; }
    var buf = alloc(64);
    if (sys_read(rfd, buf, mlen) != mlen) { return 7; }
    if (load64(buf) != load64(msg)) { return 8; }        # the 8 bytes survived the round-trip
    sys_close(rfd);
    sys_close(wfd);
    # (2) leak check: 100 pipe+close cycles must RECYCLE the fds (close frees them). A leak would make the
    # read fd climb each iteration; a clean close reuses the same fd number every time.
    var k = 0;
    var firstr = 0 - 1;
    while (k < 100) {
        if (sys_pipe(fds) != 0) { return 10; }
        var r2 = load64(fds);
        var w2 = load64(fds + 8);
        if (k == 0) { firstr = r2; }
        if (r2 != firstr) { return 11; }                 # fd not recycled -> leak
        sys_close(r2);
        sys_close(w2);
        k = k + 1;
    }
    # (3) leak-safety: a bad fds_ptr must fail CLEAN — no pipe2 side effect, no fd leak. NULL (0) is
    # unmapped (the agnos ABI requires fds_ptr >= 0x200000), so the enter-stop write-probe rejects it.
    var b = 0;
    while (b < 50) {
        if (sys_pipe(0) != (0 - 1)) { return 20; }       # bad ptr -> agnos -1, no fds created
        b = b + 1;
    }
    if (sys_pipe(fds) != 0) { return 21; }                # a good pipe still works after the bad ones
    if (load64(fds) != firstr) { return 22; }             # ...and reuses the same low fd -> nothing leaked
    sys_close(load64(fds));
    sys_close(load64(fds + 8));
    var ok = "PIPE-OK\n";
    sys_write(1, ok, strlen(ok));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/pipe_rt.cyr" "$sbox/pipe_rt" >/dev/null 2>&1

set +e; out="$(timeout 25 "$mirshi" "$sbox/pipe_rt" 2>/dev/null)"; rc=$?; set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "PIPE-OK"; then
    echo "OK: pipe#25 — intra-process round-trip (write 8 -> read 8, bytes match) + 100x create/close no fd leak"
else
    echo "FAIL: pipe rc=$rc out='$(printf '%s' "$out" | tr '\n' '|')' (2=pipe, 6/7/8=round-trip, 11=fd leak)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "pipe: FAILED" >&2; exit 1; fi
echo "OK: pipe — pipe#25 execute-in-child + 2xi32->2xu64 exit repack (v1.7.0 BITE 2)"
