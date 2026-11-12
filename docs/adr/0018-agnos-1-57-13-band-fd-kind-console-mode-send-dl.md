# 0018 — The agnos 1.57.13 band: fd_kind, console_mode and sock_send_dl, supervisor-emulated

**Status**: Accepted (v1.12.1 — fd_kind#111 / console_mode#110 / sock_send_dl#109)
**Date**: 2026-11-12

## Context

The agnos 1.57.13 kernel added three numbers, and the cyrius 6.7.11+ agnos stdlib issues all three
(`lib/syscalls_x86_64_agnos.cyr`). Each is built to probe and fall back: an older kernel answers -1, and
the stdlib takes its pre-1.57.13 path. mirshi had no arm for any of them, so at the 6.7.18 pin bump
every one fell to the ENOSYS path. Programs kept running, but each call printed a
`mirshi: ENOSYS agnos#N -> -1` line, and the behaviour was the old kernel's:

- **`sock_send_dl#109(conn, buf, len, timeout_us)`** is `sock_send#48` with a caller ceiling. It is on the
  stdlib's own socket-write path: `_agnos_sock_send_all` probes `#109(conn, buf, 0, 0)` on the first
  write. So every agnos program that writes to a socket printed one stray line, and its sends ignored
  the caller's deadline.
- **`console_mode#110(set, clear)`** controls the console's echo (`CM_NOECHO`), flushes typeahead
  (`CM_FLUSH`), and holds a per-process `CM_NOSERIAL` bit (1.57.18). Under mirshi a password prompt
  echoed.
- **`fd_kind#111(fd)`** returns what an fd is, as an `FdKind`: fstat's file type and isatty in one
  register. Under mirshi, an `isatty` built on it was always false.

The kernel is the reference (`agnos/kernel/core/syscall.cyr`: `console_mode_sys`, `fd_kind_sys`, the #109
arm; `net_tcp.cyr`: `tcp_send_dl`).

## Decision

**All three are supervisor-EMULATE.** `agnos_to_linux_nr` stays -1 for each. The skip (`orig_rax = -1`)
matters more than usual here, because Linux #109/#110/#111 are `setpgid`/`getppid`/`getpgrp`.

**`sock_send_dl#109`** joins the net band (`--net`; without it, ENOSYS like #48). It follows the kernel's
order:
1. The conn is checked first: -1 for a dead or foreign conn, even when `len <= 0`. This is what the
   stdlib's support probe relies on.
2. `len <= 0` returns 0.
3. The buffer is read.

`timeout_us == 0` is routed to `_net_send`, so it is byte-for-byte mirshi's #48. A negative timeout is one
non-blocking attempt. A positive one waits at most `min(timeout_us, 8 s)` (the kernel's D6 window,
`TCP_PROGRESS_US`) for send space. A wait that expires with nothing sent answers **0**, the committed
count, never -1.

**`console_mode#110`** treats the host terminal as the console: the first of mirshi's fds 0/1/2 that is a
tty, as for `winsize#60`. Every child inherits it, and `fd_kind` answers CONSOLE for each of those fds. A
program can read its password from any of them (darshana's `tty_echo_off(fd)` accepts whichever fd
`fd_kind` calls the console), so the console cannot be fd 0 alone. It follows the kernel's model:
- **One global mode cell plus a holder.** The holder is the process that last set a mode bit. The mode
  applies to whoever reads. It is in force only while the holder lives: the trace loop's exit hook
  clears it on every death path, and a liveness check on every call catches a death the hook missed.
- **NOECHO** clears `ECHO | ECHONL` on the tty. Clearing it restores the bits it found.
- **FLUSH** is `tcflush(TCIFLUSH)`, or `TCSETSF` when the same call changes the echo.
- **NOSERIAL** is a cell in the caller's record, reported back in the previous flags. mirshi has no COM1
  mirror, so it changes no output.
- **Unknown bits** answer -1 with nothing changed. This includes `CM_FLUSH` in `clear` and the
  `TTY_SELFTEST` knob bits.
- **With no tty on any of the three fds**, the mode is tracked and reported but nothing changes. With
  stdin piped and stderr on a terminal, the terminal is the console. Its echo is hidden and its
  typeahead flushed, while the pipe is a different file and keeps its bytes.
- **While `kbscan#42` has the tty raw,** the echo bits are left to it.
- **At exit,** mirshi gives back any echo it still hides. This runs after kbscan's restore, because
  kbscan's saved termios is a hidden one when NOECHO came first.
- **mirshi's own death.** NOECHO clears only the echo bits, so ISIG stays on, and a Ctrl-C at a hidden
  prompt sends SIGINT to mirshi as well. Default-action death would skip the exit restore. So the first
  hide installs handlers for HUP/INT/QUIT/TERM: each puts the tty back and re-raises its signal
  (`SA_RESETHAND | SA_NODEFER`), so the parent sees the same death status as before.
  - The handlers never return, so `SA_RESTORER` (which x86_64 requires) points anywhere.
  - They are installed only over SIG_DFL: a signal the parent ignored stays ignored.
  - They are not installed when mirshi is a container's PID 1. There the kernel already ignores
    default-action signals sent to mirshi, and a handler would change that.

**`fd_kind#111`**:
1. fd < 0 → -1.
2. Then mirshi's emulated signalfd/timerfd/epoll ids, by slot: open → 7/9/8, free → -1. These are checked
   before the kernel's 32-entry bound, because under mirshi they are `BASE + slot` ids rather than
   small fds. A socket-tagged id (bit 30) is the stdlib's own handle: -1, as on the kernel.
3. Then fd ≥ 32 → -1.
4. A real fd is duplicated into the supervisor with `pidfd_getfd`, `fstat`'d, asked `TCGETS`, and closed.
   A terminal is `FDK_CONSOLE`; another char device (`/dev/null`) is `FDK_DEVICE`; a closed fd fails
   `pidfd_getfd` → -1.

## Consequences

- **Positive:**
  - Programs built with cyrius 6.7.11+ get the 1.57.13 behaviour under mirshi, with no stray ENOSYS
    lines.
  - A password prompt hides its input on a real terminal and leaves piped input alone.
  - A program killed with echo off leaves the tty echoing, and so does mirshi itself when a HUP, INT,
    QUIT or TERM ends it. Linux termios guarantees neither.
  - `prog | other` sees `FDK_PIPE` on fd 1, the case #111 was added for.
  - TLS and other deadline-bound socket writes keep their deadline instead of #48's 8 s window.
  - None of the three adds a child-seccomp entry; all the work is supervisor-side.
- **Negative / owned:**
  - A FLUSH discards the tty's input at once, even another process's half-typed line; the kernel waits
    for that reader to finish its line.
  - A SIGKILL of mirshi cannot be caught, so it leaves a hidden echo hidden. As PID 1 no handler is
    installed, so a fatal signal there leaves it hidden too.
  - After a job-control stop (Ctrl-Z), the shell may restore its own tty modes. mirshi does not hide
    the echo again on SIGCONT. A Linux password prompt that needs that handles SIGTSTP/SIGCONT itself.
  - ~~A signalfd slot is never freed by `close#6`, so `fd_kind` still answers `FDK_SIGNALFD` for a
    closed signalfd.~~ Fixed in 1.12.2: `close#6` frees the slot, and `fd_kind` then answers -1.
  - `sock_send_dl` sends one chunk of at most 4096 bytes per call, like #48.
  - `fd_kind` applies the kernel's 32-fd bound, so an fd mirshi's rlimit allows above 31 reads as -1. An
    agnos program could never have been given one.
- **Neutral:**
  - `console_mode` and `fd_kind` take no child buffer. `sock_send_dl` reads its payload with the same
    bounded `pvm_read` as #48.
  - Pinned by the `fd-kind` / `console-mode` / `send-dl` unit groups, the decode and coverage tables,
    and two CI gates: `scripts/it/fdkind_console.sh` and `scripts/it/send_dl.sh`.

## Alternatives considered

- **Leave them ENOSYS.** Rejected. Programs work, but every socket writer prints a stray line, and the
  very features the band exists for (hidden passwords, `isatty`, write deadlines) silently regress
  under mirshi.
- **Classify a real fd through `/proc/<pid>/fd/<n>`.** Rejected. `stat` follows the link and works, but
  the tty test would need an `open` of the target, and opening a device can have side effects.
  `pidfd_getfd` duplicates the existing open file with none, and mirshi already uses it for
  `exec_redirect#62`.
- **Execute `console_mode` in the child as `ioctl(TCSETS)`.** Rejected. It needs a staged termios
  buffer and a child-seccomp entry. It also cannot implement the holder rule, because a child cannot
  restore the tty after its own death.
- **Answer any fd mirshi can see, ignoring the 32-entry bound.** Rejected, because mirshi's discipline is
  fidelity to the kernel. The emulated ids are the one exception, since on the kernel they really are
  small fds.
