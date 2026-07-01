# 0014 — Signal band: supervisor-emulated pending/blocked masks + an opaque-tagged signalfd

**Status**: Accepted (v1.6.0 — pause#14 / kill#16 / sigprocmask#17 / signalfd#18)
**Date**: 2026-07-01

## Context

Signals are the second post-v1 minor after multi-process ([roadmap](../development/roadmap.md)), and the
one agnsh reaches for once it has `spawn`/`waitpid` — a shell needs `kill` + signal notification. The
frozen ABI ([`lib/syscalls_x86_64_agnos.cyr`](../../lib/syscalls_x86_64_agnos.cyr)) exposes four calls,
and the agnos signal model is **signalfd-centric with NO async `sa_handler`**:

- `kill#16(pid, sig)` → 0/-1: OR `1<<sig` into the target's pending mask. Scope is *"self/child only"*,
  pid 0 protected.
- `sigprocmask#17(how, set, oldset)` → 0/-1: update the caller's blocked mask.
- `signalfd#18(fd, mask, flags)` → fd/-1: an fd you **read** to receive pending signals; a read returns
  *"the bit position AS the signal number"* (kernel `vfs_read_signalfd`) — **not** a Linux 128-byte
  `signalfd_siginfo` struct.
- `pause#14()` → 0: *"one hlt"* — wait for a signal.

Two facts force the design. **(1)** The mask convention is agnos `1<<sig` (bit N = signal N), **NOT**
libc's `1<<(sig-1)` — the lib comment flags this as load-bearing, since `kill`/`signalfd`/`sigset` must
agree. **(2)** `pause#14` has a real consumer: `_agnos_sock_recv_block`
([`lib/syscalls_x86_64_agnos.cyr`](../../lib/syscalls_x86_64_agnos.cyr)) — the TLS/HTTP blocking-read
path polls a non-blocking `sock_recv#49` and **yields via `pause#14`** between polls, bounded by a
wall-clock deadline. A block-forever `pause` would wedge every TLS/HTTP read.

The v1.5.0 record table + park/wake machinery ([ADR 0013](0013-multiprocess-supervisor-fork-record-table.md))
is the foundation — including the `C_PENDING_SIG` record field reserved for exactly this milestone.

## Decision

Build the signal band as a **fully supervisor-EMULATED** layer over the per-child record table — no
real host signals, no real host fds.

### Masks — per-child record fields, agnos `1<<sig`
Reuse `C_PENDING_SIG` (the reserved field) as the per-child **pending** mask; add `C_SIG_BLOCKED` for
the **blocked** mask (sigprocmask). A signal is **deliverable** iff `pending & ~blocked` has it. The
mask helpers (`_sig_valid` (1..63, guards the undefined `1<<sig`), `_sig_bit`, `_sig_deliverable`,
`_sig_lowest`, `_sig_clear`) are **pure** in `src/children.cyr` and unit-pinned; the ptrace/pvm
plumbing stays in `intercept.cyr`/`dispatch.cyr`. `~x` is the two's-complement identity `0 - x - 1`
(Cyrius has no unary `~`).

### kill#16 — set a pending bit, scoped
`_do_kill` (loop-level, beside spawn/waitpid): validate `sig ∈ 1..63` + `pid ≠ 0` + **self-or-direct-
child** scope (`t == caller` OR `t.parent == caller.agnos_pid`), then OR `1<<sig` into the **target's**
`C_PENDING_SIG`. The caller returns 0; the target observes the bit on its next `pause`/`signalfd` read
(edge-triggered, so nothing to wake in v1.6.0). Killing an EXITED-but-unreaped child is a harmless
no-op (POSIX kill-on-zombie); slot reuse re-zeroes the mask.

### pause#14 — a BOUNDED YIELD, never a wedge
`_do_pause` (loop-level): if `(pending & ~blocked) != 0` return 0 immediately; else `nanosleep` a short
quantum (1 ms) **in the supervisor** (the child is stopped at its trap — the `sleep_ms#41` idiom) then
return 0. This is load-bearing: it protects `_agnos_sock_recv_block`'s poll loop, matches the "one hlt"
edge-triggered contract, and — because it never parks `CS_BLOCKED` — needs **zero** change to the
v1.5.0 deadlock guard.

### signalfd#18 — an opaque tagged fd + read#5 delivery
`signalfd#18` returns `SIGFD_BASE + slot`, indexing a per-child signalfd slot table (`C_SIGFD_TBL`,
lazy-alloc-once, mirroring the net table) whose slots hold `{watched_mask, flags}`. `read#5` gains a
one-compare branch: `fd >= SIGFD_BASE` → `_sigfd_read`, which delivers the lowest
`pending & watched & ~blocked` signal as an **8-byte number** into the child buffer (returning 8) and
**then** clears the pending bit — deliver-then-consume, so a failed child-buffer write never loses a
signal. Nothing deliverable → agnos -1 (the MVP signalfd is **non-blocking**; the caller polls, yielding
via `pause`).

### The `SIGFD_BASE` choice — avoiding the agnos socket-fd tag (the load-bearing lesson)
`SIGFD_BASE = 0x20000000` (bit 29). It **must not** set bit 30, because the agnos userland tags its own
**socket** fds with `AGNOS_SOCK_TAG = 0x40000000` (bit 30) and its `sys_read`/`sys_write`/`sys_close`
route bit-30 fds to the net band **before the syscall** — a signalfd id with bit 30 set would be
swallowed as a socket and never reach mirshi's `read#5`. Bit 29 clears bit 30, so `_agnos_is_sock_fd`
returns 0 and the read passes through to mirshi; the id (`0x20000000..0x20000007`) is still far above
any real child fd (rlimit-capped < 1024). This coordination between mirshi's emulated-fd tags and the
agnos userland's own fd tags is a general constraint for any future emulated fd (epoll, timerfd).

## Consequences

- **Positive** — the full signalfd-centric model works over the existing record table: `kill` →
  pending bit → `signalfd` read delivers the raw number, watch-filtered and mask-gated. No async signal
  injection into the tracee (agnos has no `sa_handler`), so [ADR 0007](0007-group-stop-signal-handling.md)'s
  group-stop forwarding is untouched. The bounded-yield `pause` protects the net band's blocking reads
  and dissolves the deadlock-guard interaction. `kill#16` + the pending mask set up v1.x job control.
- **Negative / owned** — **`pause` head-of-line blocking**: the 1 ms supervisor `nanosleep` blocks other
  children for the quantum (the same class as `sleep_ms#41`; single-child pause is unaffected).
  **Non-blocking-only signalfd**: a `read` with nothing pending returns -1 rather than blocking (a
  blocking signalfd read — level-triggered park — is deferred; the poll-with-`pause` idiom is the MVP
  contract). **signalfd-close slot leak**: `sys_close` on a signalfd does a real (harmless) close and
  does **not** free the mirshi slot — bounded at 8 slots/process, freed on exit; a close#6 intercept is
  a future enhancement. **8-signalfd cap** per process.
- **Neutral** — masks are single 64-bit words (signals 0..63). `sigprocmask` reads `set` before writing
  `oldset` (handles `oldset == set` aliasing). `SIGKILL`/`SIGSTOP` unmaskability and the full POSIX
  masked-stays-pending nuance beyond `pending & ~blocked` are not special-cased (agnos delivers via
  signalfd, not default actions). Matrix rows #14/#16/#17/#18 move ENOSYS → EMULATE; `agnos_to_linux_nr`
  is unchanged (they are intercepted before it), so the freeze test's values stay pinned.

## Alternatives considered

- **Real host signals injected into the tracee** (ptrace signal delivery) — rejected: agnos has no
  `sa_handler`; delivery is fd-based (`signalfd` read), so there is nothing to inject. It would also
  entangle the emulated signals with [ADR 0007](0007-group-stop-signal-handling.md)'s real-signal
  group-stop handling.
- **A real pipe/eventfd as the signalfd** (kill writes bytes, the child reads a real fd) — rejected:
  the supervisor and child have **separate fd tables** across the ptrace boundary, so a supervisor-made
  fd is meaningless in the child, and injecting one needs privileged `pidfd_getfd` the deputy must not
  hold. The opaque emulated-fd + `read#5` intercept is the only path.
- **Block-forever `pause`** (park `CS_SIGWAIT`, wake on `kill`) — rejected for v1.6.0: it would wedge
  `_agnos_sock_recv_block`'s TLS/HTTP poll loop and force a `CS_SIGWAIT` state + a deadlock-guard
  extension. Bounded yield is the safe default and matches the "one hlt" contract; true blocking is
  deferred.
- **libc `1<<(sig-1)` masks** — rejected: agnos `kill`/`signalfd`/`sigset` all use `1<<sig`; mirroring
  the libc off-by-one would silently desync the mask from `kill`/`signalfd`.
- **`SIGFD_BASE = 0x40000000`** (the initial design) — rejected after it collided exactly with
  `AGNOS_SOCK_TAG`; moved to bit 29.
