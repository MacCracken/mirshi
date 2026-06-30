# 0008 — Child-hang robustness: no watchdog; fix the supervisor-emulate heap leak

**Status**: Accepted
**Date**: 2026-06-30

## Context

The 0.6.0 hardening line *"child crash / hang / zombie reaping — do not die with the
child stuck"* was scoped **empirically** (after [ADR 0007](0007-group-stop-signal-handling.md),
where an assumed failure mode turned out not to exist — verify before building). The
question: does a *hung* agnos child (blocked in a syscall, or spinning in a compute
loop) break the supervisor — orphan, zombie, leak, deadlock, or host harm?

Findings (all verified on this host, several with debug builds):

- A hung child is **correct block-mirroring**: mirshi blocks in `waitpid` while the
  child is legitimately blocked/running. That is not a supervisor defect — it is what
  a faithful supervisor must do. An **internal watchdog would be wrong**: it would
  kill a legitimately long-running tool.
- **No orphan, no persistent zombie, ever.** `PTRACE_O_EXITKILL` (`src/intercept.cyr`,
  set in `_attach`) makes the *kernel* `SIGKILL`+reap the child on **any** tracer
  death — `SIGTERM`/`SIGKILL`/crash/normal-exit — needing no in-process cleanup
  (mirshi installs no signal handler, and that is fine). Verified even in the two
  windows the first experiments missed: (a) mirshi killed while the supervisor sleeps
  in the `sleep_ms#41` emulation and the child is ptrace-stopped, and (b) mirshi
  killed in the `fork`→`_attach` window **before** `EXITKILL` is set — a `TRACEME`'d
  child stopped at the exec trap is still cleaned up by the kernel on tracer death,
  not resumed-and-reparented.
- **No deadlock.** `_wait` retries only on `-EINTR` and returns every other errno;
  the enter/exit phase only toggles on a real syscall stop, so a mid-syscall
  `WIFSIGNALED`/`WIFEXITED` exits the loop cleanly. The child cannot `fork`/`clone`
  (not in the seccomp allowlist), so nothing ever reparents to mirshi-as-PID-1.
- **One real gap — a supervisor-side heap leak (not a hang).** The dispatcher
  `alloc()`d a fresh 16-byte timespec **per call** for the supervisor-emulated timers
  `uptime_ms#40` and `sleep_ms#41`, against the never-freeing bump allocator. A child
  looping an emulated timer drove mirshi's RSS up by megabytes (~2.4 MB / 5 s
  measured) without bound — a **child-driven supervisor-OOM**: the supervisor DoS'd by
  the child it is meant to contain. (The child's *own* memory is rlimit-capped per
  [ADR 0006](0006-host-resource-bounds-child-rlimits.md), but the supervisor has no
  self-rlimit; the per-call alloc was the leak.)

## Decision

**Add no watchdog and no new hang-handling mechanism — child-hang is handled by
design (block-mirror + `PTRACE_O_EXITKILL` + `waitpid` status). Fix the one real gap:
hoist the emulated-timer timespec scratch to a one-time lazily-allocated static so a
looping child cannot grow the supervisor's heap.**

- `src/dispatch.cyr` — `_emu_ts_buf()` returns a single 16-byte buffer allocated once
  (lazily); `uptime_ms#40` and `sleep_ms#41` use it instead of a per-call `alloc(16)`.
  Single in-flight call per child + strict enter/exit alternation make one shared slot
  safe (the same one-slot-global discipline as `_xlat_emu_ret` and the M2 repack
  buffers); each call overwrites the fields before use.
- `scripts/it/supervisor_hardening.sh` (CI gate) — (1) asserts mirshi's RSS stays
  flat under an `uptime_ms#40` storm (the leak grew it ~MBs; the fix holds it ~0), and
  (2) asserts terminating mirshi mid-hang leaves no orphan and no zombie (guards
  `EXITKILL`).

With the fix, mirshi's RSS under an unbounded emulated-timer storm is **flat**
(verified: 116 kB → 116 kB), vs ~2.4 MB / 5 s growth before.

## Consequences

- **Positive** — the supervisor can no longer be memory-DoS'd through its emulate
  path; the hot path for the two emulated timers is now allocation-free (a down payment
  on the 0.8.0 "allocation-clean hot path" goal). The child-hang requirement is met
  with **zero new code** beyond the leak fix — the kernel's `EXITKILL` already
  guarantees no orphan/zombie on any supervisor death, and a hung child correctly
  blocks the supervisor rather than corrupting it. A durable record that an internal
  watchdog was *considered and rejected*.
- **Negative / owned** — the supervisor still has **no self-rlimit**; the static
  buffer removes the *known* per-syscall leak, but any future per-call allocation on
  the hot path would reintroduce child-driven growth. The `supervisor_hardening.sh`
  RSS check is a guard, but it only covers the emulate-timer path — a new emulate
  handler that `alloc()`s per call needs its own buffer hoisted (mirror the
  `_emu_ts_buf` / `scratch.cyr` pattern). A hung child still pins one supervisor +
  one child until externally terminated — correct, but the operator (container
  orchestrator) owns the wall-clock bound, not mirshi.
- **Neutral** — `sleep_ms#41` with `ms > 0` still sleeps the supervisor (capped 1 h);
  that is intended block-mirroring, unaffected by the buffer change.

## Alternatives considered

- **An internal watchdog / per-child wall-clock timeout** — rejected: a legitimately
  long-running agnos tool is indistinguishable from a "hang", so a watchdog would kill
  valid work. The wall-clock bound belongs to the external orchestrator (the Docker
  runtime / the fault harness's own `timeout`), not the syscall supervisor.
- **A self-`RLIMIT_AS` on the supervisor** — would *bound* the leak's blast radius
  (mirshi OOMs at the cap, `EXITKILL` then reaps the child — fail-safe) but does not
  *fix* the leak; it also risks killing a legitimately memory-busy supervisor. The
  one-time static buffer removes the leak at the source, which is strictly better; a
  self-rlimit remains available as defense-in-depth if a future, harder-to-hoist
  allocation appears.
- **Reset the bump allocator per syscall (`alloc_reset` in the trace loop)** —
  rejected: the loop holds live buffers across the enter/exit boundary (`regs`,
  `status`, the staged red-zone paths, the M2 repack buffers), so a blanket reset
  would free memory still in use. Hoisting the specific leaking buffers is the
  surgical fix.
- **A graceful `SIGTERM`/`SIGINT` handler in mirshi** — unnecessary for correctness:
  `EXITKILL` already cleans up the child on the default signal disposition, verified
  across `SIGTERM`/`SIGKILL`/crash. A handler would add code for no cleanup benefit;
  deferred unless a future need (e.g. flushing diagnostics) appears.
