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

mirshi handles agnos# 0–63 (except the kernel-only ops), `readlink#70`, `uptime_us#95`, the 1.57.13
band `#109–#111`, and since 1.13.0 the re-sync's cheap band (`#81`, `#99–#104`, `#106–#108`, `#115`). The
agnos ABI has kept growing: the kernel at agnos 1.57.19 answers numbers up to **#115**, and the cyrius
6.7.18 stdlib issues most of them. Everything mirshi does not handle falls to `ENOSYS -> -1` with a stderr
line. Closing that gap is the rest of the 1.13 line.

Each item below was checked against the kernel at agnos `aef48206` (1.57.19) on 2026-11-12. Items the
kernel has since made right on its side were dropped:
- `readlink#70` truncates since 1.57.18, as Linux does.
- `rename#31` replaces since 1.57.17.
- `flock#59` accepts directories.

---

The 1.12 line is done: 1.12.2 (kernel-fidelity repairs) and 1.12.3 (the P(-1) sweep, findings in
[`../audit/2026-11-12-audit.md`](../audit/2026-11-12-audit.md)). What the sweep found and did not fix is
filed below, each under the release it belongs to. 1.13.0 (the cheap band) shipped; its record is the
CHANGELOG and [ADR 0019](../adr/0019-abi-resync-cheap-band-supervisor-side.md).

**Upstream report, ready to file:** the kernel's `sigprocmask#17` writes `oldset` before it reads `set`,
so `set == oldset` applies the old mask. mirshi keeps the POSIX order (ADR 0014, *Amendment*). The draft
is in the audit doc.

---

## 1.13.x — ABI re-sync II

The agnos numbers past mirshi's surface. For each one, read its kernel arm first, then classify it:
EXECUTE (a Linux peer), EMULATE (answer it in the supervisor), or permanent ENOSYS (hardware-only,
see 1.x).

- **1.13.1 — the process environment.** It goes with `chdir#112` / `getcwd#113` (agnos 1.57.18).
  - The kernel stages `HOME=/` and `PWD=<the cwd the child is born with>` into every init envp, and a
    `spawn_path#43` env blob replaces that default.
  - mirshi passes `[NULL]` for the root child, `spawn#3`, `#37` and `#43`. So `getenv("HOME")` is null
    under mirshi, and hapi's `$HOME`-scoped verbs cannot run.
  - Under `--root`, `PWD` and `chdir` must stay inside the rootfs.
  - The supervisor-side path calls (1.13.0 `readdir#81` / `readdir_at#101` / `statfs#103`, and the
    confined `_cf_*` ops) resolve a relative path from mirshi's working directory or the root; with
    `chdir` they must resolve from the caller's.
  - **`exec_redirect#62`**, from the sweep:
    - Its arm is one global, where the kernel keeps a set of up to 4 pairs per process.
    - `REDIR_ADD` (`2>&1`) and `REDIR_CLEAR` (0x200) are not decoded, and src/dst outside [0, 32)
      are not refused.
    - The arm is not cleared when a `#37`/`#43` returns early.
  - **Children of `#37`/`#43` start with fds 0–2 only** (1.12.3). Without `SPAWN_F_CLEANFD` the kernel
    hands them the caller's table instead.
  - **`spawn_path#43`/`execwait#37` exec failures** (-4 / -5 on the kernel) answer a pid under mirshi. It
    needs an exec-status pipe from the grandchild.
- **1.13.2 — the process band re-sync** (from the sweep). This needs a decision first.
  - **`spawn_limits#107`** answers -1 (1.13.0) until the caps it arms are enforced on the caller's next
    child: a memory cap (`RLIMIT_AS`) and a CPU budget (`RLIMIT_CPU`) in the grandchild before exec.
  - **The pid model:** the kernel's pids are process-table slots 0..15, reused. mirshi's are monotonic
    (ADR 0013), and the stdlib's `sys_waitpid_block` refuses a pid above 15.
  - **`waitpid#4`:**
    - A plain call is a poll on the kernel: -2 while the child lives. mirshi parks the caller until the
      child exits.
    - mirshi does not support `0x100|pid` (WAIT_BLOCK), `0x1FF` (wait-any), or the restriction to
      the caller's own children.
    - The status word should be `0x100|sig` for a signal death and `128 + vector` for a fault; mirshi
      answers -1.
  - **`kill#16`:** signal 9 should end the target, 18/19 continue and stop it, `KILL_TREE` (0x100) signal
    the whole tree, and a partial tree stop answer -2.
  - **`spawn#3`'s image cap:** the kernel's is 16 KB. Decide whether mirshi follows it.
- **1.13.3 — `fork#96`:** a second process image, traced like a `spawn#3` grandchild but sharing the
  parent's memory image at the fork point.
- **1.13.4 — channels `chan_op#97`:** the PTY band a terminal emulator hands its child. It is
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
- **From the 1.12.3 sweep:**
  - **`flock#59`'s owner** is the pid on the kernel and the open file on Linux. Two fds in one process
    do not contend on the kernel, and closing either fd releases the lock.
  - **Fd limits:**
    - The kernel's table is 32 fds (`RLIMIT_NOFILE` 32 after ROOTFD is pinned).
    - Its emulated fds share that one budget; mirshi has separate 8/8/4 slot tables.
  - **`munmap#28`** outside the mmap arena, or not 2 MB-aligned, is refused on the kernel.
  - **`sock_connect#47`'s timed form** (a3 bit 32, a4 = a timeout in ms, 0 = non-blocking) is ignored.
  - **UDP:**
    - The kernel keeps a separate 8-entry UDP table, where mirshi shares one table with TCP.
    - The kernel sends from a source port that was never bound.
  - **epoll:**
    - 128 watches per instance (mirshi has 8).
    - The 1.57.17 ABI: op 3 SET, EPOLLOUT / EPOLLRDHUP, `EP_TCP|id` targets, and EPW_TIMED's
      blocking wait.
    - Op 1 refusing tagged socket ids.
  - **`kbscan#42`:**
    - Keys beyond `max` should be kept for the next call.
    - A bad buffer should be -1 with the keys kept.
    - stdin's `O_NONBLOCK` should be restored at exit.
  - **Smaller items:** `write(fd, NULL, 0)` is -1 on the kernel. `open#7`'s create mode is applied
    under the child's umask, where the kernel has none.

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
- **Fairness** (from the sweep). `wait4(-1)` serves the oldest ready child first, so a syscall-dense
  child can delay a sibling's first syscall by seconds. Serve the ready stops round-robin.
- **`sleep_ms#41` in the child** (a nanosleep with a staged timespec) instead of in the supervisor, and
  an opt-in CPU-pinning flag (measured: about 23–29 % per call when pinned).
- **Revisit seccomp-notify** (ADR 0005, deferred-by-data) as the per-syscall cost path once the
  supervisor is event-driven.

## 1.x — open decisions

- **Refactor leftovers** from 1.12.3:
  - the `HOST_*` / `SYS_READ0` / `SYS_FCNTL_KB` aliases of stdlib names;
  - `_net_emu`, the shared emulate helper, renamed for what it is;
  - a per-mode seccomp allowlist (the unconfined path peers are allowed under `--root` too);
  - the trace loop's assumption that a new child's first stop is its exec SIGTRAP.

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
