# 0007 — Group-stop signal handling: discriminate and suppress, don't re-inject

**Status**: Accepted
**Date**: 2026-06-30

## Context

Both supervisor trace loops (`_trace_log`, `_trace_run` in `src/intercept.cyr`) peel
off syscall-stops (the `SIGTRAP|0x80` TRACESYSGOOD marker) and handle every other
`WIFSTOPPED` in one else-branch that did `pending_sig = sig` — blind re-injection of
whatever signal stopped the child. The code carried a standing TODO that this is
wrong for a **group-stop**: when the child receives a stopping signal (`SIGSTOP`,
`SIGTSTP`, `SIGTTIN`, `SIGTTOU`) the kernel reports a group-stop, and per ptrace(2)
the correct restart of a group-stopped tracee carries **no signal** — you do not
re-deliver the stop. The roadmap's 0.6.0 line is *"supervisor signal handling —
don't die with the child stuck."*

A measured-on-this-kernel finding shaped the decision: an external `SIGSTOP` to the
agnos child (it cannot self-`kill` — `kill` is not in the seccomp allowlist) surfaces
to mirshi as **two stops** — first a signal-delivery stop (`WSTOPSIG=SIGSTOP`,
`PTRACE_GETSIGINFO` *succeeds*, so mirshi forwards it, delivering the `SIGSTOP`), then
the resulting group-stop (`PTRACE_GETSIGINFO` *fails* `-EINVAL`, so mirshi suppresses
it, resuming with no signal). **The child runs to completion whether mirshi suppresses
the group-stop or blindly re-injects it** — Linux discards a stop signal re-injected
at a group-stop. So blind re-injection does **not** wedge the supervisor here; the
defect is protocol-correctness and cross-kernel robustness, not an observed hang.
Verified by instrumentation: the raw `PTRACE_GETSIGINFO` returns are `0` then
`-EINVAL`. (The request number is `0x4202`; an initial miswiring as `4` =
`PTRACE_POKETEXT` made the discrimination dead code that *still passed the end-to-end
test* — so this path's correctness rests on the instrumented check + review, since no
behavioral test can distinguish it on a lenient kernel.)

## Decision

**Discriminate group-stops with `PTRACE_GETSIGINFO` and SUPPRESS them (resume with
`data=0`); keep forwarding genuine signal-delivery stops.** Applied identically to
both loops. Scope:

- `_is_group_stop(pid, sig, si)` — only the four stopping signals can produce a
  group-stop, so probe `PTRACE_GETSIGINFO` (request `0x4202`) **only** for those: it
  fails with **exactly** `-EINVAL` at a group-stop and succeeds at a signal-delivery
  stop. Returns 1 only on `== -EINVAL` (not any `< 0`, so a raced `-ESRCH` from a
  child that just exited is not misread as a group-stop). `si` is a per-loop
  `siginfo_t` buffer (`SIGINFO_SIZE` = 128).
- Else-branch: `if group-stop -> pending_sig = 0` (suppress; the unconditional
  top-of-loop `PTRACE_SYSCALL`/`PTRACE_SYSEMU` then resumes the child with no signal).
  Otherwise `pending_sig = sig` (forward `SIGTERM`/`SIGSEGV`/… as before).
- **Suppress, not `PTRACE_LISTEN`.** mirshi is a headless, single-child, run-to-
  completion supervisor with no job control and no one to send `SIGCONT`. Honoring the
  stop (`PTRACE_LISTEN`) would leave the child stopped indefinitely — the literal
  *"child stuck"* the roadmap warns against — and would not fit the loop's
  unconditional top-of-loop resume. Suppression keeps the child runnable, the right
  policy for a tool-runner; real pausing is the container freezer / cgroup, not a
  per-child signal.

This is **correctness and cross-kernel robustness**, not a behavior change for the
common case on Linux (the child completes either way).

## Consequences

- **Positive** — the group-stop path now conforms to the ptrace(2) protocol (resume a
  group-stopped tracee with no signal), so the supervisor never re-delivers a stop it
  did not originate and is robust on kernels/configs where re-injecting a stop signal
  is **not** silently discarded. Removes a long-standing TODO. Genuine
  signal-delivery stops are unaffected. The `GETSIGINFO` probe runs only for the four
  stopping signals, so the common signal path pays nothing.
- **Negative / owned** — the agnos child is now deliberately **immune to job-control
  stop via signal** (`SIGSTOP`/`SIGTSTP`/…): mirshi resumes it. This is intended for a
  headless runner; an operator who wants to pause the workload uses the container
  freezer / cgroup, not a signal to the inner pid. One extra `alloc(128)` siginfo
  buffer per trace-loop invocation (not per stop).
- **Neutral** — the regression gate (`scripts/it/groupstop.sh`) verifies the
  *requirement* (an external `SIGSTOP` does not leave the child stuck; mirshi exits
  cleanly), **not** suppress-vs-re-inject — on a lenient Linux kernel both satisfy it,
  so the pre-fix code also passes. The test still catches a genuine strand (a
  mis-wired `PTRACE_LISTEN`, a crash in the group-stop path, a stricter kernel).

## Alternatives considered

- **Blind re-injection (status quo)** — `pending_sig = sig` for stop signals. Works on
  Linux (the child runs), but re-delivers a stop the supervisor never originated,
  violates the ptrace group-stop protocol, and relies on the kernel silently
  discarding the re-injected stop — fragile across kernels. Rejected.
- **`PTRACE_LISTEN` (honor job control)** — the protocol-complete way to honor a
  group-stop: leave the tracee stopped and wait for `SIGCONT`. Wrong for mirshi — a
  headless container has no one to `SIGCONT`, so the child would be **stuck**
  indefinitely (the exact failure the roadmap names); it also needs the loop split so
  the listen isn't cancelled by the unconditional top-of-loop resume. Deferred unless
  a job-control consumer ever appears.
- **Suppress by signal number, skip `GETSIGINFO`** — just treat `sig ∈ {19,20,21,22}`
  as suppress. Simpler, and behaviorally equivalent here, but it conflates a genuine
  signal-delivery stop of a stopping signal with a group-stop; `PTRACE_GETSIGINFO` is
  the canonical, self-documenting discriminator and keeps the door open to a future
  `PTRACE_LISTEN` policy without re-deriving the stop type.
