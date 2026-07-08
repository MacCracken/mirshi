# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.10.1] — 2026-07-07

Continues the exec-band re-sync opened in 1.10.0, on the latest toolchain.

### Added
- **`spawn_path#43` — EMULATE at the loop level** (`_do_spawn_path`, `src/intercept.cyr`). agnos's
  NON-blocking from-disk spawn — the cyrius stdlib `exec_*` path (`_agnos_spawn_path` + `sys_waitpid`,
  distinct from agnsh's `execwait#37`). The from-path exec was refactored into a shared `_spawn_from_path`
  core (read cmdline → tokenize argv → fork a traced grandchild that execve's the path → register):
  `execwait#37` = core + **park** (blocking, returns exit code); `spawn_path#43` = core + **inject the
  coined pid** (async, the caller reaps via `waitpid#4`). Behavioral smoke `docker/tools/sptest.cyr`
  (spawn `./hello` async + waitpid → exit 0). Freeze suite green (295/0); execwait#37 regression-verified
  after the refactor.

### Changed
- **Toolchain pin → cyrius 6.4.19** (from 6.3.27). The committed `lib/` snapshot was re-vendored to match
  (`cyrius lib sync --full` → 98 files) so the pin is real, not shadowed by a stale vendored stdlib. Build
  + full freeze suite (295/0) + the `execwait#37` behavioral smoke all green on 6.4.19.

## [1.10.0] — 2026-07-07

Ships two things together — the argv-forwarding fix that was staged but never released (1.9.0 is the last
tag), and the first **exec-band re-sync** to agnos's grown userland ABI.

**exec band — `execwait#37` (agnsh's `run`).** agnos grew a ring-3 blocking-exec primitive past mirshi's
frozen 0–61 surface: `execwait#37` loads a static ELF from a **path** and runs it **to completion**,
returning its exit code — the syscall agnsh binds for `run /bin/x`. It sat in mirshi's `#36–39` gap and
returned ENOSYS, so agnsh couldn't launch programs in a container. This closes it, re-syncing mirshi to
the current agnos userland ABI.

### Added
- **`execwait#37` — EMULATE at the loop level** (`_do_execwait`, `src/intercept.cyr`). The fusion of the
  existing `spawn#3` fork machinery and `waitpid#4` parking: fork a traced grandchild that execve's the
  path token via `_child_exec` (the same path the root child takes — no memfd, since execwait's ELF is a
  real file), register it (caller = parent), then **park the caller** on the coined agnos pid until it
  exits; `_wake_waiters` injects the child's exit code as execwait's return. The cmdline `"PATH args.."`
  is staged NUL-split on the supervisor heap (inherited across the fork) and space-tokenized into the
  argv vector, argv[0]=path. Storm-bounded by `MAX_CHILDREN`; cmdline capped at 127 (matches agnos).
  Dispatched at the demux loop (`enr == 37`) alongside `spawn#3`/`waitpid#4`/`pause#14`/`kill#16`.
- **Behavioral smoke** `docker/tools/ewtest.cyr`: raw `syscall(37,"./hello",…)` runs the agnos `hello`
  ELF to completion under mirshi and confirms control returns with exit code 0. Verified end-to-end
  (`mirshi ./ewtest` → hello's output prints between ewtest's markers).
- Freeze contract + `docs/reference/syscall-coverage.md` updated: `#37` row moved from the undefined
  `#36–39` gap to **execwait / EMULATE**; the loop-level freeze assertion re-messaged. Full suite green
  (295 passed, 0 failed).

_Next in the exec-band re-sync: `spawn_path#43` (the stdlib `exec_*` path — `_agnos_spawn_path` +
`waitpid`), `exec_redirect#62` (agnsh `>` / pipes), `symlink#63`._

---

**argv forwarding — the root child gets its command line.** Before this, mirshi ran the target agnos ELF
with a hard-coded `argv = [path, NULL]` — **every argument past the ELF path was silently dropped**. Any
arg-taking tool (kii `<image>`, descent `serve <port>`, kriya subcommands, dig, cmdrs…) saw no arguments
and fell back to its usage/error path; iam was the only tool unaffected (it takes none). Surfaced by the
agnosticos **mirshi-fanout** vehicle running the ecosystem's real userland tools.

### Fixed
- **Root-child argv is now forwarded.** `main()` collects the trailing command line (`argv(i)…argv(n-1)`,
  where `i` is the target after mirshi's own flags) into a NULL-terminated vector built on the supervisor
  heap **pre-fork** (inherited across the fork like the net allow-list), and `intercept_run` →
  `_child_exec` hands it straight to `sys_execve` — replacing the hard-coded `[path, NULL]`. Verified end
  to end: `kii <image.png>` renders an 8 KB ANSI halfblock frame under mirshi (positional path forwarded);
  `kii --version` / `--width <n>` (flags forwarded). Backward-compatible — an arg-free tool (iam) still
  gets `[path, NULL]`.

### Unchanged (by design)
- **spawn#3 grandchildren stay `argv = [NULL]`** — agnos `spawn#3` passes no argv/envp; `_child_exec_memfd`
  is untouched. Only the root child (`_child_exec`) takes a command line.
- **envp stays `[NULL]`** — agnos userland reads no environment yet; revisit per a real consumer.

### Tests
- 295/0 unit assertions unchanged; the two exec-path integration gates (`scripts/it/m1_run.sh`,
  `scripts/it/m2_fs.sh`) stay green (their tools hardcode paths — arg-free — so they exercise the
  `[path, NULL]` case and confirm no regression).

## [1.9.0] — 2026-07-01

**tty sizing — direction 1 is feature-complete.** agnos `winsize#60` now runs: an agnos TUI sizes to the
real console under mirshi. This is the **entire direction-1 graphics surface** (there is no `fbinfo`/`blit`
in the agnos ABI), and its landing means **every defined, non-kernel-only agnos syscall is now handled** —
the only ENOSYS rows left are the agnos-kernel-only ops + the undefined ABI gaps
([ADR 0017](docs/adr/0017-winsize-emulated-tiocgwinsz.md)).

### Added
- **`winsize#60`** EMULATE: a pure supervisor return (no child buffer, like `uptime_ms#40`) — mirshi reads
  the controlling terminal's size via `TIOCGWINSZ` on its own stdio (the child inherits it) and returns
  `(cols<<16)|rows` (cols high, rows low — matching the kernel's `fb_winsize` packing and darshana's
  `tty_winsize` unpack). No tty → an 80×24 virtual default; **always returns a usable size** (faithful to
  real agnos, whose framebuffer is always up).
- **New gate**: `scripts/it/winsize.sh` — the no-tty default (→ 80×24) and a pty sized to 120×40
  (→ `TIOCGWINSZ` reports 120×40, proving the real read, not just the fallback; SKIPs without python3).
  CI-wired.

### Security
- **No child-seccomp delta** — the `ioctl(TIOCGWINSZ)` runs supervisor-side (the child never runs it);
  `winsize` carries no child buffer/pointer (no TOCTOU surface) and no path (`--root`-orthogonal).
  Adversarially reviewed clean — offsets/constants/packing verified against system headers **and the real
  darshana consumer**.

### Changed
- **Frozen matrix**: row #60 moves ENOSYS → **EMULATE ⁷** (tty sizing). `agnos_to_linux_nr(60)` stays −1
  (EMULATE, dispatcher-intercepted). With this, **direction 1 is feature-complete** — the matrix's only
  remaining ENOSYS rows are the agnos-kernel-only ops (`mount#11`/`umount#24`/`reboot#13`/
  `write_boot_checkpoint#26`) and the undefined gaps (#36–39, #42–44).
- **Toolchain pin → `6.3.27`** (`cyrius.cyml`) — synced to the current wrapper at the release boundary.

## [1.8.0] — 2026-07-01

**Info getters + advisory locks — the ENOSYS long-tail.** agnos `getuid#15` / `uname#34` / `sysinfo#35` /
`flock#59` now run: a general userland can read its identity + system stats and take advisory file locks.
The three info getters are **supervisor-emulated** (synthesized agnos-native structs — mirshi never leaks
host identity in the wrong shape); `flock` is **execute-in-child** (the host kernel's inode-keyed advisory
lock is exactly the agnos semantics) ([ADR 0016](docs/adr/0016-info-getters-emulated-flock-executed.md)).

### Added
- **`getuid#15`** (also `geteuid`, same #15) EMULATE → **0** — the agnos environment is always root.
- **`uname#34`** EMULATE: the agnos-NATIVE 64-byte identity struct (4×16 NUL-padded at 0/16/32/48 =
  `sysname="AGNOS"` / `nodename="agnos"` / `release="mirshi"` / `machine="x86_64"`), **not** Linux
  `utsname`. `len<64` → −1 (no partial fill).
- **`sysinfo#35`** EMULATE: the agnos-NATIVE 40-byte struct (5×u64 at 0/8/16/24/32 = `uptime_secs` /
  `totalram` / `freeram` / `procs` / `cpus`) from **live host values** — host Linux `sysinfo#99` for
  uptime + RAM (×`mem_unit`→bytes), `_child_count` for procs, `sched_getaffinity` popcount for cpus.
  `len<40` → −1.
- **`flock#59`** EXECUTE-in-child → Linux `flock(73)` (op codes bit-identical: `SH`/`EX`/`UN`/`NB`) — a
  real inode-keyed advisory lock on the child's fd.
- **New gates**: `scripts/it/flock.sh` (getuid/geteuid=0 + two-OFD `LOCK_EX` contention/release),
  `scripts/it/info.sh` (uname 4-field layout + sysinfo live-value ranges + both `len`-guards). CI-wired.

### Security
- **Sole child-seccomp delta: `flock(73)`** — the three info getters read supervisor-side, so they add
  **zero** child syscalls. `getuid`→0 never leaks the host uid; `uname`/`sysinfo` synthesize agnos-native
  structs, never the host `utsname`/`sysinfo` shape. Each band adversarially reviewed (getuid/flock:
  clean, incl. `flock` on an emulated id → EBADF→−1; sysinfo: clean, struct offsets probe-verified).

### Changed
- **Frozen matrix**: rows #15/#34/#35 move ENOSYS → **EMULATE ⁶**, #59 ENOSYS → **EXECUTE ⁶** (`flock`).
  The freeze test's `agnos_to_linux_nr` values: #15/#34/#35 stay −1 (dispatcher-intercepted); #59 gains
  `→73` (a real execute-in-child peer).
- **Value assumptions** (ADR 0016, revisit per a real consumer): `uname.release="mirshi"` (vs the kernel's
  `_AGNOS_VERSION`), `sysinfo.procs` = live count (vs the kernel's high-water).
- **Toolchain pin → `6.3.26`** (`cyrius.cyml`) — synced to the current wrapper at the release boundary.

## [1.7.0] — 2026-07-01

**I/O multiplexing — the event loop.** agnos `epoll#19–21` / `timerfd#22–23` / `pipe#25` now run: a server
multiplexes a `timerfd`, a `signalfd`, and a socket on one `epoll` set and wakes on whichever fires. epoll
and timerfd are **supervisor-emulated** (a server epolls sockets + signalfds, which aren't real child fds, so
a real in-child epoll couldn't see them); pipe is **execute-in-child** (a real Linux pipe, the only
agnos-reachable use being intra-process). ([ADR 0015](docs/adr/0015-io-mux-emulated-epoll-timerfd-executed-pipe.md)).

### Added
- **`pipe#25`** (execute-in-child): rewritten to Linux `pipe2(O_CLOEXEC)` run in the child; the exit stop
  widens the two i32 host fds into the agnos `{u64 read; u64 write}` (16 B). The read/write ends are real
  child fds, so `read#5`/`write#1`/`close#6` on them ride the existing execute-in-child path.
- **`timerfd#22`/`#23`** (`src/dispatch.cyr`): a supervisor-side **`CLOCK_MONOTONIC` deadline** (per-child
  8-slot table, no real Linux timerfd). `settime` arms it (seconds; capped at `TIMERFD_SEC_CAP`); `read#5`
  delivers the u64 expiration count (deliver-then-consume, re-arm/disarm) once the deadline passes, else −1.
- **`epoll#19`/`#20`/`#21`**: a per-child epoll instance (4 instances × an 8-watch list of raw agnos ids).
  `epoll_ctl` op 1=ADD (dedup, first-empty, negative-reject, 8-cap) / op 2=CLEAR (whole list). `epoll_wait`
  is a **heterogeneous bounded-yield readiness engine** — `ppoll` the supervisor-held socket host fds +
  mask-test signalfds + clock-test timerfds, merge, write packed 12 B `{u32 EPOLLIN; u64 raw-id}` events.
  Never parks (a readiness event has no `wait4` wake source).
- **Tag ladder + pure helpers** (`src/children.cyr`): `TIMERFD_BASE`/`EPOLL_BASE`/`PIPE_BASE` (bit-30-clear,
  descending below `SIGFD_BASE`) + `MIN_EMU_BASE`; the pure, unit-pinned `_emu_classify` (tier an id by tag)
  and `_timer_ticks`; a `read#5`/`close#6` `>= MIN_EMU_BASE` front gate that sub-routes to each band. The
  per-child record grew to hold `C_EPOLL_TBL` / `C_TIMERFD_TBL` (+ a reserved `C_PIPE_TBL`).
- **New gates**: `scripts/it/pipe.sh`, `timerfd.sh`, `epoll.sh`, `epoll_wait.sh` (the heterogeneous
  timerfd+signalfd wake — the roadmap gate — plus best-effort socket-watching). All CI-wired.

### Security
- **Sole child-seccomp delta: `pipe2` (293)** — epoll + timerfd add **zero** child syscalls (all
  supervisor-side). A bad `pipe#25` `fds_ptr` is **write-probed at the enter stop** so it fails clean with no
  fd leaked (the net band's fail-clean discipline). `timerfd_settime` rejects negative + caps huge seconds so
  `sec·1000` can't overflow into a wrong timer. Each band was adversarially reviewed (pipe: 1 fd-leak MINOR
  found + fixed; timerfd: 1 overflow MINOR found + fixed; epoll create/ctl + epoll_wait: clean).

### Changed
- **Frozen matrix**: rows #19–23 move ENOSYS → **EMULATE ⁵**, #25 ENOSYS → **EXECUTE ⁵** (`pipe2`). The
  freeze test's `agnos_to_linux_nr` values stay pinned (all intercepted before the mapper; `pipe#25` stays −1).
- **Socket-watching is best-effort** — a coordinated agnos-kernel + mirshi-shim fix for the guest/mirshi
  socket-slot divergence lands later (documented, wait-time `SLOT_FREE`-revalidated). ADR 0015.
- **Toolchain pin → `6.3.25`** (`cyrius.cyml`) — synced to the current wrapper at the release boundary.

## [1.6.0] — 2026-07-01

**Signals — the shell's other half.** agnos `pause#14` / `kill#16` / `sigprocmask#17` / `signalfd#18`
now run: a process sends a signal to itself or a direct child, masks signals, and reads deliveries via a
`signalfd` — the notification half of job control that pairs with v1.5.0's `spawn`/`waitpid`. The agnos
signal model is **signalfd-centric with no async `sa_handler`**, so the whole band is supervisor-emulated
over the v1.5.0 record table — no real host signals, no real host fds
([ADR 0014](docs/adr/0014-signal-band-supervisor-emulated-masks-signalfd.md)).

### Added
- **Pending / blocked masks** (`src/children.cyr`): each child record carries a **pending** mask
  (`C_PENDING_SIG`, the field reserved in v1.5.0) and a **blocked** mask (`C_SIG_BLOCKED`), both in the
  agnos `1<<sig` convention (bit N = signal N — **not** libc's `1<<(sig-1)`). Pure, unit-pinned helpers
  `_sig_valid` (1..63) / `_sig_bit` / `_sig_deliverable` (`pending & ~blocked`) / `_sig_lowest` /
  `_sig_clear` (`~x` via the `0-x-1` identity — Cyrius has no unary `~`).
- **`kill#16`** (`_do_kill`, loop-level): OR `1<<sig` into the **target's** pending mask;
  **self-or-direct-child** scope only, pid 0 protected, `sig ∈ 1..63`. Killing an exited-but-unreaped
  child is a harmless no-op.
- **`pause#14`** (`_do_pause`, loop-level): a **bounded yield** — returns 0 immediately if a deliverable
  signal is pending, else idles one supervisor quantum (1 ms) then returns 0. Never blocks forever.
- **`sigprocmask#17`** (`_do_sigprocmask`): `SIG_BLOCK` / `SIG_UNBLOCK` / `SIG_SETMASK` over the caller's
  blocked mask, with the previous mask written to `oldset` (reads `set` first, so `oldset == set` aliasing
  is safe).
- **`signalfd#18`** (`_do_signalfd`) + **`read#5` delivery** (`_sigfd_read`): `signalfd` returns an
  opaque `SIGFD_BASE + slot` fd indexing a per-child 8-slot signalfd table (`{watched_mask, flags}`); a
  `read` on it delivers the lowest `pending & watched & ~blocked` signal as an **8-byte number** (returns
  8), else agnos −1 (non-blocking). `read#5` gains a one-compare `fd >= SIGFD_BASE` branch.
- **New gate**: `scripts/it/signals.sh` — kill scope (self/child 0; pid0/badsig/unknown/cross-tree −1),
  pause bounded yield, sigprocmask oldset round-trip, and the full `kill → signalfd read` delivery chain
  incl. the signal-loss regression. CI-wired after `net_icmp` / the v1.5.0 gates.

### Security
- **`SIGFD_BASE = 0x20000000`, bit 30 clear** — the agnos userland tags its own **socket** fds with
  `AGNOS_SOCK_TAG = 0x40000000` (bit 30) and routes bit-30 fds to the net band **before** the syscall; a
  signalfd id with bit 30 set would be swallowed as a socket and never reach `read#5`. Bit 29 avoids the
  collision (found + fixed during bring-up).
- **Bounded-yield `pause` — anti-wedge**: `_agnos_sock_recv_block` (the TLS/HTTP blocking read) polls a
  non-blocking `sock_recv` and yields via `pause`; a block-forever `pause` would wedge every such read.
  The 1 ms bounded yield protects it and — never parking `CS_BLOCKED` — leaves the v1.5.0 deadlock guard
  untouched.
- **Deliver-then-consume** (`_sigfd_read`): the pending bit is cleared **after** a successful delivery
  write, so a failed child-buffer write never loses the signal (adversarial-review finding + regression
  test). The signal band was reviewed for signal-loss, mask aliasing, and fd-tag collision — all fixed.

### Changed
- **Frozen matrix**: rows #14/#16/#17/#18 move ENOSYS → **EMULATE ⁴** (signals). They are intercepted at
  the loop level / dispatcher **before** `agnos_to_linux_nr`, so the freeze test's values stay pinned
  (still −1, "no peer").
- **Toolchain pin → `6.3.23`** (`cyrius.cyml`) — synced to the current wrapper at the release boundary.

## [1.5.0] — 2026-07-01

**Multi-process — the agnsh crown jewel.** agnos `spawn#3` / `waitpid#4` / `getpid#2` now run: a
parent spawns children from in-memory ELF images and waits their exit codes, to arbitrary depth, all
under one supervisor. mirshi grows from a single-child tracer into a small process tree
([ADR 0013](docs/adr/0013-multiprocess-supervisor-fork-record-table.md)).

### Added
- **Multi-tracee supervisor** (`src/intercept.cyr`): `_trace_run` is now a `wait4(-1, __WALL)` demux —
  it services one ptrace stop per iteration keyed on a per-child record, resumes that child, and
  returns only when the root exits. Single-stop-per-iteration keeps dispatch non-reentrant, so the
  pure staging buffers stay shared; only the enter→exit carry + the net-slot table went per-child.
- **Per-child record table** (`src/children.cyr`): a fixed `MAX_CHILDREN=16` lazy-alloc-once table
  (pid mapping, state, exit code, wait target, `needs_attach`, the carry, the net table).
- **`spawn#3`** (`_do_spawn`): supervisor reads the caller's in-memory ELF (`process_vm_readv`,
  bounds-checked to `SPAWN_ELF_MAX=8 MB`), stages it into a `memfd`, `fork`s a traced grandchild that
  runs the same rlimits/rootfd/seccomp gauntlet then `execveat(memfd, AT_EMPTY_PATH)`, and injects a
  coined agnos pid. **Not** `PTRACE_O_TRACEFORK` (the child never forks); the fork stays
  supervisor-side, so the child seccomp bound grows by **only** `execveat`.
- **`waitpid#4`** (`_do_waitpid`): parks the caller *stopped* (not the supervisor) until the target
  exits, then injects its exit code; an already-exited target is claimed via a zombie fast-path;
  unknown/reaped → −1. The `WIFEXITED` handler wakes parked waiters and frees the slot.
- **`getpid#2`** EXECUTE→EMULATE: returns the caller's coined agnos pid (root=1) instead of host
  `getpid#39`, so each process sees *its* pid (matching what spawn returns).
- **New gates**: `scripts/it/spawn.sh`, `waitpid.sh`, `getpid.sh`, `spawn_storm.sh` (fork-storm cap +
  no-leak + 3-level grandchild depth). All CI-wired.

### Security
- **Process-storm bound**: flipping `spawn#3` to EMULATE reopens the process-exhaustion vector
  ([ADR 0006](docs/adr/0006-host-resource-bounds-child-rlimits.md) had closed it via the child bound +
  spawn=ENOSYS). Re-closed by the `MAX_CHILDREN` cap, checked before each fork (never `RLIMIT_NPROC` —
  per-uid + container-hostile). **Deadlock guard**: a self-wait / wait-cycle can't wedge the
  single-threaded supervisor — parked waiters are failed to −1 rather than blocking `wait4(-1)` forever.
  `spawn#3` + `waitpid#4` were adversarially reviewed (fd/memfd leaks, use-after-free of slots,
  lost-wakeups, privilege — all clean; the deadlock wedge was found and fixed here).

### Changed
- **Frozen matrix**: rows #2/#3/#4 move ENOSYS/EXECUTE → **EMULATE ³** (multi-process). The freeze
  test's `agnos_to_linux_nr` *values* stay pinned (these are intercepted at the loop level / dispatcher,
  before it); `getpid#2` drops its `→39` peer. The `alloc_clean` gate's EXECUTE representative moved
  from getpid#2 to the bufferless `time_unix#46`.
- **Pid model** ([ADR 0013](docs/adr/0013-multiprocess-supervisor-fork-record-table.md)): opaque
  monotonic agnos pids (root=1, never reused), a two-way guest↔host mapping — bidirectional-ready for
  the v2+ swallow. Known limits documented: head-of-line blocking (`sleep`/blocking I/O), 8-bit exit
  truncation, deadlock-break-to-−1.
- **Toolchain pin → `6.3.22`** (`cyrius.cyml`) — synced to the current wrapper at the release boundary.

## [1.4.0] — 2026-06-30

**Net band — ICMP (the arc's finale).** agnos `icmp_echo#55` (yo/ping) now round-trips through
mirshi via an **unprivileged** ping socket, completing the sovereign net band (#47–57, #61).
Supervisor-emulated ([ADR 0012](docs/adr/0012-net-band-supervisor-emulated-conn-table.md)).

### Added
- **`icmp_echo#55`** (`src/dispatch.cyr`, `_net_icmp`): a **pure** supervisor op (no child buffer)
  — egress-check → open an **unprivileged** socket (`SOCK_DGRAM`+`IPPROTO_ICMP`, **never**
  `SOCK_RAW`/`CAP_NET_RAW`) → send one echo request → **bounded `ppoll(POLLIN)`** (~3s) for the
  reply, returning the monotonic-clock RTT in ms (≥0; a sub-ms reply reads 0). Fail-closed to −1 on
  any error (socket denied by `net.ipv4.ping_group_range`, send failure, timeout). New helper
  `_mono_ms` (monotonic ms, reuses the timer scratch). dst_ip is the agnos kernel-ip4 form.
- **New gate**: `scripts/it/net_icmp.sh` — an agnos client pings 127.0.0.1 under mirshi (RTT ≥ 0)
  and proves per-destination egress; **SKIPs gracefully** where the kernel forbids unprivileged
  ICMP (`ping_group_range` / sandbox). CI-wired. (Live-verified: `icmp_echo(1.1.1.1)` = 6 ms vs the
  host's own `ping` = 6.48 ms.)

### Security
- `icmp_echo#55` is **egress-checked** (`--net-allow`, default-deny) before the socket, and uses
  **only** the unprivileged datagram-ICMP path — a privilege a sandbox-class deputy must not hold
  or grant. The handler was adversarially reviewed (no fd leak on any exit path, fail-closed).

### Changed
- **Frozen syscall-coverage contract**: `icmp_echo#55` moves ENOSYS → **EMULATE ²**
  (`docs/reference/syscall-coverage.md`) — the **net band is now complete**, no net-band number
  (#47–57, #61) remains ENOSYS.
- **Toolchain pin** stays `6.3.16` (`cyrius.cyml`) — the wrapper is unchanged at this release
  boundary, so no drift to reconcile.

## [1.3.0] — 2026-06-30

**Net band — UDP + net_config.** agnos UDP tools (dig/DNS-class) can now send + receive datagrams
through mirshi, and `net_config#61` exposes the real container-netns config — so a ring-3 resolver
can target the on-subnet DNS. Supervisor-emulated over the same slot table ([ADR 0012](docs/adr/0012-net-band-supervisor-emulated-conn-table.md)).

### Added
- **UDP** (`src/dispatch.cyr`): `udp_bind#51` (a bound non-blocking DGRAM socket, `SLOT_UDP`, the
  bound port stashed so `udp_send` can find it), `udp_send#52` (**per-datagram egress check** →
  `sendto` from the socket bound to the packed source port), `udp_recv#53` (`recvfrom` + the
  **sender `addr_out` repack** `{ip@0, port@8}`, no EOF inversion — UDP has none), `udp_unbind#54`.
  Ingress loopback-default like TCP listen (`--net-listen-any` binds all interfaces).
- **`net_config#61`** (`src/dispatch.cyr`): a supervisor EMULATE getter that reads the **real
  container-netns config** — field 2 (gateway) from `/proc/net/route`, field 3 (DNS) from
  `/etc/resolv.conf`, field 0 (host IP) via a `getsockname` trick; field 1 (netmask) is 0-unset;
  a bad field → −1; any missing file / parse failure → 0 (unset). `--net`-gated. Minor infoleak
  (the child sees the container's gateway/DNS), accepted.
- **Pure parsers** (`src/translate.cyr`, +7 unit assertions): `net_parse_dotquad` (dotted-quad →
  kernel-ip4) and `net_parse_hex32` (the `/proc/net/route` little-endian gateway hex).
- **New gates**: `scripts/it/net_udp.sh` (an agnos UDP round-trip against a python echo server,
  verifying the payload **and** the `addr_out` `{ip,port}` + per-datagram egress denial) and
  `scripts/it/net_config.sh` (mirshi's gateway/DNS compared against the environment's own files).
  Both CI-wired.

### Security
- UDP `udp_send#52` is **egress-checked per datagram** (`--net-allow`, default-deny) — the dst can
  change every call, so each is re-checked (SSRF-hardened, same policy as TCP connect). The UDP +
  net_config handlers were adversarially reviewed (no fd/slot leak, OOB, buffer over-read, or crash).

### Changed
- **Toolchain pin → `6.3.16`** (`cyrius.cyml`) — synced to the current wrapper at the release boundary.

## [1.2.0] — 2026-06-30

**Net band — TCP server.** agnos server tools can now accept inbound TCP connections through
mirshi: `sock_listen#56` / `sock_accept#57`, supervisor-emulated over the same conn_id slot
table as the client. Safe-by-default ingress posture ([ADR 0012](docs/adr/0012-net-band-supervisor-emulated-conn-table.md)).

### Added
- **Net band TCP server** (`src/dispatch.cyr`): `sock_listen#56` merges bind+listen (a supervisor
  non-blocking listening socket, `SO_REUSEADDR`); `sock_accept#57` `accept4`s the next connection
  into a fresh `SLOT_CONN` whose `parent` is the listener (so `sock_close#50` on a listener **reaps
  its accepted children** — the agnos 1.45.6 semantic). The slot table became a unified 8-slot
  `{fd, kind, parent}` space (conn / listen), so `close#50(id)` is unambiguous; send/recv now
  require a live `SLOT_CONN` (can't operate on a listener).
- **`--net-listen-any`** (`src/main.cyr`): `sock_listen` binds **all interfaces** (the faithful
  agnos behavior, network-exposed); the default binds **loopback only** — the safe ingress default
  (a sandboxed child's server is reachable only from localhost / the same container).
- **New gate** `scripts/it/net_server.sh`: an agnos server (listen/accept/recv/send/close-reap)
  accepts a real python client and replies, verified in **both** bind modes. CI-wired.

### Security
- **Ingress default-loopback** ([ADR 0012](docs/adr/0012-net-band-supervisor-emulated-conn-table.md)):
  a sandboxed child's listening socket is bound to loopback unless `--net-listen-any` is passed,
  so the new inbound surface is not network-exposed by default (mirrors the egress default-deny
  posture). The server + reap-children handlers were adversarially reviewed (no fd/slot leak,
  double-close, cross-close, or OOB; the reap invariant is pinned in a code comment).

## [1.1.0] — 2026-06-30

**Net band — TCP client (the first post-v1 expansion).** agnos net tools can now open TCP
connections through mirshi: a sandboxed agnos child reaches the network via a
**supervisor-emulated** socket layer, egress-confined by a default-deny policy. Architecture +
security fixed in [ADR 0012](docs/adr/0012-net-band-supervisor-emulated-conn-table.md). Scope:
TCP client (`sock_connect#47`/`send#48`/`recv#49`/`close#50`); TCP server, UDP, ICMP, and
`net_config#61` follow in v1.2.0–v1.4.0.

### Added
- **Net band TCP client** (`src/dispatch.cyr`) — **supervisor-EMULATE**: the supervisor owns the
  sockets via an 8-slot `conn_id(0..7) → host fd` table; the child only ever sees the opaque
  conn_id, never a real socket fd; the child seccomp allowlist is **unchanged** (socket syscalls
  run supervisor-side; the emulated `-1` skip-sentinel is already allowed). `connect#47` does
  `socket`+non-blocking-`connect`+bounded `ppoll`/`SO_ERROR`; `send#48` pvm-stages the child buffer
  → `sendto` (**`MSG_NOSIGNAL`** so a closed peer can't SIGPIPE the supervisor); `recv#49`
  `recvfrom MSG_DONTWAIT` → the **inverted-EOF** mapper → pvm-writes the child buffer; `close#50`
  frees the slot. Chosen over execute-in-child to avoid a rip-rewind loop change (ADR 0002's
  rejected pattern) and keep the fd + egress choke point supervisor-side.
- **`--net` / `--net-allow <cidrs>`** (`src/main.cyr`) — opt-in to the net band + the egress policy;
  the policy is **validated fail-closed before fork** (malformed → refuse to run). Pinned by `cli.sh`.
- **Pure, unit-pinned net translation** (`src/translate.cyr`, +~50 assertions): `net_htons`,
  `net_ip4_to_inaddr` (the kernel-ip4 → `sin_addr` byte-swap the agnos side expects), `build_sockaddr_in`,
  the **inverted `recv#49` EOF** mapper `net_recv_to_agnos` (`0`=Linux-EOF→agnos `-1`, `-EAGAIN`→agnos
  `0`=WOULD_BLOCK — a naïve reuse of the fs mapper spins agnos poll-loops forever), and the **egress
  policy** (`net_parse_allow`/`net_in_cidr`/`net_reserved_min_prefix`/`net_egress_ok`).
- **New gates**: `scripts/it/net_client.sh` (connect/close + egress enforcement, incl. connect-failure)
  and `scripts/it/net_io.sh` (an agnos HTTP-GET round-trip proving send/recv + the inverted-EOF
  end-to-end). Both CI-wired.

### Security
- **Default-deny egress** ([ADR 0012](docs/adr/0012-net-band-supervisor-emulated-conn-table.md)):
  `--net-allow` is required to reach any destination; **SSRF-hardened** — a broad `0.0.0.0/0` does
  **not** implicitly expose metadata/RFC1918/loopback (only a sufficiently-specific allow does),
  enforced in the supervisor on the decoded `dst_ip` before the socket, fail-closed to agnos `-1`.
  **Brute-force-verified**: an exhaustive all-2³² sweep of the `0.0.0.0/0` policy — every public IP
  allowed, every reserved IP denied, zero misclassifications. The socket/send/recv handlers were
  adversarially reviewed (no fd/slot leak, OOB, double-close, SIGPIPE-kill, or overflow).

### Changed
- **Toolchain pin → `6.3.15`** (`cyrius.cyml`) — synced to the current wrapper at the release boundary.

## [1.0.0] — 2026-06-30

**The clean cut: AGNOS userland in Docker, no QEMU (direction 1, headless CLI).** A
representative agnos CLI userland runs as native Linux processes under mirshi's syscall
translation in a plain `FROM scratch` Docker container — shared host kernel, no full-system
emulation — fan-out-ready and seccomp-bounded. The v1 definition is met and proven end-to-end.
The 0.6→0.9 quality arc (hardened · audited · confined · optimized · frozen) lands here as a
stable foundation; no translation-logic change in this cut. Registry publishing is a
documented post-v1 ops step (see the fan-out guide), not gated by the v1 definition. Net band
(#47–57), multi-process, graphics, and the Linux→AGNOS swallow remain post-v1.

### Added
- **`docker/tools/cp.cyr`** — a `cp` write-path demo tool: copies `/data/motd.txt` →
  `/data/out.txt` (`open AO_CREAT|AO_WRONLY` + `write`) then reads the copy back to stdout,
  exercising the M2 filesystem **write/create** path end-to-end in-container — the one part
  of the frozen fs surface the read-only tools (`catfile`/`ls`) didn't show.

### Changed
- **`docker/smoke.sh`** now asserts the full representative userland in-container: console
  out (`hello`), stdin echo (`echo`), fs read (`catfile`), dir listing (`ls`, getdents), and
  the fs **write** path (`cp`) — previously only `hello` + `catfile` were asserted (the others
  were built but unproven). Plus the existing no-QEMU proof + 4-container fan-out.
- **Toolchain pin → `6.3.14`** (`cyrius.cyml [package].cyrius`) — synced to the current
  `cycc`/`cyrius` wrapper (proven good: it builds the green smoke + 166-assertion suite),
  clearing the pin-drift warning for the v1 cut.

## [0.9.0] — 2026-06-30

Freeze + docs cleanup — no behavior change. Froze the v1 contracts (the per-number syscall-
coverage matrix + the CLI), promoted the mirshi/QEMU/iron boundary discipline to a cited ADR,
and consolidated the docs before the v1.0.0 cut. No `src/*.cyr` logic changed.

### Docs
- **Frozen translation-table contract** — [`docs/reference/syscall-coverage.md`](docs/reference/syscall-coverage.md):
  the canonical, exhaustive per-number (agnos 0–61) AGNOS→Linux matrix — disposition
  (EXECUTE / EMULATE / EXIT / ENOSYS), the Linux peer, the `--root` re-anchored peers, the
  arg/return notes, the runnable v1 surface, and the carried-forward gaps. Mirrors the code
  and is **pinned by tests** (`tests/mirshi.tcyr` `xlat-coverage`: every agnos# 0–61's
  disposition exhaustively asserted → 166 total). Adversarially audited row-by-row vs the code.
- **Frozen CLI contract** — [`docs/reference/cli.md`](docs/reference/cli.md): the synopsis,
  flags (`--selftest-trace` / `--no-seccomp` / `--root <dir>`), modes, streams, and the
  exit-code map (child code / `128+sig` / `2` usage / `125` wait / `126` bound / `127` execve).
  Pinned by `scripts/it/cli.sh` (usage on misuse + `EXECVE_FAILED`), wired into CI.
- New `docs/reference/` section (frozen contracts); indexed in `CLAUDE.md`.
- **Boundary discipline ADR** — [ADR 0011](docs/adr/0011-mirshi-qemu-iron-boundary-discipline.md):
  the load-bearing rule that mirshi *complements, never replaces* QEMU+KVM (real agnos kernel)
  + iron (hardware truth), with the per-surface bug-class ownership table — promoting the
  discipline from CLAUDE.md/roadmap prose to a cited decision (closes the "boundary-vs-QEMU"
  + "discipline doc" 0.9.0 items). Linked from the roadmap's discipline note.
- **Guides cross-linked** to the frozen contracts: `getting-started.md` gains a "Run an agnos
  binary" section pointing at `reference/cli.md` + `reference/syscall-coverage.md`. (Verified
  current — build/test commands, the ptrace recipe, and `--no-seccomp` are all accurate.)

## [0.8.0] — 2026-06-30

Optimizations — measure-first hot-path work. The per-syscall cost model is dominated by the
two `PTRACE_SYSCALL` stops (irreducible under ptrace); the byte-identical lever is trimming
the register I/O within those stops. Ships the exit-stop single-register I/O (~5–7 % off the
syscall-dense tax), the 0-alloc-per-syscall gate, and the honest cost-model reconciliation —
no transparent pass-through fast-path exists in direction 1, and the seccomp-notify hybrid
stays deferred-by-data, so **ptrace is the documented default** (superseding two aspirational
roadmap lines).

### Performance
- **Exit-stop single-register I/O** ([ADR 0010](docs/adr/0010-ptrace-exit-stop-single-register-io.md)):
  the `PTRACE_SYSCALL` exit stop now reads only `rax` via `PTRACE_PEEKUSER` (8 bytes) and
  writes it back via `PTRACE_POKEUSER` **only when the agnos return differs** from the raw
  kernel return — replacing the old `GETREGS` + unconditional `SETREGS` (two 216-byte
  register copies). The syscall-dense success path costs one 8-byte peek and no write-back at
  all (getpid/read/write/lseek/mmap/getrandom returns pass through unchanged; `stat` success
  stays 0 with its output already repacked into child memory). **Byte-identical** to 0.7.1
  (at a syscall-exit the supervisor only ever wrote `rax`); A/B vs HEAD measured ~5–7 % off
  the per-syscall tax on syscall-dense workloads (getpid −5.4…6.6 %, getrandom −6.9 %),
  negligible on buffer-heavy ones. The enter stop stays full-register (it rewrites
  `orig_rax` + 5–6 arg registers). See [docs/benchmarks.md](docs/benchmarks.md).

### Changed
- **Toolchain pin → `6.3.12`** (`cyrius.cyml [package].cyrius`, the source of truth) — synced
  to the current `cycc`/`cyrius` wrapper, clearing the pin-drift build warning.

### Tests
- **0-alloc-per-syscall gate** (`scripts/it/alloc_clean.sh`, the roadmap's named 0.8.0
  acceptance): asserts the supervisor's per-syscall hot path allocates **nothing** per
  translated call — mirshi's bump allocator never frees, so any per-call `alloc` is linear
  RSS growth under a storm. Storms the EXECUTE pass-through (getpid#2) and fs path-staging
  (stat#33) classes and asserts mirshi's RSS stays flat (delta 0 kB observed), complementing
  `supervisor_hardening.sh`'s emulate-path (uptime#40) heap-bound check. Teeth-verified (a
  materialized per-call `alloc(16)` grows RSS ~2.7 MB and trips the gate). Wired into CI.

## [0.7.1] — 2026-06-30

Supervisor rootfs confinement — the path-escape blocker fix (audit class-(c)), bites
1+2+3. `--root <dir>` confines the child's filesystem kernel-enforced + unprivileged;
the audit's class-(c) blocker tier is closed (confined under `--root` for the bare CLI,
namespace-bounded for the container vehicle).

### Security
- **`--root <dir>` rootfs confinement** ([ADR 0009](docs/adr/0009-rootfs-confinement-openat2-in-child.md)):
  with `--root`, mirshi confines the child's filesystem to `<dir>`, kernel-enforced,
  unprivileged, TOCTOU-safe.
  - **bite 1 (`open`)** — `open#7` → **`openat2` with `RESOLVE_IN_ROOT`** anchored at a
    per-child rootfd (opened `O_PATH|O_DIRECTORY`, `dup3`'d to a fixed fd, fail-closed if
    it won't open), so the kernel **clamps** absolute paths, `..` traversal, and symlink
    targets inside the root. Every fd-based op (`read`/`write`/`lseek`/`dup`/`close`/
    `getdents`) is transitively confined (its fd came from a confined open).
  - **bite 2 (path mutation/metadata)** — `mkdir`/`rmdir`/`unlink`/`rename`/`link`/`stat`
    → the `*at` family anchored at the rootfd, with the path **lexically sanitized**
    (`sanitize_rootrel`: strip leading `/`, reject any `..` component) since `*at` has no
    `RESOLVE_*`. So under `--root` no path string reaches the kernel unconfined.
  - **bite 3 (hardening)** — `RESOLVE_NO_MAGICLINKS` added to the `open` resolve, blocking
    proc magic-links (`/proc/*/root`, `/proc/*/fd/N`) that could jump out of a bare-CLI
    jail containing `/proc`. The Docker vehicle needs no `--root` — its mount namespace
    already confines every path to the container image.
  Without `--root`, transparent pass-through is unchanged (a loud warning prints in run
  mode); the container mount namespace remains the boundary for the v1 vehicle. New gate
  `scripts/it/confine.sh` (self-validating: proves the escape leaks without `--root`,
  then that `--root` clamps open + mutation escapes while in-root ops work); the pure
  `sanitize_rootrel` is unit-tested (16 assertions).

## [0.7.0] — 2026-06-30

Security CVE / 0-day sweep — audit + hardening (phased: the path-escape confinement is
0.7.1). seccomp **proven default-deny**; TOCTOU safe-by-design; the path-escape blocker
tier is bounded by the container mount namespace in the v1 vehicle pending 0.7.1.

### Added
- **Security audit** ([docs/audit/2026-06-30-audit.md](docs/audit/2026-06-30-audit.md)):
  a 32-finding adversarial sandbox-escape sweep across the four escape classes +
  supervisor integrity. **seccomp proven default-deny**; TOCTOU **safe by design**
  (single-threaded ptrace-stopped child); `mmap` synthesis confirmed hardened (no
  PROT_EXEC/MAP_FIXED/file-backed). The **blocker tier is entirely class-(c)
  path-escape** — mirshi has no in-supervisor path confinement, so a bare-CLI child
  reaches arbitrary host paths (confirmed by PoC). Bounded by the container mount
  namespace in the v1 (Docker) vehicle; the supervisor-side **rootfs confinement** fix
  is the next milestone (0.7.1).

### Security
- **Fail-closed bound** (`src/intercept.cyr`, `src/seccomp.cyr`): if the bounding
  seccomp filter cannot be installed in bounded mode, mirshi now **aborts the child**
  (exit 126) instead of running it unconfined; filter `alloc()`s are guarded (audit b1).
- **x32-ABI mask** (`src/seccomp.cyr`): the filter rejects any `nr >= 0x40000000`
  (`__X32_SYSCALL_BIT`, the emulate/ENOSYS skip sentinel excepted), closing the x32
  number-alias gap and completing the default-deny proof (audit b2).
- **Least-privilege create modes** (`src/translate.cyr`): `open#7` 0644 → **0600**,
  `mkdir#9` 0777 → **0700** — a sandboxed child's created files are not world-readable
  by default (audit d).

## [0.6.0] — 2026-06-30

Hardening: the supervisor against a misbehaving / hostile child. Supervisor stable +
host untouched across the fault-injection harness; host-resource bounds enforced;
signal handling and child-hang robustness closed.

### Added
- **Host-resource bounds** (`src/limits.cyr`): kernel-enforced rlimits set on the
  child before `execve` cap the two exhaustion vectors reachable through the
  translated surface — `RLIMIT_AS` = 1 GiB bounds an `mmap#27` storm, `RLIMIT_NOFILE`
  = 256 bounds an `open#7` / `dup#8` storm. A storm degrades to the agnos failure
  sentinel (`mmap#27` → 0, `open#7`/`dup#8` → -1), never a supervisor crash or host
  OOM. Set after `PTRACE_TRACEME`, before the seccomp filter (so `prlimit64` needs no
  allowlist entry and the child can't raise its own limits); always on, independent
  of `--no-seccomp`. The PID/process vector needs no rlimit — the seccomp allowlist
  has no `clone`/`fork` and `spawn#3` is `ENOSYS`, so a process storm is structurally
  impossible. [ADR 0006](docs/adr/0006-host-resource-bounds-child-rlimits.md).
- **Fault-injection harness wired into CI** (`scripts/it/fault_inject.sh`): the 0.6.0
  hardening gate now runs in CI (after the M2 step). Adds a memory-exhaustion
  (`mmap#27` storm) and an fd-exhaustion (`open#7` storm) case to the existing
  bad-pointer / SIGSEGV / unknown-syscall / syscall-storm / spawn cases; all assert
  the supervisor stays stable and the host is untouched.
- **Group-stop signal handling** (`src/intercept.cyr`): both trace loops now
  discriminate a ptrace **group-stop** (a stopping signal — `SIGSTOP`/`SIGTSTP`/
  `SIGTTIN`/`SIGTTOU`) via `PTRACE_GETSIGINFO` and **suppress** it (resume the child
  with no signal) instead of blindly re-injecting the stop — the ptrace-correct
  restart of a group-stopped tracee. Genuine signal-delivery stops are still
  forwarded. This is protocol-correctness + cross-kernel robustness, not a fix for an
  observed hang: on Linux the child runs whether the stop is suppressed or
  re-injected. New regression gate `scripts/it/groupstop.sh` (external `SIGSTOP` →
  child must run to completion, mirshi must not die with it stuck).
  [ADR 0007](docs/adr/0007-group-stop-signal-handling.md).
- **Child-hang robustness** ([ADR 0008](docs/adr/0008-child-hang-supervisor-robustness.md)):
  a hung child (blocked or spinning) was scoped empirically and found **handled by
  design** — correct block-mirroring, `PTRACE_O_EXITKILL` reaping the child on any
  supervisor death (no orphan/zombie, verified even in the `fork`→attach window), and
  no deadlock; **no internal watchdog** is added (it would wrongly kill a legitimately
  long-running tool). The scoping surfaced one real gap, now fixed: the dispatcher
  `alloc()`d a 16-byte timespec **per call** for the emulated timers `uptime_ms#40` /
  `sleep_ms#41`, so a child looping one grew mirshi's heap unbounded (a child-driven
  supervisor-OOM) — hoisted to a one-time static buffer (`_emu_ts_buf`), RSS now flat
  under the storm. New regression gate `scripts/it/supervisor_hardening.sh`
  (heap-bound under an emulate-timer storm + no-orphan/zombie on terminate-mid-hang).

### Changed
- **Fault-harness zombie check** (`scripts/it/fault_inject.sh`): scans all defunct
  processes by fixture command name (anchored) instead of `--ppid $$`, which could
  never see mirshi's agnos child — a *grandchild* of the harness reparented to PID 1
  if orphaned.

## [0.5.0] — 2026-06-29

M4 — seccomp-notify feasibility + benchmark baseline (the full migration reframed).

### Added
- **Benchmark baseline** — `scripts/bench/bench_syscall.sh` (mechanism-agnostic:
  a `seccomp-notify` row slots in unchanged later) + `docs/benchmarks.md`. The
  ptrace path measures **~30 µs per trapped+translated syscall** (~100× native on
  a `getpid` storm, but only ~5× native on a realistic `cat` of a 4 MB file — the
  per-syscall tax dominates only syscall-dense work). Wired as a non-gating CI step.
- [ADR 0005](docs/adr/0005-seccomp-notify-feasibility.md) — the durable finding
  that seccomp-notify **cannot renumber a syscall** (its response is
  `{id,val,error,flags}`) and therefore cannot do `mmap`-in-child, so a *full*
  replacement of the ptrace loop (M4-as-written) is impossible. The realistic M4
  is a **hybrid** (notify for the emulatable hot path, ptrace for the
  `mmap`/renumber residue) — documented and **deferred by data** (realistic
  workloads are ~5× native, so the hybrid's complexity is not yet justified).
  Also records the `FLAG_CONTINUE` TOCTOU rule (emulate every pointer/buffer
  syscall from one supervisor-side copy; never read-decide-then-CONTINUE).

## [0.4.0] — 2026-06-29

M3 — the Docker vehicle. agnos userland runs in a plain container, no QEMU.
This completes the functional v1 surface (direction-1 headless CLI, M0–M3).

### Added
- **M3 — the Docker vehicle + multi-container fan-out** (the v1 vehicle): agnos
  userland runs in a plain container, **no QEMU**.
  - `docker/Dockerfile` — a **`FROM scratch`** image (~58 KB) carrying mirshi +
    agnos-target static ELFs + a tiny rootfs, `ENTRYPOINT ["/mirshi"]`. Static
    no-libc binaries → no base OS, no shell, structurally no QEMU.
  - `docker/{build,fanout,smoke}.sh` + `docker/tools/*.cyr` (hello/catfile/ls/echo)
    — build the image, run agnos tools (`docker run agnos-mirshi /bin/hello`),
    demonstrate N-container fan-out, and a CI smoke gate (proves no qemu in the
    image). Wired into CI after the M2 step.
  - **Bounding seccomp policy** (`src/seccomp.cyr`): mirshi installs a classic-BPF
    allowlist on the child (after `PTRACE_TRACEME`, before `execve`, with
    `PR_SET_NO_NEW_PRIVS`) capping it to the syscalls the translation emits;
    anything else is `SIGSYS`-killed. Default-on in run mode, `--no-seccomp`
    opt-out, off in trace mode. The default-deny completeness proof is 0.7.0.
  - `mirshi` CLI: `mirshi [--selftest-trace] [--no-seccomp] <agnos-elf>`.
  - [ADR 0004](docs/adr/0004-docker-vehicle-bounding-seccomp.md) + the
    [fan-out guide](docs/guides/docker-fanout.md). ADR 0004 records the
    load-bearing finding that **seccomp is evaluated after the ptrace rewrite**
    (so the filter allowlists mirshi's *output* syscalls, not the agnos input).

## [0.3.0] — 2026-06-29

M2 — filesystem syscalls. agnos coreutils-class tools read+write a real fs, no QEMU.

### Added
- **M2 filesystem syscalls** — agnos `cat`/`cp`/`ls`/`stat`-class tools now read+
  write a real fs under mirshi (no QEMU). Adds 13 fs translations:
  `open#7` (`AO_*`→`O_*` flags + synthesized mode), `close#6`, `read#5`/`write#1`
  (M1), `lseek#58`, `dup#8`, `mkdir#9`, `rmdir#10`, `unlink#30`, `rename#31`,
  `link#32` (hardlink), `stat#33`, `getdents#29`.
  - `src/scratch.cyr` — child red-zone path staging: `process_vm_readv`/`writev`
    wrappers + `stage_at` (writes the NUL-terminated path below the stopped
    child's `rsp`, short-transfer-guarded). The fs calls execute in-child so the
    kernel reads the staged path natively.
  - `src/dispatch.cyr` — the fs handlers (single-path, two-path register MOVE for
    `rename`/`link`, and the `stat`/`getdents` exit-stop output repack).
  - `src/translate.cyr` — pure helpers: `ao_to_o`, `dtype_to_agnos`, the
    `stat` 144 B→48 B repack, the `getdents` Linux→agnos dirent repack, + the fs
    number map. Unit-tested (41 new assertions; 105 total).
  - `tests/fixtures` via `scripts/it/m2_fs.sh` — sandboxed fs integration test
    asserting HOST EFFECTS (file created/content, cp `cmp`, dir created, rename/
    hardlink, unlink, stat fields, dir listing). Wired into CI after the M1 step.
  - [ADR 0003](docs/adr/0003-fs-redzone-path-staging.md) — why red-zone path
    staging + exit-stop repack (not injected-mmap, not supervisor-side fs).
- Known gaps (documented): transparent path pass-through (rootfs isolation is M3,
  `..`/symlink-escape hardening is 0.7.0); `getdents` drops records past the agnos
  buffer; `getdents` ino truncated u64→u32.

## [0.2.0] — 2026-06-29

M1 — core translation. agnos binaries run as native Linux processes, no QEMU.

### Added
- **M1 core translation (process + console)** — mirshi's default mode now
  TRANSLATES + EXECUTES agnos syscalls so an agnos-compiled binary runs as a
  native Linux process (no QEMU). `mirshi <agnos-elf>` runs it; `--selftest-trace`
  keeps the M0 trap-log mode. Acceptance met: an agnos `hello` (write+exit) and a
  stdin `cat` run correctly, exit codes propagate, and a heap fixture proves
  `mmap#27` is executed in-child (the M0→M1 segfault gate).
  - `src/translate.cyr` — PURE agnos→Linux translation: the number remap, the
    number-aware return mapping (`-errno`→`-1`, but `mmap#27`/`time_unix#46`
    failure→0), the 2 MB mmap round-up, and the 6-arg mmap register synthesis.
    Unit-tested (39 new assertions; 64 total).
  - `src/dispatch.cyr` — the impure dispatcher: execute-in-child (rewrite
    `orig_rax`+args, kernel runs it in the child) for `write#1`/`read#5`/
    `getpid#2`/`mmap#27`/`munmap#28`/`sync#12`/`getrandom#45`/`time_unix#46`;
    supervisor-emulate (`uptime_ms#40` via shared `clock_gettime`, `sleep_ms#41`)
    via the `orig_rax=-1` skip + injected return; `exit#0`→real `exit_group`.
  - `src/intercept.cyr` — split into `_trace_log` (M0 `PTRACE_SYSEMU`) and
    `_trace_run` (M1 `PTRACE_SYSCALL` enter/exit loop), sharing `_attach`.
  - `tests/fixtures/{hello,cat,exit42,heapuser}.cyr` + `scripts/it/m1_run.sh` —
    the real translate+execute integration gate (wired into CI after the M0 step).
  - [ADR 0002](docs/adr/0002-execute-in-child-translation.md) — why
    execute-in-child via `PTRACE_SYSCALL` register rewrite (not SYSEMU+rip-rewind,
    not pure supervisor-emulate).

## [0.1.0] — 2026-06-29

M0 — scaffold + the trap loop. Interception proven *before* translation.

### Added
- Initial project scaffold (`cyrius init --bin --agent`, pin 6.3.5).
- Project identity: **mirror-shim** — bidirectional AGNOS↔Linux syscall-ABI
  translation (userland pico-process supervisor, NOT kernel emulation / VM).
  Activated from the idea-log ([[project_tools_stable_ideas]]) per the "earns its
  own memory file + planning doc when it activates" note.
- Architecture map in `src/main.cyr` (intercept → translate → emulate) + the
  first-few-cycles roadmap toward **v1 = AGNOS + mirshi runs in a plain Docker
  container, no QEMU** (direction 1, AGNOS→Linux).
- **The trap loop** — mirshi `fork`+`exec`s an agnos-target static ELF and traps
  **every** syscall it makes via `ptrace(PTRACE_SYSEMU)` on x86_64 Linux, decoding
  and logging the agnos syscall number + name + args. The host kernel executes
  none of the child's foreign-ABI syscalls; mirshi acts only on agnos `exit#0`
  (the program-exit that SYSEMU would otherwise suppress) to tear the child down
  and propagate its code.
  - `src/decode.cyr` — pure, side-effect-free decode: x86_64 `user_regs_struct`
    offsets, agnos number→name/arity/pointer-arg tables (all 0–35, 40–41, 45–61),
    and the `format_event` log-line renderer. Pointer args render `<ptr>` so logs
    are hermetic.
  - `src/intercept.cyr` — the fork/`PTRACE_TRACEME`/execve + `PTRACE_SYSEMU` wait
    loop, syscall-stop vs exit/signal classification, single-resume-site signal
    forwarding, and clean teardown. Defines the ptrace ABI the Linux stdlib peer
    lacks (`SYS_PTRACE`, `PTRACE_*`, `WIFSTOPPED`/`WSTOPSIG`). `wait4` is
    EINTR-retried and failure-guarded (a failed wait is never laundered into
    "child exited 0"), and the post-exec handshake is `WIFSTOPPED`-gated.
  - `src/main.cyr` — argv dispatch; `mirshi [--selftest-trace] <agnos-elf>`.
- `tests/fixtures/hi.cyr` (+ `hi.expected.log`) — the minimal agnos fixture
  (`getpid#2`, `write#1 "hi"`, `exit#0`) and its golden trapped stream.
- `tests/mirshi.tcyr` — pure-cyrius unit tests for the decode/format layer
  (hermetic; runs under `cyrius test`, no ptrace dependency).
- `scripts/it/m0_trap.sh` — integration test of the real fork+ptrace path; wired
  as a dedicated CI step after `cyrius test`.
- [ADR 0001](docs/adr/0001-ptrace-sysemu-intercept.md) — why `PTRACE_SYSEMU`
  (not `PTRACE_SYSCALL`, not seccomp-notify, not `LD_PRELOAD`) for M0.

### Changed
- `cyrius.cyml` — added `args` to `[deps].stdlib` (mirshi reads its own argv).
