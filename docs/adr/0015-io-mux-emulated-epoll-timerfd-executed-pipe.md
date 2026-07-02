# 0015 — I/O multiplexing: supervisor-emulated epoll + timerfd, execute-in-child pipe

**Status**: Accepted (v1.7.0 — epoll_create#19 / epoll_ctl#20 / epoll_wait#21 / timerfd_create#22 / timerfd_settime#23 / pipe#25)
**Date**: 2026-07-01

## Context

I/O multiplexing is the third post-v1 minor after multi-process (v1.5.0) and signals (v1.6.0) — the
readiness / timer / pipe primitives an agnos server reaches for once it outgrows the net band's blocking
loops. The frozen ABI ([`lib/syscalls_x86_64_agnos.cyr`](../../lib/syscalls_x86_64_agnos.cyr)) is
deliberately small:

- `epoll_create#19()` → fd/-1 (no args; an **8-watch** list). `epoll_ctl#20(epfd, op, fd)` → 0/-1 with
  op **1=ADD / 2=clear** — there is **no interest-mask arg** (readiness is implicitly read-readiness)
  and **no per-fd DEL** (only a whole-list clear). `epoll_wait#21(epfd, events_ptr, max)` → nready;
  each event is a packed 12-byte `{u32 mask; u64 data}` (data = the watched fd).
- `timerfd_create#22()` → fd/-1 (no args). `timerfd_settime#23(fd, flags, val_ptr)` → 0/-1; the val is
  `{u64 interval_sec@0; _@8; u64 initial_sec@16}` (24 B, **seconds only**).
- `pipe#25(fds_ptr)` → 0/-1, writing **2×u64** (read, write) at `fds_ptr`.

The decisive constraint is the **emulated-fd reality** established by the net band
([ADR 0012](0012-net-band-supervisor-emulated-conn-table.md)) and the signal band
([ADR 0014](0014-signal-band-supervisor-emulated-masks-signalfd.md)): agnos **socket** fds are
supervisor-held host fds behind an opaque conn_id, and **signalfd** readiness is a supervisor-side mask
— *neither is a real fd in the child*. A server's epoll exists precisely to watch those. So a **real
in-child epoll fd could not see them** (separate fd tables across the ptrace boundary; there is no
`pidfd_getfd`/`CLONE_FILES` anywhere in `src/`). epoll — and, for coherence, timerfd — **must** be
supervisor-emulated.

## Decision

### Tag ladder (`src/children.cyr`) — the emulated-fd id space
A strictly **descending, bit-30-clear** ladder, so a single `>= MIN_EMU_BASE` front gate can tier an id
by one compare and every emulated id stays out of the agnos userland's own socket routing (which claims
`AGNOS_SOCK_TAG = 0x40000000`, bit 30):

    SIGFD_BASE   0x20000000 (bit 29)   — signalfd (v1.6.0)
    TIMERFD_BASE 0x10000000 (bit 28)   — timerfd
    EPOLL_BASE   0x08000000 (bit 27)   — epoll instance
    PIPE_BASE    0x04000000 (bit 26)   — RESERVED (a future watchable pipe; unused in the MVP)
    MIN_EMU_BASE 0x04000000            — the low guard

The pure `_emu_classify(fd)` (checks bit 30 **first** — a socket id `0x40000000|slot` exceeds SIGFD_BASE
and would else mis-tier) and `_timer_ticks(now, deadline, interval)` are unit-pinned in `children.cyr`;
the ptrace/pvm plumbing stays in `dispatch.cyr`. `read#5` and `close#6` gain a `>= MIN_EMU_BASE` front
gate that sub-routes descending (signalfd/timerfd → their handler; epoll/reserved-pipe → −1; real child
fd, below the gate → the execute-in-child path unchanged).

### timerfd — a supervisor-side DEADLINE (no real Linux timerfd)
Per-child `C_TIMERFD_TBL` (lazy-alloc-once), 8 slots of `{flags(-1=FREE), deadline_ms, interval_ms,
armed}`. `settime` reads the 24 B seconds-only val, computes `deadline = _mono_ms() + initial_sec·1000`
(`CLOCK_MONOTONIC` — agnos gives no clockid, the only sane choice) with **no Linux `itimerspec` repack**
(we run no host timerfd). `read#5` on a timerfd id delivers the u64 expiration count once the deadline
passes (**deliver-then-consume**: re-arm/disarm only after a successful write), else agnos −1
(non-blocking — the caller polls, yielding via `pause#14`). Untrusted seconds are bounded by
`TIMERFD_SEC_CAP` (≈31.7 yr) + a negative-reject, so `·1000` can't overflow i64 into a wrong timer (the
`sleep_ms#41` `SLEEP_MS_CAP` discipline). A real Linux timerfd was rejected: it would be **invisible to
the supervisor-emulated epoll**, the same stranding as sockets.

### epoll — a supervisor-side instance holding raw watched ids
Per-child `C_EPOLL_TBL`, 4 instances × an 8-entry watch list of **raw agnos ids** (socket / signalfd /
timerfd), resolved **fresh at wait time** (the stale-slot-reuse guard). `epoll_ctl` op 1 = ADD (dedup,
first-empty, negative-reject, 8-cap), op 2 = CLEAR (whole list; fd ignored — the frozen semantics).
`close#6` frees the instance.

