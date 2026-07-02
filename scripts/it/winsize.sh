#!/usr/bin/env bash
# scripts/it/winsize.sh — v1.9.0 winsize#60 gate (BITE 1). agnos winsize#60 is EMULATE: mirshi returns the
# CONTROLLING TERMINAL's size packed agnos-style as (cols<<16)|rows, read via TIOCGWINSZ on its own stdio
# (the child inherits it); no tty -> a virtual 80×24 default (a headless container has no framebuffer). This
# gate proves both paths: (1) no-tty stdio -> 80×24; (2) a pty with a set size -> that size (TIOCGWINSZ works).
# The fixture returns 0 iff the unpacked cols×rows match the baked expected values. Needs the same-uid ptrace req.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

# build a fixture that asserts winsize() unpacks to exactly ($1 cols × $2 rows), into $3
mk() {
    cat > "$sbox/ws.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var w = sys_winsize();
    if (w < 0) { return 2; }
    var cols = (w >> 16) & 0xFFFF;
    var rows = w & 0xFFFF;
    if (cols != $1) { return 3; }
    if (rows != $2) { return 4; }
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$sbox/ws.cyr" "$3" >/dev/null 2>&1
}

# (1) no-tty stdio -> the 80×24 virtual default
mk 80 24 "$sbox/ws_def"
set +e; timeout 25 "$mirshi" "$sbox/ws_def" </dev/null >/dev/null 2>&1; rc=$?; set -e
if [ "$rc" -eq 0 ]; then
    echo "OK: winsize#60 no-tty -> 80×24 default"
else
    echo "FAIL: winsize default rc=$rc (2=neg, 3=cols!=80, 4=rows!=24)" >&2; fail=1
fi

# (2) a pty sized to 120×40 -> winsize reports 120×40 (proves TIOCGWINSZ, not just the fallback)
if command -v python3 >/dev/null; then
    mk 120 40 "$sbox/ws_pty"
    set +e
    timeout 25 python3 - "$mirshi" "$sbox/ws_pty" <<'PY'
import os, pty, sys, struct, fcntl, termios
mirshi, fixture = sys.argv[1], sys.argv[2]
mfd, sfd = pty.openpty()
fcntl.ioctl(sfd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))   # rows, cols
pid = os.fork()
if pid == 0:
    os.dup2(sfd, 0); os.dup2(sfd, 1); os.dup2(sfd, 2)
    if sfd > 2:
        os.close(sfd)
    os.close(mfd)
    os.execv(mirshi, [mirshi, fixture])
os.close(sfd)
try:
    while True:
        if not os.read(mfd, 4096):
            break
except OSError:
    pass
_, st = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(st))
PY
    prc=$?; set -e
    if [ "$prc" -eq 0 ]; then
        echo "OK: winsize#60 pty(120×40) -> TIOCGWINSZ reports 120×40"
    else
        echo "FAIL: winsize pty rc=$prc (3=cols!=120, 4=rows!=40)" >&2; fail=1
    fi
else
    echo "SKIP: winsize pty sub-test — python3 not available"
fi

if [ "$fail" -ne 0 ]; then echo "winsize: FAILED" >&2; exit 1; fi
echo "OK: winsize — winsize#60 (v1.9.0 BITE 1)"
