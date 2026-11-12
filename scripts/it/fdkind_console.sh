#!/usr/bin/env bash
# scripts/it/fdkind_console.sh — 1.12.1 gate for fd_kind#111 + console_mode#110 (agnos 1.57.13), the two
# console-side numbers the cyrius 6.7.11+ agnos stdlib issues. Both are supervisor-EMULATE. Proves, through
# the REAL ptrace path (raw syscall(111/110) so no stdlib shortcut answers first):
#   (1) fd_kind on no-tty stdio: stdin </dev/null -> DEVICE, stdout piped -> PIPE, then stdout to a file ->
#       FILE; a file, a directory, both pipe#25 ends, the three emulated event fds (open -> their kind, closed
#       -> -1), fd < 0, fd >= 32, a closed fd, an unopened signalfd slot and a socket-tagged id -> -1.
#   (2) console_mode with a PIPE on stdin: tracked and reported, but NOECHO|FLUSH discards nothing, so the
#       scripted input still arrives.
#   (3) on a real pty: fd 0 / 1 are CONSOLE; refused bits answer -1; NOECHO|FLUSH drops the typeahead and hides
#       the next line, clearing it shows the next one; the per-process NOSERIAL bit is reported; a SPAWNED
#       holder's mode dies with it (the tty echoes again while the parent still runs); and mirshi gives the
#       echo back at exit when the root dies holding NOECHO.
#   (4) stdin PIPED with stderr on the pty: the pty is still the console, so a line read from fd 2 is hidden,
#       while the piped stdin keeps its bytes.
#   (5) mirshi itself killed by SIGTERM / SIGINT while it hides the echo: it dies of that same signal, and the
#       terminal echoes again.
# Needs the same-uid ptrace requirement; (3)-(5) need python3.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

# ---- (1) fd_kind on no-tty stdio. $1 = the expected kind of fd 1, $2 = the output binary.
mk_fk() {
    cat > "$sbox/fk.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    if (syscall(111, 0 - 1) != (0 - 1)) { return 10; }        # fd < 0
    if (syscall(111, 32) != (0 - 1)) { return 11; }           # fd >= 32: past the kernel's table
    if (syscall(111, 31) != (0 - 1)) { return 12; }           # a closed fd
    if (syscall(111, 0) != 10) { return 13; }                 # stdin </dev/null -> DEVICE (not a tty)
    if (syscall(111, 1) != $1) { return 14; }                 # stdout
    var p = "$sbox/f.txt";
    var f = sys_open(p, strlen(p), 0x102);                    # AO_CREAT | AO_RDWR
    if (f < 0) { return 20; }
    if (syscall(111, f) != 2) { return 21; }                  # FILE
    syscall(6, f);
    if (syscall(111, f) != (0 - 1)) { return 22; }            # closed -> -1
    var d = "$sbox";
    var df = sys_open(d, strlen(d), 0x800);                   # AO_DIRECTORY
    if (df < 0) { return 23; }
    if (syscall(111, df) != 3) { return 24; }                 # DIR
    syscall(6, df);
    var pf[16];
    if (syscall(25, &pf) != 0) { return 30; }                 # pipe#25 -> {u64 read; u64 write}
    if (syscall(111, load64(&pf)) != 4) { return 31; }        # PIPE (read end)
    if (syscall(111, load64(&pf + 8)) != 4) { return 32; }    # PIPE (write end)
    var mask[8];
    store64(&mask, 1 << 15);
    var sfd = syscall(18, 0 - 1, &mask, 0);                   # signalfd#18
    if (sfd < 0) { return 40; }
    if (syscall(111, sfd) != 7) { return 41; }                # SIGNALFD
    var tfd = syscall(22);                                    # timerfd_create#22
    if (syscall(111, tfd) != 9) { return 42; }                # TIMERFD
    var efd = syscall(19);                                    # epoll_create#19
    if (syscall(111, efd) != 8) { return 43; }                # EPOLL
    syscall(6, tfd);
    if (syscall(111, tfd) != (0 - 1)) { return 44; }          # a closed timerfd -> -1
    syscall(6, efd);
    if (syscall(111, efd) != (0 - 1)) { return 45; }          # a closed epoll -> -1
    if (syscall(111, 0x20000005) != (0 - 1)) { return 46; }   # an unopened signalfd slot
    if (syscall(111, 0x40000003) != (0 - 1)) { return 47; }   # a socket-tagged id: the stdlib's handle
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$sbox/fk.cyr" "$2" >/dev/null 2>&1 || { echo "FAIL: fk fixture did not build" >&2; exit 1; }
}

