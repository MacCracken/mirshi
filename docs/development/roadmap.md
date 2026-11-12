# mirshi — Roadmap

> **Forward-looking only.** What ships next, in what order. Shipped work lives in
> [`../../CHANGELOG.md`](../../CHANGELOG.md) (per release) and [`state.md`](state.md) (live snapshot);
> the per-number contract is [`../reference/syscall-coverage.md`](../reference/syscall-coverage.md).
>
> **Discipline** ([ADR 0011](../adr/0011-mirshi-qemu-iron-boundary-discipline.md)): mirshi runs agnos
> userland on the *host* Linux kernel. It validates **userland concurrency + Linux-app compat at
> scale**, NOT the agnos kernel's own SMP scheduler / net stack, and **complements, never replaces**
> QEMU+KVM (real kernel) + iron (hardware truth). **The kernel's code is the reference** for every
> answer mirshi gives: `../agnos/kernel/core/syscall.cyr` and its callees.

## Where things stand

mirshi handles agnos# 0–63 (except the kernel-only ops), `readlink#70`, `uptime_us#95` and the 1.57.13
band `#109–#111`. The agnos ABI has kept growing: the kernel at agnos 1.57.19 answers numbers up to
**#115**, and the cyrius 6.7.18 stdlib issues most of them. Everything mirshi does not handle falls to
`ENOSYS -> -1` with a stderr line. Closing that gap is the 1.13 line.

Each item below was checked against the kernel at agnos `aef48206` (1.57.19) on 2026-11-12. Items the
kernel has since made right on its side were dropped:
- `readlink#70` truncates since 1.57.18, as Linux does.
- `rename#31` replaces since 1.57.17.
- `flock#59` accepts directories.

---

## 1.12.2 — quick kernel-fidelity repairs

Small, self-contained fixes where mirshi gives a different answer than the kernel. Each one is a
contained change with a kernel line to check it against.

**The signal band** (filed 2026-10-12 from darshana's 1.1.4 audit; together they meant an agnos
signalfd never received a signal under mirshi):
1. **A signalfd reads `pending & watched`, ignoring the blocked mask**, as the kernel's
   `vfs_read_signalfd` and its epoll readiness test do. A signalfd consumer must block the signals
   first, so under mirshi the signal a program waits for was exactly the one it could never read.
   ADR 0014's `~blocked` term is corrected.
2. **The signalfd `read#5` record is the kernel's.** A count below 4 is -1. With nothing pending the
   answer is 0. Otherwise a 4-byte signal number is stored and the answer is 4. mirshi wrote 8 bytes,
   required 8, and answered -1 for "nothing pending". The kernel's 1..63 range, which mirshi already
   used, is unchanged.
3. **`close#6` on a signalfd frees its slot.** It stayed taken, so the 9th `signalfd#18` in a process
   was -1, and `fd_kind#111` kept answering SIGNALFD for a closed one.
4. **`signalfd#18` always makes a new signalfd**, as the kernel does: it ignores the fd argument and
   the flags. mirshi updated an existing one when given its id, and stored the flags word in the
   slot's in-use marker, so a flags value of -1 freed the slot.
5. **`sigprocmask#17` edges.** A NULL or unreadable `set` is -1, as on the kernel. `how` other than
   0 (BLOCK) or 1 (UNBLOCK) stores the set verbatim, where mirshi left the mask unchanged for
   `how >= 3`.

**Other fidelity:**

6. **`flock#59` refuses an fd that is neither a file nor a directory** (a pipe, a terminal, a device),
   and refuses fd < 0 or >= 32, as the kernel does. This is what is left of hapi's 2026-10-28 finding:
   the kernel now locks directories too.
7. **`sock_send#48` answers 0, not -1, when its ~8 s window expires with nothing sent.** The kernel
   returns the committed count (`TCP_PROGRESS_US`: "#48 returns the committed count after this long
   with no ACK progress"); a -1 told the program its connection was dead. Found in the 1.12.1 review.
8. **Coverage-doc corrections.** `kbscan#42` is listed as an undefined gap although it has been handled
   since 1.11.0. #36 (`klug`), #38/#39 (`fbinfo`/`blit`) and #44 (`sched_yield`) are real agnos calls
   now (still ENOSYS, see 1.13.0). `link#32`'s gap note says agnos has no symlink call, but #63 has
   existed since 1.10.2.

## 1.12.3 — P(-1) sweep: audit, refactor, hardening, optimization, security, and repairs

A whole-tree pass with no new syscalls, ending in the repairs it finds. Scope:
- **Correctness audit** of every arm against the kernel's current code (the drift found above suggests
  more).
