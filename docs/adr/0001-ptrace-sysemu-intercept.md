# 0001 — ptrace(PTRACE_SYSEMU) as the M0 syscall-intercept mechanism

**Status**: Accepted
**Date**: 2026-06-29

## Context

mirshi must intercept every syscall an agnos-compiled child makes and stop the
host kernel from executing it. This is forced, not cosmetic: agnos and Linux
share the *identical* x86_64 register ABI and `syscall`-instruction emit — only
the syscall **numbers** differ. So an un-translated agnos syscall does not fault
cleanly; it silently invokes whatever Linux call owns that number. The two
headline symmetric collisions are agnos `exit#0` → Linux `read#0` (the process
blocks reading into a garbage pointer instead of exiting) and agnos `winsize#60`
→ Linux `exit#60` (the process terminates instead of returning a window size).
Worse cases exist: `sock_accept#57` → Linux `fork#57` (fork bomb),
`sock_listen#56` → Linux `clone#56`, `flock#59` → Linux `execve#59`. Running a
bare agnos binary on Linux confirms it: a `write; exit` fixture prints, then
**segfaults** because `exit#0` ran as `read#0`.

Two facts constrain the mechanism: agnos binaries are **static, no libc**, so
`LD_PRELOAD` cannot hook them — interception must be supervisor-side; and the
host kernel must **never** execute the child's raw foreign number.

The mechanisms available on Linux: `ptrace(PTRACE_SYSCALL)`,
`ptrace(PTRACE_SYSEMU)`, and `seccomp` user-notify (`SECCOMP_RET_USER_NOTIF`).

## Decision

For M0 (interception proven before any translation), mirshi `fork`+`exec`s the
agnos ELF and traps every syscall with **`ptrace(PTRACE_SYSEMU)`** on x86_64
Linux. It reads the trapped registers via `PTRACE_GETREGS` (the agnos number is
`orig_rax`, args `rdi/rsi/rdx/r10`), decodes and logs each event, and executes
and translates **nothing** — with the single necessary exception of agnos
`exit#0`, on which it tears the child down (`SIGKILL` + reap) and returns the
requested code.

In scope: the trap loop, register decode, structured logging, clean teardown.
Out of scope (deferred): translating numbers/args, emulating no-Linux-peer
syscalls, reading child-memory buffers, and the seccomp-notify migration (M4).

## Consequences

- **Positive** — `PTRACE_SYSEMU` stops the child at syscall *entry* and
  **suppresses kernel execution entirely** (exactly one stop per syscall, no
  exit-stop). The host kernel never runs a foreign agnos number, so none of the
  collision hazards above can fire. It also gives full register read/write, the
  natural substrate for M1 translation (rewrite `orig_rax`/args, inject a return
  via `PTRACE_SETREGS`). Fastest bring-up, no extra privilege for a same-uid
  child.
- **Negative** — `PTRACE_SYSEMU` is **x86_64-specific** (aarch64 needs
  `PTRACE_GETREGSET`/`NT_PRSTATUS` and different offsets). ptrace is also a
  high-overhead, one-stop-per-syscall path — acceptable for M0–M3, but the
  fan-out-at-scale goal is why M4 migrates the hot path to seccomp-notify.
- **Negative / owned** — because SYSEMU suppresses execution, the child's own
  `exit()` never runs; the supervisor must explicitly act on `exit#0`, keyed on
  the **agnos** number 0 (never Linux 60, which is agnos `winsize`).
- **Neutral** — M0 must define the ptrace ABI itself (`SYS_PTRACE=101`, the
  `PTRACE_*` requests, `WIFSTOPPED`/`WSTOPSIG`); the Linux stdlib peer carries
  none of them. Lives in `src/intercept.cyr`, guarded x86_64-only.

## Alternatives considered

- **`ptrace(PTRACE_SYSCALL)`** — stops at entry *and* exit and the kernel
  **does** execute the syscall in between. To prevent the foreign call from
  running you must poke `orig_rax = -1` at every entry; forgetting once runs a
  collision. Two stops per syscall doubles the trap cost. Rejected: SYSEMU makes
  non-execution the default, which is exactly the safety property M0 needs.
- **seccomp user-notify (`SECCOMP_RET_USER_NOTIF`)** — the low-overhead,
  scale-oriented path (gVisor-class) and mirshi's eventual default. Deferred to
  M4: it needs `process_vm_readv` for every argument and a default-deny bounding
  policy to be correct, and it carries the documented `FLAG_CONTINUE` TOCTOU
  0-day class (roadmap 0.7.0). Too much surface to bring up *and* validate
  before interception itself is proven. SYSEMU proves interception first.
- **`LD_PRELOAD` shim** — impossible: agnos binaries are static with no libc,
  so there is no dynamic linker to interpose.