mk_fk 4 "$sbox/fk_pipe"
set +e; "$mirshi" "$sbox/fk_pipe" </dev/null 2>"$sbox/fk.err" | cat >/dev/null; rc=${PIPESTATUS[0]}; set -e
if [ "$rc" -eq 0 ]; then
    echo "OK: fd_kind#111 — DEVICE stdin, PIPE stdout, FILE/DIR/PIPE fds, event fds, every -1 case"
else
    echo "FAIL: fd_kind (stdout piped) rc=$rc (see the fixture's return codes)" >&2; fail=1
fi
if grep -q "ENOSYS agnos#11[01]" "$sbox/fk.err"; then
    echo "FAIL: fd_kind still reached the ENOSYS path: $(grep ENOSYS "$sbox/fk.err" | head -1)" >&2; fail=1
fi

mk_fk 2 "$sbox/fk_file"
set +e; "$mirshi" "$sbox/fk_file" </dev/null >"$sbox/fk.out" 2>/dev/null; rc=$?; set -e
if [ "$rc" -eq 0 ]; then
    echo "OK: fd_kind#111 — stdout redirected to a file -> FILE"
else
    echo "FAIL: fd_kind (stdout to a file) rc=$rc" >&2; fail=1
fi

# ---- (2) console_mode with a pipe on stdin: tracked, reported, nothing discarded.
cat > "$sbox/cmp.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    if (syscall(111, 0) != 4) { return 9; }                   # stdin is a PIPE
    if (syscall(110, 0, 0) != 0) { return 10; }               # no mode yet
    if (syscall(110, 3, 0) != 0) { return 11; }               # NOECHO|FLUSH -> prev 0
    if (syscall(110, 0, 0) != 1) { return 12; }               # tracked
    var buf[64];
    var n = sys_read(0, &buf, 64);
    if (n < 4) { return 13; }                                 # FLUSH must not have eaten the piped input
    if (load8(&buf) != 97) { return 14; }                     # 'a'
    if (syscall(110, 0, 1) != 1) { return 15; }               # clear -> prev 1
    if (syscall(110, 0, 0) != 0) { return 16; }
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/cmp.cyr" "$sbox/cmp" >/dev/null 2>&1 || { echo "FAIL: cmp fixture did not build" >&2; exit 1; }
set +e; printf 'abc\n' | "$mirshi" "$sbox/cmp" >/dev/null 2>&1; rc=${PIPESTATUS[1]}; set -e
if [ "$rc" -eq 0 ]; then
    echo "OK: console_mode#110 — piped stdin: mode tracked + reported, NOECHO|FLUSH discards nothing"
else
    echo "FAIL: console_mode (piped stdin) rc=$rc" >&2; fail=1
fi

# ---- (3) on a real pty.
if ! command -v python3 >/dev/null; then
    echo "SKIP: fd_kind/console_mode pty sub-tests — python3 not available"
else
    # the spawned holder: hide the echo and die holding it
    cat > "$sbox/holder.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    syscall(110, 1, 0);
    var m = "CHILD-HID\n";
    sys_write(1, m, strlen(m));
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$sbox/holder.cyr" "$sbox/holder" >/dev/null 2>&1 || { echo "FAIL: holder fixture did not build" >&2; exit 1; }
    # shared fixture helpers: say on an fd, read one line from an fd, compare a line
    cat > "$sbox/cmlib.cyr" <<'EOF'
fn say(fd, s): i64 { sys_write(fd, s, strlen(s)); return 0; }
# one line from `fd` into buf (no newline, NUL-terminated); returns its length or -1
fn line(fd, buf, cap): i64 {
    var n = 0;
    while (n < cap - 1) {
        var c[8];
        var r = sys_read(fd, &c, 1);
        if (r <= 0) { return 0 - 1; }
        var ch = load8(&c) & 0xFF;
        if (ch == 10) { store8(buf + n, 0); return n; }
        store8(buf + n, ch);
        n = n + 1;
    }
    store8(buf + n, 0);
    return n;
}
# 1 when the NUL-terminated buf holds exactly the NUL-terminated s
fn same(buf, s): i64 {
    var i = 0;
    while (load8(s + i) != 0) {
        if (load8(buf + i) != load8(s + i)) { return 0; }
        i = i + 1;
    }
    if (load8(buf + i) != 0) { return 0; }
    return 1;
}
EOF
    # (3) the main pty run: stdio all on the pty
    cat > "$sbox/cmt.cyr" <<EOF