`epoll_wait#21` is a **heterogeneous BOUNDED-YIELD pass** — the `pause#14` model, **never** a
`CS_BLOCKED` park: a readiness event has no `wait4` wake source, so parking would wedge the
single-threaded supervisor forever (the failure [ADR 0014](0014-signal-band-supervisor-emulated-masks-signalfd.md)
already rejected for `pause`). Per call: classify each watch; signalfd → a pure `_sig_deliverable & watched`
mask test; timerfd → an `armed && now >= deadline` clock test; **socket → `ppoll` the supervisor-held
host fd** (`_net_fd_pollable`, which — unlike `_net_fd_conn` — accepts a LISTEN slot, since a listener is
POLLIN-readable on an inbound connection). One bounded `ppoll` (timeout 0 if something is already ready,
else a 1 ms quantum; a 1 ms `nanosleep` if there are no socket fds). Merge, then write up to
`min(nready, max, 8)` packed 12 B events `{u32 EPOLLIN; u64 raw-watched-id}`. 0 ready is a valid
non-blocking return (the caller re-polls, yielding). The readiness probes are **read-only** — epoll_wait
reports without consuming, so the program `read#5`s after the wake (level-triggered).

### pipe — EXECUTE-in-child real `pipe2` (the one call kept off the supervisor)
The usage survey is decisive: agnos has **no fork** and `spawn#3` passes **no fds**, so every
agnos-reachable pipe use is **intra-process** (self-pipe / intra-runtime buffering) — exactly what a real
child pipe serves. `pipe#25` is a stage-then-execute-then-exit-repack handler (mirroring
`stat#33`/`getdents#29`): rewrite `orig_rax = pipe2(293)`, point it at an 8 B red-zone scratch,
`O_CLOEXEC`; the exit stop widens the two i32 host fds → the agnos `{u64 read; u64 write}` (16 B). The
output buffer is **write-probed at the enter stop** so a bad `fds_ptr` fails clean (agnos −1) with **no
fds leaked** (the net band's fail-clean discipline). `agnos_to_linux_nr(25)` stays −1 (dispatcher-
intercepted before the mapper → the freeze test's value is pinned). This is the **sole** child-seccomp
delta in v1.7.0 (`pipe2=293`).

## Consequences

- **Positive** — a full event loop works: `epoll_wait` wakes on a socket, a timerfd, or a signalfd
  through one readiness engine reusing existing machinery (`ppoll`, `_sig_deliverable`, `_mono_ms`,
  `_net_fd_*`, the `pause`-style bounded yield). epoll + timerfd add **zero** child-seccomp entries
  (all supervisor-side); pipe adds exactly one. `PIPE_BASE`/`C_PIPE_TBL` are **reserved** so a future
  supervisor-held **watchable** pipe is purely additive.
- **Negative / owned** — (1) **socket-watching is best-effort**: a program watches the bit-30-tagged
  socket fd, and epoll resolves it by `id & 7` → conn slot. This is **exact for sequential server
  flows** (listen/accept — the primary case), but the guest's own socket-fd slot allocator
  (`_agnos_conn_tbl`) and mirshi's conn-slot allocator can **diverge under connect-failure churn**, so a
  watched socket may then resolve to the wrong / a free slot. A coordinated **agnos-kernel + mirshi-shim
  repair** (the guest passing a mirshi-resolvable id) will nail this down; until then it is a documented
  caveat, guarded by the wait-time `SLOT_FREE` re-validation. (2) A **real child fd** (stdin, a pipe end)
  is **not epoll-watchable** — the supervisor doesn't hold it; such watches are silently skipped. (3) A
  **blocking pipe read** with no data and no concurrent writer would wedge the single-threaded supervisor
  (the intra-process write-before-read / self-pipe pattern avoids it; O_NONBLOCK/watchable pipe is the
  reserved follow-up). (4) `epoll_wait`'s bounded `ppoll`/`nanosleep` **head-of-line-blocks** other
  children for ≤1 ms (the `pause#14`/`sleep_ms#41` class). (5) timerfd and signalfd `read`s are
  **non-blocking** (poll-with-`pause`); a signalfd/timerfd `close` leaks its slot until process exit
  (bounded 8/proc) — a `close#6` divert frees timerfd + epoll slots, signalfd stays as v1.6.0.
- **Neutral — ABI-ambiguity defaults** (no in-tree consumer to confirm; baked as the only self-consistent
  reading, "confirm when a real consumer lands"): the epoll event mask is `EPOLLIN=0x1` with `data` at
  offset 4 (12 B packed); `epoll_ctl` op 2 is a **whole-list clear** (the fd arg ignored — no per-fd
  DEL); `timerfd` `flags` is treated as **relative** (TFD_TIMER_ABSTIME ignored — murky with seconds-only
  vals + no clockid). Matrix rows #19–23 move ENOSYS → EMULATE and #25 ENOSYS → EXECUTE; the freeze
  test's `agnos_to_linux_nr` values stay pinned (all intercepted before the mapper).

## Alternatives considered

- **Execute-in-child epoll** (a real Linux epoll fd in the child) — rejected: it can only watch real
  child fds, but the whole point is watching the **emulated** sockets/signalfds, which are not child fds.
  Dead on arrival.
- **A real host timerfd fd** — rejected: it would be invisible to the supervisor-emulated epoll (same
  stranding as sockets). A supervisor-side deadline folds into the readiness pass with a pure clock
  compare and needs no `read` plumbing beyond the count.
- **Blocking / parking `epoll_wait`** (a `CS_BLOCKED` park woken by readiness) — rejected: a readiness
  event has no `wait4` wake source, so a park wedges the single-threaded supervisor (the `pause#14`
  lesson). Bounded yield is the safe MVP; a true blocking wait is deferred.
- **Supervisor-held watchable pipe** (both ends host fds, read/write via pvm, epoll-pollable) — deferred,
  not rejected: no agnos-reachable epoll-on-pipe pattern exists (no fork; spawn passes no fds), so it
  would be dead machinery today. The reserved `PIPE_BASE`/`C_PIPE_TBL` make it additive when a consumer
  needs it.
