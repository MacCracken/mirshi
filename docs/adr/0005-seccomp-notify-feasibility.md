# 0005 — seccomp-notify cannot replace the ptrace renumber loop; M4 is a hybrid

**Status**: Accepted
**Date**: 2026-06-29

## Context

The roadmap's M4 (v0.5.0) reads: *"Replace the ptrace trap loop with
`SECCOMP_RET_USER_NOTIF` … the M1–M3 suite passes under seccomp-notify with
materially lower per-syscall overhead."* Before committing that rewrite, a
feasibility study (web + the kernel headers) checked whether seccomp-notify can
do what mirshi's translation requires.

mirshi's model ([ADR 0002](0002-execute-in-child-translation.md)) is
**renumbering**: at the ptrace syscall-enter stop it rewrites `orig_rax` (an
agnos number) to the Linux peer and the kernel runs *that* syscall **in the
child's address space**. The load-bearing case is `mmap#27`→Linux `mmap#9`,
executed in-child so the new VMA lands in the child's `mm` and the returned
address is child-valid.

## Decision

**Record that a *full* seccomp-notify replacement is architecturally impossible
for mirshi, and reframe M4 as a hybrid — pending the user's scope sign-off (this
departs from the literal roadmap text).** Land the benchmark baseline +
[docs/benchmarks.md](../benchmarks.md) now as the data that justifies the hybrid.

The confirmed facts:

- **seccomp-notify cannot renumber or rewrite args.** `struct seccomp_notif_resp`
  is exactly `{u64 id; s64 val; s32 error; u32 flags}` (verified in
  `linux/seccomp.h` / `seccomp_unotify(2)`). Per notification the kernel offers
  only **EMULATE** (`flags=0`: the original syscall never runs; the supervisor
  returns `val`/`error`) or **CONTINUE** (`FLAG_CONTINUE`: the kernel runs the
  *original, unmodified* syscall). There is no field to change the syscall number
  or args. The renumber/run-in-child primitive lives **only** in the ptrace
  family (`PTRACE_SETREGS` at an enter-stop, or `SECCOMP_RET_TRACE` +
  `PTRACE_O_TRACESECCOMP`).
- **`mmap`/`munmap`/`brk` are unreachable under notify.** EMULATE can't create a
  VMA in another process's `mm` (the supervisor's own `mmap` maps into the
  supervisor; no notify ioctl mutates the target's `mm`; `ADDFD` installs only
  fds; `process_vm_writev` only writes already-mapped pages). CONTINUE runs the
  agnos number as the wrong Linux syscall (agnos `mmap#27` = Linux `mincore#27`).
  This is exactly gVisor's documented limitation (#7426).
- **The emulatable hot path is sound.** `read`/`write`/`lseek`/`dup`, the `stat`
  family, `getdents`, `open` (host-open + `SECCOMP_IOCTL_NOTIF_ADDFD`,
  `ADDFD_FLAG_SEND` for atomic add-and-respond), the pure path calls
  (`mkdir`/`rmdir`/`unlink`/`rename`/`link`), and the scalars/timers are all
  supervisor-emulatable — none mutates the child's address space; they compute a
  scalar, `process_vm_writev` into an *existing* child buffer, or inject an fd.
  This is the lower-overhead path (skip one of the two ptrace stops).
- **`FLAG_CONTINUE` is a TOCTOU footgun** (the roadmap's 0.7.0 0-day class). On
  CONTINUE the kernel re-reads pointer args **fresh at execution time**, so a
  racing thread in a multi-threaded child can swap a validated buffer
  (`/allowed`→`/etc/shadow`) between the supervisor's check and the kernel's act.
  The header states plainly: the notifier *"cannot be used to implement a security
  policy."* mirshi's rule: **EMULATE every pointer/buffer syscall from a single
  supervisor-side copy; never read-decide-then-CONTINUE.** (CONTINUE is also
  wrong-number for every agnos call, so mirshi never uses it.)

The reframed M4 (recommended): **seccomp-notify for the emulatable hot path +
`SECCOMP_RET_TRACE`/ptrace for the renumber residue (`mmap`/`munmap`/`brk`).** One
tracer owns both the notify fd and the ptrace stops. It passes M1–M3, captures the
high-frequency win, and reuses the entire shipped dispatcher for the residue.

## Consequences

- **Positive** — a durable record of *why M4-as-written is unsatisfiable*, so the
  next engineer doesn't re-litigate the dead end. The benchmark baseline lands
  now (pure win) and gives the data to justify (or defer) the hybrid.
- **Negative / owned** — M4 becomes a scope fork the user must approve; the
  hybrid is dual-mechanism (a notify event loop *and* ptrace stops in one tracer
  — more coexistence state, the `SECCOMP_IOCTL_NOTIF_ID_VALID` dual-check for safe
  child reads), so it is more complex than either mechanism alone.
- **Neutral** — the gVisor-class endpoints that *do* solve mmap-in-child without
  ptrace (systrap's in-stub SIGSYS handler; the KVM platform) are deferred to a
  post-M4 platform arc. The KVM path would defeat the no-QEMU/shared-host-kernel
  premise of direction-1 v1, so it stays out of scope.

## Alternatives considered

- **Pure seccomp-notify (M4 literal)** — impossible: cannot renumber, cannot
  `mmap` in-child. The M1–M3 suite exercises mmap-backed allocation, so a
  pure-notify supervisor fails it. This ADR is the record of that.
- **memfd + `ADDFD` for mmap** — gives shareable *storage*, not the *act* of
  mapping it in the child (the child would still have to issue a native `mmap`,
  which it can't — it issues agnos `#27`). A building block, not a drop-in.
- **Pre-mapped child arena** (emulate anonymous-heap mmap from a supervisor-side
  allocator over a startup-reserved VMA) — a real *optimization* on top of the
  hybrid, but can't cover `MAP_FIXED`, file-backed mappings, arena exhaustion, or
  true `munmap`; never the sole mmap strategy.
- **gVisor systrap** (SIGSYS in-stub handler driving mmap into the child's own
  `mm`) — the only userland path that solves mmap-in-child without ptrace, but a
  major re-architecture (per-thread shared-memory sysmsg protocol, in-stub signal
  handler, address-space manager) and *not* seccomp-notify. Post-M4.
