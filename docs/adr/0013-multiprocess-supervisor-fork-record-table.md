# 0013 — Multi-process: supervisor-driven fork + memfd/execveat, a per-child record table, and an opaque-monotonic pid model

**Status**: Accepted (v1.5.0 — spawn#3 / waitpid#4 / getpid#2)
**Date**: 2026-07-01

## Context

Multi-process is the **crown-jewel** post-v1 surface ([roadmap](../development/roadmap.md)): it runs
**agnsh** (the agnos shell) and any agnos tool that forks children. The frozen ABI
([`lib/syscalls_x86_64_agnos.cyr`](../../lib/syscalls_x86_64_agnos.cyr)) exposes it as:

- `spawn#3(elf_addr, elf_size) → pid / -1` — a new process from an **in-memory ELF image** (the bytes
  live in the *calling child's* address space), returning an opaque pid.
- `waitpid#4(pid) → exit_code` — **BLOCKING**, single-pid; rax **is** the exit code (agnos has no
  Linux status word — no `WEXITSTATUS` indirection).
- `getpid#2 → pid`; `kill#16(pid, sig)` is *"self/child only"*, pid 0 protected.

This is structurally unlike the M1/M2/net surface, forcing several decisions:

- **The supervisor is single-child.** The v1 `_trace_run` loop `wait4(pid)`s exactly one tracee and
  keeps its enter→exit carry in loop locals + dispatch globals. Tracing N children needs a different
  loop.
- **spawn is a fused, in-memory exec.** agnos `spawn` is *not* a Linux `fork`+`execve(path)`; it loads
  an ELF **image** already in memory. There is no path to `execve`.
- **A new trust + resource surface.** [ADR 0006](0006-host-resource-bounds-child-rlimits.md) closed the
  PID/process-exhaustion vector *structurally*: the child seccomp bound
  ([ADR 0004](0004-docker-vehicle-bounding-seccomp.md)) carries **no** `clone`/`fork`, and `spawn#3` was
  `ENOSYS` — so *"a process storm is structurally impossible."* Making `spawn#3` real **reopens** that
  vector unless something re-bounds it.
- **The pid space is unspecified in-repo.** The agnos-userland ABI doc is not vendored; the pid *value*
  form is not pinned (see the pid decision below).

## Decision

Build multi-process as a **single-threaded, multi-tracee supervisor** with a **per-child record
table**, **supervisor-driven fork + memfd + execveat**, and an **opaque-monotonic pid model**. No
kernel-thread concurrency; the loop services exactly **one ptrace stop per iteration**.

### The multi-tracee loop
Generalize `_trace_run` into a `wait4(-1, __WALL)` demux: wait for the next stop from **any** child,
look the woken **host** pid up in the record table, service that one stop keyed on its record, then
**resume that child immediately** (so the signal-forwarding carry needs no cross-iteration state). The
loop returns only when the **root** (agnos pid 1) exits; a non-root exit stashes its code in the record
and keeps looping. `PTRACE_O_EXITKILL` on every tracee SIGKILLs any lingering grandchild on teardown.
Servicing one stop at a time keeps dispatch **non-reentrant**, so the pure staging buffers stay
**shared** — only the enter→exit carry and the net-slot table move per-child.

### The per-child record table
One fixed `MAX_CHILDREN = 16` array of records (lazy-alloc-once, ADR 0008 discipline), each holding the
pid mapping, state (`FREE`/`RUNNING`/`BLOCKED`/`EXITED`), exit code, wait target, `needs_attach`, and
the enter→exit carry (`at_entry`/`agnos_nr`/`strat`/the EMULATE-return + M2-repack staging) + the
per-child net-slot table. This is the supervisor's first **persistent cross-trap per-child** state
(M1/M2 had one-in-flight-call globals). ([`src/children.cyr`](../../src/children.cyr).)

### spawn#3 = supervisor-driven fork + memfd + execveat
On the `spawn#3` enter stop (a **supervisor-control** op handled at the loop level, *not* in
`translate_dispatch` — it forks and calls `_child_exec_memfd`, which depend on `limits.cyr`/
`seccomp.cyr`): storm-bound check → `process_vm_readv` the caller's ELF (bounds-checked) → the
supervisor `memfd_create`s + writes the image → `fork`s a grandchild that runs the same
TRACEME→rlimits→rootfd→seccomp gauntlet then `execveat(memfd, "", AT_EMPTY_PATH)` → the supervisor
registers the grandchild (`needs_attach`) and injects the coined agnos pid. Chosen over
**`PTRACE_O_TRACEFORK` auto-attach** because the agnos child never issues a real Linux `fork`/`clone`
(spawn is EMULATE, and the child bound forbids clone) — there is no kernel fork event to catch. Doing
the fork **supervisor-side** keeps `clone`/`fork` **out of the child bound**: the only allowlist
addition is `execveat(322)` (the grandchild's image load; the filter + `NO_NEW_PRIVS` persist across it,
so the re-exec'd image stays bounded). Fail-closed to agnos `-1` on any error.

### waitpid#4 = park-or-claim
Also loop-level (it may **park** the caller — leave it stopped — which needs loop cooperation). If the
target already `EXITED`, claim it (inject the retained code, free its slot). Else **park** the caller
(`orig_rax=-1` so on resume it lands at its exit stop; state `BLOCKED`); the loop leaves it stopped —
**not the supervisor** — so other children keep running. When the target exits, the `WIFEXITED` handler
injects the code into every parked waiter's carry and resumes it. This is what removes the
head-of-line-blocking a naïve "supervisor blocks in waitpid" would cause. Unknown/already-reaped
target → `-1`.

### getpid#2 = the caller's coined pid
`getpid#2` moves EXECUTE→EMULATE, returning the caller's coined agnos pid (the loop-supplied
`_cur_rec`), not the host `getpid#39` — once >1 process exists, a child must see **its** agnos pid, and
two children seeing distinct host pids would clash with the pids `spawn` coins.

### The pid model — opaque monotonic, bidirectional-ready
mirshi coins the **guest-facing** agnos pid as a private **monotonic index** (root = 1, +1 per spawn,
**never reused**, 0 reserved) and maps it to the real host pid in the record table (two-way lookup).
The pid **contract** is agnos-owned (an opaque token ≥0, 0 protected, waitpid/kill self/child-scoped —
what the ABI already implies); the pid **value** is mirshi-owned in **direction 1** because *no agnos
kernel runs* — mirshi is the process creator (exactly as it coins the net band's `conn_id`/
`listener_id`, [ADR 0012](0012-net-band-supervisor-emulated-conn-table.md)). Coining opaque pids (never
passing a host pid through) keeps this **direction-agnostic**: direction 2 (the v2+ Linux→AGNOS
"swallow") flips the guest/host roles and reuses the same table + coiner. Never-reuse makes a late
`waitpid` on a reaped pid deterministically `-1`.

### The storm bound — re-closing the ADR 0006 vector
Flipping `spawn#3` to EMULATE means the **supervisor** forks per spawn, reopening the process-storm
vector [ADR 0006](0006-host-resource-bounds-child-rlimits.md) had closed *"structurally"* (via the
child bound + `spawn#3` ENOSYS). It is re-closed **supervisor-side** by the `MAX_CHILDREN` cap, checked
**before** each fork (so an untrackable grandchild is never created). Deliberately **not**
`RLIMIT_NPROC` — that is per-uid and container-hostile (ADR 0006's own reasoning); the supervisor cap
is exact and local.

### The deadlock guard
A self-wait (`waitpid(getpid())`) or a wait-cycle would park every involved child `BLOCKED` with no
runnable tracee, so `wait4(-1)` would block **forever, wedging the single-threaded supervisor** — worse
than a hung program (the sandbox deputy itself hangs, holding host resources). The loop checks
`_any_running()` before each `wait4`: if no child is `RUNNING`, `_break_deadlock` fails every parked
waiter with agnos `-1` and resumes it. A misbehaving/hostile child degrades gracefully, never wedges
mirshi (0.6.0 hardening stance).

## Consequences

- **Positive** — the crown-jewel surface works: an agnsh-class parent-spawns-child-and-waits runs under
  one supervisor, to arbitrary depth (root→child→grandchild — the record table is **flat**, so nesting
  needs no special code). The child seccomp bound grows by **exactly one** number (`execveat`); the
  supervisor holds the fork + the process-count choke point. The pure staging buffers stay shared
  (single-stop-per-iteration non-reentrancy). The pid model is bidirectional-ready.
- **Negative / owned** — the supervisor now holds **persistent per-child state** (the 16-slot table).
  **Head-of-line blocking**: `sleep_ms#41` and blocking net I/O still run *in the supervisor*, so while
  one child sleeps the others don't advance (agnsh is largely serial `spawn`-then-`waitpid`, which the
  park/wake path handles without blocking; the general fix — multiplex timers/I/O into the `wait4`
  loop — is **deferred** past v1.5.0, and pairs naturally with v1.6.0 signals). **8-bit exit codes**:
  agnos `exit(>255)` is truncated by the host `exit_group` status word (`& 0xFF`); acceptable since
  agnos codes are conventionally 0–255. **EXITKILL attach window**: a grandchild between `fork` and its
  first-stop `SETOPTIONS` is not yet `EXITKILL`-protected — identical to the root child's pre-existing
  window, accepted. **Deadlock is broken, not detected**: cyclic waiters all get `-1` rather than a
  diagnostic.
- **Neutral** — `waitpid` waits on **any known pid** (a safe superset of direct-child-only; can be
  tightened if the agnos kernel scopes it). `getppid`/`kill#16` stay unsupported (kill is v1.6.0; the
  record already carries `parent`/state/exit_code so it slots in behind this milestone). The frozen
  matrix rows #2/#3/#4 move ENOSYS→EMULATE; `agnos_to_linux_nr` is unchanged for them (they are
  intercepted at the loop level / dispatcher, before it), so the freeze test's *values* stay pinned.

## Alternatives considered

- **Execute-in-child fork (real `clone`/`fork` in the child, `PTRACE_O_TRACEFORK` auto-attach)** —
  rejected: `spawn#3` is EMULATE (the child never issues a Linux fork), it would put `clone`/`fork` in
  the child seccomp bound (widening the sandbox surface + the fork-bomb vector the supervisor cap
  otherwise governs), and it does not match the in-memory-ELF semantics (there is no path to execve).
- **`RLIMIT_NPROC` for the storm bound** — rejected (ADR 0006's reasoning): per-uid, container-hostile,
  a false-`EAGAIN` footgun. The exact supervisor `MAX_CHILDREN` cap is local and deterministic.
- **Host-pid pass-through** (spawn returns the real Linux pid; getpid returns it) — rejected: leaks host
  pids into the sandbox, is non-deterministic across runs, and would **not** flip cleanly for direction
  2 (the "host" there is the agnos kernel). The user (the agnos authority) chose the opaque-monotonic
  index explicitly *"so long as it can work bidirectionally later."*
- **A blocking supervisor `waitpid`** (the supervisor itself `wait4`s the target) — rejected: it would
  freeze every *other* child while one parent waits (total head-of-line blocking). Parking the caller
  keeps the supervisor free.
- **Multi-threaded / truly concurrent dispatch** — rejected for v1.5.0: it would force per-child locking
  on every staging buffer; the single-stop-per-iteration model gives correct interleaving at a fraction
  of the complexity, and matches the ptrace cost model (the stops dominate, not CPU).