- **Security sweep:**
  - every `pvm_read`/`pvm_write` length and pointer;
  - every child-controlled integer;
  - the child seccomp allowlist kept least-privilege;
  - the supervisor's own fds, signals and heap bounds.
- **Hardening:** fault injection over the new arms (#109–#111) and the 1.12.2 changes.
- **Refactor:** `src/dispatch.cyr` is ~2,200 lines, one file for every band.
- **Optimization:** the per-syscall hot path (ADR 0010 is the last pass).

Seeds already noticed:
- `src/` still declares local `SYS_*` / `O_*` / `SO_*` numbers that the stdlib has since grown with the
  same values (`SYS_PPOLL`, `SYS_MEMFD_CREATE`, `SYS_SENDTO` …). They compile silently today, but would
  break the build if a stdlib value ever changed.
- The `xlat-coverage` freeze test's labels name #36/#38/#39/#42/#44 as gaps.
- `state.md`'s version history has gaps (1.10.1–1.11.3 are one line).
- README's version paragraph stops at 1.11.1.
- `docs/reference/syscall-coverage.md` is headed "agnos# 0–61" but now has rows up to #111.
- The kernel's `sigprocmask#17` stores `oldset` before it reads `set`, so with `set == oldset`
  (which POSIX allows) it reads back the old mask. mirshi keeps the POSIX-correct order. Report this
  upstream rather than copy it.

---

## 1.13.x — ABI re-sync II

The agnos numbers past mirshi's surface. For each one, read its kernel arm first, then classify it:
EXECUTE (a Linux peer), EMULATE (answer it in the supervisor), or permanent ENOSYS (hardware-only,
see 1.x).

- **1.13.0 — the cheap ones:** a getter, an fs call with a Linux peer, or a pure supervisor answer.
  - Scheduling: `sched_yield#44` and `sched_yield_to#108`.
  - Filesystem: `lstat#102` (the `stat#33` repack, no-follow), `statfs#103` (a frozen 32-byte
    record), `mountlist#104`, `readdir#81` / `readdir_at#101`, and `fsync#115`.
  - The log: `klug#36`, mirshi's own log, or an empty ring.
  - Processes and limits: `proclist#99` (mirshi's record table) and `spawn_limits#107`.
  - Net: `sock_peer#106` and `icmp_echo_ex#100`.
- **1.13.1 — the process environment.** It goes with `chdir#112` / `getcwd#113` (agnos 1.57.18).
  - The kernel stages `HOME=/` and `PWD=<the cwd the child is born with>` into every init envp, and a
    `spawn_path#43` env blob replaces that default.
  - mirshi passes `[NULL]` for the root child, `spawn#3`, `#37` and `#43`. So `getenv("HOME")` is null
    under mirshi, and hapi's `$HOME`-scoped verbs cannot run.
  - Under `--root`, `PWD` and `chdir` must stay inside the rootfs.
- **1.13.2 — `fork#96`:** a second process image, traced like a `spawn#3` grandchild but sharing the
  parent's memory image at the fork point.
- **1.13.3 — channels `chan_op#97`:** the PTY band a terminal emulator hands its child. It is
  `fd_kind`'s FDK_CHAN, which mirshi never answers today.
- **Then:** `shm_*#71–74` and `ptrscan#98`. Read their arms before scheduling them.

## 1.14.x — kernel fidelity II

Bigger divergences that need a design choice, not a one-line fix:
- **`open#7` opens what the kernel refuses.** The kernel's `ext2_open` opens only regular files; a
  directory opens only through `AO_DIRECTORY`. mirshi passes `AO_RDONLY` to Linux `open`, which opens a
  directory, a FIFO or a device (filed 2026-10-28 from hapi's audit: fd 3 under mirshi, -1 on the
  kernel).
  - The check has to happen before the open: closing an fd from the supervisor after the fact means
    injecting a syscall, which ADR 0002 rejected.
  - It has to work under `--root` too.
- **timerfd semantics.**
  - A `read#5` before expiry is 0 on the kernel and -1 under mirshi.
  - The kernel stores 1, where mirshi stores an expiration count.
  - The kernel re-arms a periodic timer from now, where mirshi re-arms from the old deadline.
  - Decide which of the ADR 0015 defaults to change, with a consumer.
- **`read#5`'s non-blocking form (a4 = 1) is ignored for real fds.** The kernel answers -2
  (WOULD_BLOCK) or -3 (fd 0: a partial keyboard line pending). mirshi renumbers to a blocking Linux
  `read`, so `sys_read_nb` blocks. darshana's terminal reads use it.
- **`console_mode#110`:** a FLUSH while another process is mid-line waits for that reader on the
  kernel, and discards at once under mirshi.

## 1.15.x — the signal model

- **Host-originated signals bypass the agnos model.**
  - What happens today: a terminal Ctrl-C, a host `kill`, a SIGHUP or a SIGWINCH takes the ptrace
    signal-delivery path and is re-injected as a real Linux signal with its real default action,
    because the child's agnos blocked mask exists only in the supervisor (filed 2026-10-12).
  - The consequence: a screen-owning program is killed instead of waking its teardown, and the
    terminal is left raw.
  - The fix maps them into `C_PENDING_SIG` and suppresses the real delivery while the agnos mask
    blocks them.
- **Job control and the console:** after Ctrl-Z / `fg`, mirshi does not hide a `console_mode` echo
  again. This needs a SIGCONT handler that returns, so a real `sa_restorer` trampoline.

## 1.16.x — supervisor concurrency

- **Head-of-line blocking.** One single-threaded supervisor serves every child. So `sleep_ms#41`,
  `pause#14`'s quantum, `epoll_wait#21`'s ppoll and the net band's bounded waits (up to 8 s for
  `#48`/`#109`) stall every other child for that long. The fix is an event-driven supervisor: stop
  scheduling instead of in-line waits.
- **epoll.** Real child fds (stdin, a pipe end) are not watchable, which is the reserved `PIPE_BASE`
  watchable-pipe promotion. Socket watching resolves `id & 7` to a slot, which is exact for sequential
  servers but diverges under connect-failure churn; that needs a coordinated agnos + mirshi fix.
- **Revisit seccomp-notify** (ADR 0005, deferred-by-data) as the per-syscall cost path once the
  supervisor is event-driven.

## 1.x — open decisions

- **The hardware bands:** sound `#64–69`, block devices `#75–80`, the GPU `#82–94` (`#86` and
  `#87` share the shm band), `fbinfo#38` / `blit#39`, and the power query `#114`. Either they stay
  permanent ENOSYS, or a headless emulation is useful (a null sound sink, a blit to the terminal, an
  image file as a block device). Decide per band, with a consumer.
- **`symlink#63` under `--root`:** refused today, because a raw target is not a confinable path. It
  needs a custom `symlinkat` that keeps the target text literal while anchoring the link path.
- **Value assumptions** (ADR 0016/0017), each revisited when a consumer needs it:
  - `uname.release` is `mirshi`, where the kernel writes its version.
  - `sysinfo.procs` is a live count, where the kernel reports a high-water mark.
  - `winsize#60` never answers -1.

---

## 2.0.0 — backlog: direction 2, the Linux→AGNOS "swallow"

Run **Linux** binaries **on the agnos kernel**: the permanent compat layer, the mirror half of the
mirror-shim, and a **major** bump. An entirely separate validation surface: the same translation core
run from the other side. Per [ADR 0011](../adr/0011-mirshi-qemu-iron-boundary-discipline.md) this still
never replaces QEMU+iron. It is scheduled once the 1.x line has closed the direction-1 re-sync.

## Not planned (agnos-kernel-only)

`mount#11` / `umount#24` / `reboot#13` / `write_boot_checkpoint#26` are agnos-**kernel** operations
with no meaningful host-Linux translation (on agnos itself they stub or halt). mirshi returns ENOSYS by
design.