include "lib/syscalls.cyr"
$(cat "$sbox/cmlib.cyr")
fn main(): i64 {
    if (syscall(111, 0) != 1) { return 50; }                  # a terminal -> CONSOLE
    if (syscall(111, 1) != 1) { return 51; }
    if (syscall(110, 0, 0) != 0) { return 52; }               # no mode yet
    if (syscall(110, 8, 0) != (0 - 1)) { return 53; }         # an unknown bit is refused
    if (syscall(110, 0, 2) != (0 - 1)) { return 54; }         # FLUSH in clear is refused
    if (syscall(110, 0, 0) != 0) { return 55; }               # ...with nothing changed
    # the driver typed "typeahead" before this process existed: NOECHO|FLUSH discards it
    if (syscall(110, 3, 0) != 0) { return 56; }
    if (syscall(110, 0, 0) != 1) { return 57; }
    if (syscall(110, 4, 0) != 1) { return 58; }               # set NOSERIAL; prev = the console's 1
    if (syscall(110, 0, 0) != 5) { return 59; }               # NOECHO | the caller's NOSERIAL
    if (syscall(110, 0, 4) != 5) { return 60; }
    var buf[128];
    say(1, "READY1\n");
    if (line(0, &buf, 128) < 0) { return 61; }
    if (same(&buf, "hunter2") != 1) { return 62; }            # the typeahead was flushed, not read
    say(1, "GOT1\n");
    if (syscall(110, 0, 1) != 1) { return 63; }               # echo back on
    say(1, "READY2\n");
    if (line(0, &buf, 128) < 0) { return 64; }
    say(1, "GOT2\n");
    # a spawned child takes the mode and dies holding it
    var path = "$sbox/holder";
    var fd = sys_open(path, strlen(path), 0);
    if (fd < 0) { return 70; }
    var eb = alloc(1048576);
    var total = 0;
    var go = 1;
    while (go == 1) {
        var n = sys_read(fd, eb + total, 1048576 - total);
        if (n <= 0) { go = 0; } else { total = total + n; }
    }
    sys_close(fd);
    var cp = sys_spawn(eb, total);
    if (cp < 0) { return 71; }
    if (sys_waitpid(cp) != 0) { return 72; }
    # no console_mode call before this line: a query would itself heal the tty (it finds the holder
    # dead), so only the death path can have given the echo back for the driver to see
    say(1, "READY4\n");
    if (line(0, &buf, 128) < 0) { return 74; }
    say(1, "GOT4\n");
    if (syscall(110, 0, 0) != 0) { return 73; }               # the mode died with its holder
    syscall(110, 1, 0);                                       # the root dies holding NOECHO
    say(1, "READY3\n");
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$sbox/cmt.cyr" "$sbox/cmt" >/dev/null 2>&1 || { echo "FAIL: cmt fixture did not build" >&2; exit 1; }
    # (4) stdin PIPED, stdout/stderr on the pty: the pty is still the console (fd_kind says so for fd 2)
    cat > "$sbox/cm2.cyr" <<EOF
include "lib/syscalls.cyr"
$(cat "$sbox/cmlib.cyr")
fn main(): i64 {
    if (syscall(111, 0) != 4) { return 80; }                  # stdin is a PIPE
    if (syscall(111, 2) != 1) { return 81; }                  # stderr is the CONSOLE
    if (syscall(110, 3, 0) != 0) { return 82; }               # hide + flush the console
    var buf[128];
    say(2, "READY5\n");
    if (line(2, &buf, 128) < 0) { return 83; }                # the password comes from the terminal
    if (same(&buf, "hunter3") != 1) { return 84; }
    say(2, "GOT5\n");
    if (line(0, &buf, 128) < 0) { return 85; }                # the piped stdin kept its bytes
    if (same(&buf, "piped") != 1) { return 86; }
    syscall(110, 0, 1);
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$sbox/cm2.cyr" "$sbox/cm2" >/dev/null 2>&1 || { echo "FAIL: cm2 fixture did not build" >&2; exit 1; }
    # (5) mirshi itself killed while it hides the echo
    cat > "$sbox/cmk.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn main(): i64 {
    syscall(110, 1, 0);
    var m = "READY6\n";
    sys_write(1, m, strlen(m));
    var i = 0;
    while (i < 600) { syscall(41, 100); i = i + 1; }          # ~60 s: the driver kills mirshi first
    return 9;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$sbox/cmk.cyr" "$sbox/cmk" >/dev/null 2>&1 || { echo "FAIL: cmk fixture did not build" >&2; exit 1; }
    set +e
    timeout 120 python3 - "$mirshi" "$sbox" <<'PY'
import os, pty, sys, select, signal, termios, time
mirshi, sbox = sys.argv[1], sys.argv[2]
ECHOBITS = termios.ECHO | termios.ECHONL

class Run:
    # mirshi on a fresh pty. stdin is the pty unless `stdin_bytes` is given (then a pipe holding them).
    # The driver KEEPS the slave open: a pts slave's termios is reset when its last fd closes, so the
    # checks read the same live tty mirshi wrote to. `typeahead` is typed before the child exists.
    def __init__(self, fixture, stdin_bytes=None, typeahead=None):
        self.mfd, self.sfd = pty.openpty()
        self.orig = termios.tcgetattr(self.sfd)
        if typeahead:
            os.write(self.mfd, typeahead)
        rp = None
        if stdin_bytes is not None:
            rp, wp = os.pipe()
            os.write(wp, stdin_bytes)
            os.close(wp)
        self.pid = os.fork()
        if self.pid == 0:
            os.dup2(rp if rp is not None else self.sfd, 0)
            os.dup2(self.sfd, 1); os.dup2(self.sfd, 2)
            os.execv(mirshi, [mirshi, fixture])
        if rp is not None:
            os.close(rp)
        self.buf = b""
    def until(self, marker, secs=15):
        end = time.time() + secs
        while marker not in self.buf:
            left = end - time.time()
            if left <= 0:
                fail("timeout waiting for %r; got %r" % (marker, self.buf[-300:]))
            r, _, _ = select.select([self.mfd], [], [], left)
            if r:
                self.buf += os.read(self.mfd, 4096)
        i = self.buf.index(marker) + len(marker)
        seg, self.buf = self.buf[:i], self.buf[i:]
        return seg
    def type(self, b):
        os.write(self.mfd, b)
    def echo_bits(self):
        return termios.tcgetattr(self.sfd)[3] & ECHOBITS
    def orig_bits(self):
        return self.orig[3] & ECHOBITS
    def wait(self):
        _, st = os.waitpid(self.pid, 0)
        return st

def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)

# (3) refusals, FLUSH, hide/show, NOSERIAL, a spawned holder's death, the exit restore
r = Run(sbox + "/cmt", typeahead=b"typeahead\n")
r.until(b"READY1")
r.type(b"hunter2\n")
seg = r.until(b"GOT1")
if b"hunter2" in seg:
    fail("NOECHO line was echoed: %r" % seg)
r.until(b"READY2")
r.type(b"visible42\n")
seg = r.until(b"GOT2")
if b"visible42" not in seg:
    fail("echo did not come back after clearing NOECHO: %r" % seg)
r.until(b"CHILD-HID")
r.until(b"READY4")
r.type(b"afterdeath7\n")
seg = r.until(b"GOT4")
if b"afterdeath7" not in seg:
    fail("the spawned holder died but the tty is still hidden: %r" % seg)
r.until(b"READY3")
st = r.wait()
if os.waitstatus_to_exitcode(st) != 0:
    fail("pty fixture rc=%d (see its return codes); tail %r" % (os.waitstatus_to_exitcode(st), r.buf[-200:]))
if r.echo_bits() != r.orig_bits():
    fail("echo not restored at mirshi exit: lflag %#x" % termios.tcgetattr(r.sfd)[3])
print("OK: console_mode#110 on a pty — refusals, FLUSH, NOECHO hide/show, NOSERIAL, holder death, exit restore")

# (4) stdin piped, the console on stderr
r = Run(sbox + "/cm2", stdin_bytes=b"piped\n")
r.until(b"READY5")
r.type(b"hunter3\n")
seg = r.until(b"GOT5")
if b"hunter3" in seg:
    fail("stdin piped: the console (stderr's tty) still echoed the hidden line: %r" % seg)
st = r.wait()
if os.waitstatus_to_exitcode(st) != 0:
    fail("piped-stdin fixture rc=%d" % os.waitstatus_to_exitcode(st))
print("OK: console_mode#110 — stdin piped: the console is stderr's tty (hidden there), the pipe keeps its bytes")

# (5) mirshi killed while it hides the echo: it dies of that signal, with the echo back
for sig in (signal.SIGTERM, signal.SIGINT):
    r = Run(sbox + "/cmk")
    r.until(b"READY6")
    if r.echo_bits() != 0:
        fail("NOECHO was not applied before the kill (lflag %#x)" % termios.tcgetattr(r.sfd)[3])
    os.kill(r.pid, sig)
    st = r.wait()
    if not os.WIFSIGNALED(st) or os.WTERMSIG(st) != sig:
        fail("mirshi did not die of %s (status %#x)" % (sig.name, st))
    if r.echo_bits() != r.orig_bits():
        fail("mirshi died of %s with the echo still hidden" % sig.name)
print("OK: console_mode#110 — mirshi killed by SIGTERM / SIGINT while hiding: dies of the signal, echo restored")
sys.exit(0)
PY
    prc=$?; set -e
    if [ "$prc" -ne 0 ]; then
        echo "FAIL: fd_kind/console_mode pty sub-tests rc=$prc" >&2; fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then echo "fdkind_console: FAILED" >&2; exit 1; fi
echo "OK: fdkind_console — fd_kind#111 + console_mode#110 (1.12.1)"
