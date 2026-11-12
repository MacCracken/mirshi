# mirshi — syscall coverage matrix (the frozen translation contract)

> **Frozen at v0.9.0.** This is the canonical, per-number contract for direction 1
> (AGNOS→Linux): every agnos syscall is either **mapped** to a Linux peer (executed in
> the child), **emulated** in the supervisor, rewritten as the special **exit**, or
> returns **ENOSYS**. The source of truth is the code (`src/translate.cyr` +
> `src/dispatch.cyr` + `src/decode.cyr`); this table mirrors it and is **pinned by
> tests** (`tests/mirshi.tcyr`: `xlat-nr`, `fs-nr`, `xlat-coverage` assert
> `agnos_to_linux_nr` for every number 0–61 + boundaries). Changing a row is a
> deliberate contract change — update the code, this doc, **and** the freeze test together.
> The v1.0 **core is frozen**; the **net band** (#47–50 TCP client / #56–57 TCP server / #51–54 UDP /
> `icmp_echo#55` / `net_config#61`) is a documented **post-v1 extension** (v1.1.0–v1.4.0, EMULATE
> under `--net` — footnote ²), now **complete** — no net-band number remains ENOSYS.

## Dispositions

| code | meaning |
|---|---|
| **EXECUTE** | renumber `orig_rax` to the Linux peer (+ arg synth / path staging) and run it **in the child** (execute-in-child, [ADR 0002](../adr/0002-execute-in-child-translation.md)); the exit stop maps the return. |
| **EMULATE** | skip the kernel syscall (`orig_rax = -1`) and inject a supervisor-computed return; no Linux peer. |
| **EXIT** | agnos `exit#0` is rewritten to Linux `exit_group(231)`; the child terminates, `waitpid` carries the status out (no exit stop). |
| **ENOSYS** | out of the v1 surface — skip the foreign call and inject the agnos error sentinel `-1` + a logged diagnostic; never run a wrong Linux syscall. |

agnos uses the x86_64 kernel register ABI (a1..a6 = `rdi/rsi/rdx/r10/r8/r9`; **a4 = r10**,
not `rcx`). The agnos error convention is a **bare `-1`** for most calls (mmap#27 and
time_unix#46 use `0`); the exit stop maps Linux `-errno` accordingly
([`linux_ret_to_agnos`](../../src/translate.cyr)).

## Matrix (agnos# 0–61)

| # | name | disp. | Linux peer | notes |
|--:|------|:-----:|-----------:|-------|
| 0 | exit | EXIT | `exit_group` (231) | code in a1; terminates, no exit stop |
| 1 | write | EXECUTE | `write` (1) | `(fd,buf,len)` identical; err→`-1` |
| 2 | getpid | EMULATE ³ | — | multi-process (v1.5.0): returns the caller's **coined agnos pid** (root=1), not host `getpid`(39) — else children would see clashing host pids; loop-supplied `_cur_rec` |
| 3 | spawn | EMULATE ³ | — | multi-process (v1.5.0): supervisor forks a **traced** grandchild from the in-memory ELF (memfd + `execveat`), returns a coined agnos pid; handled at the loop level, not `agnos_to_linux_nr` |
| 4 | waitpid | EMULATE ³ | — | multi-process (v1.5.0): blocks on the target agnos pid (parks the caller stopped — not the supervisor — until it exits), returns its exit code directly; loop-level, not `agnos_to_linux_nr` |
| 5 | read | EXECUTE | `read` (0) | number differs; EOF `0` passes |
| 6 | close | EXECUTE | `close` (3) | |
| 7 | open | EXECUTE | `open` (2) ¹ | path staged (NUL-term); `AO_*`→`O_*` ([`ao_to_o`](../../src/translate.cyr)); mode 0600 on `O_CREAT` |
| 8 | dup | EXECUTE | `dup` (32) | |
| 9 | mkdir | EXECUTE | `mkdir` (83) ¹ | path staged; mode 0700 |
| 10 | rmdir | EXECUTE | `rmdir` (84) ¹ | path staged |
| 11 | mount | ENOSYS | — | stub |
| 12 | sync | EXECUTE | `sync` (162) | |
| 13 | reboot | ENOSYS | — | |
| 14 | pause | EMULATE ⁴ | — | signals (v1.6.0): **bounded yield** — returns 0 (idle a quantum, or immediately if a deliverable signal is pending); never wedges the recv poll loop; loop-level |
| 15 | getuid | EMULATE ⁶ | — | info getters (v1.8.0): `getuid`/`geteuid` → **0** (always root; never the host uid) |
| 16 | kill | EMULATE ⁴ | — | signals (v1.6.0): sets `1<<sig` in the target's pending mask; self/direct-child scope, pid 0 protected, sig 1..63; loop-level |
| 17 | sigprocmask | EMULATE ⁴ | — | signals (v1.6.0): read/apply/write the caller's blocked mask (`SIG_BLOCK`/`UNBLOCK`/`SETMASK`), oldset round-trip. **v1.12.2:** `set` is required (NULL → −1, as on the kernel); `how` ≥ 2 stores the set verbatim |
| 18 | signalfd | EMULATE ⁴ | — | signals (v1.6.0): opaque `SIGFD_BASE+slot` fd (per-child slot table). **v1.12.2, the kernel's contract:** every call is a new signalfd (fd and flags not consulted); `read#5` stores the lowest pending & watched signal — the blocked mask not consulted — as a **4-byte** number and answers 4, 0 when nothing is pending, −1 for a count < 4; `close#6` frees the slot |
| 19 | epoll_create | EMULATE ⁵ | — | I/O-mux (v1.7.0): a per-child epoll instance (`EPOLL_BASE+slot`), an 8-watch list of raw agnos ids |
| 20 | epoll_ctl | EMULATE ⁵ | — | I/O-mux (v1.7.0): op 1=ADD (dedup, 8-cap), op 2=CLEAR (whole list; fd ignored) |
| 21 | epoll_wait | EMULATE ⁵ | — | I/O-mux (v1.7.0): heterogeneous **bounded-yield** readiness — `ppoll` sockets + mask-test signalfds + clock-test timerfds; packed 12 B events; never parks |
| 22 | timerfd_create | EMULATE ⁵ | — | I/O-mux (v1.7.0): a supervisor-side deadline (`TIMERFD_BASE+slot`); no real Linux timerfd |
| 23 | timerfd_settime | EMULATE ⁵ | — | I/O-mux (v1.7.0): arm a `CLOCK_MONOTONIC` deadline (seconds; capped); `read#5` delivers the expiration count |
| 24 | umount | ENOSYS | — | stub |
| 25 | pipe | EXECUTE ⁵ | `pipe2` (293) | I/O-mux (v1.7.0): run **in the child** (`O_CLOEXEC`); exit-stop 2×i32→2×u64 repack; the sole child-bound delta. Not via `agnos_to_linux_nr` (intercepted before it) |
| 26 | write_boot_checkpoint | ENOSYS | — | agnos-kernel-only |
| 27 | mmap | EXECUTE | `mmap` (9) | a1=length → 6-arg synth: anon/private, `PROT_READ\|WRITE`, fd=-1, 2 MB round-up; fail→`0` |
| 28 | munmap | EXECUTE | `munmap` (11) | length 2 MB round-up (matches mmap granularity) |
| 29 | getdents | EXECUTE | `getdents64` (217) | one-page scratch staged; Linux→agnos dirent repack at exit (cap 4096) |
| 30 | unlink | EXECUTE | `unlink` (87) ¹ | path staged |
| 31 | rename | EXECUTE | `rename` (82) ¹ | two paths staged; a4=r10 |
| 32 | link | EXECUTE | `link` (86) ¹ | two paths staged; a **HARDLINK** (symlinks are `symlink#63`) |
| 33 | stat | EXECUTE | `stat` (4) ¹ | path staged; Linux 144 B → agnos 48 B repack at exit |
| 34 | uname | EMULATE ⁶ | — | info getters (v1.8.0): synthesized agnos-native 64 B struct (4×16 = sysname=AGNOS/nodename=agnos/release=mirshi/machine=x86_64); `len<64`→−1 |
| 35 | sysinfo | EMULATE ⁶ | — | info getters (v1.8.0): agnos-native 40 B struct (5×u64 = uptime/totalram/freeram/procs/cpus) from live host values; `len<40`→−1. **v1.11.3:** the kernel's length tiers — writes exactly 40 / 104 (+per-core user/kernel ticks at +40, host `/proc/stat`) / 200 (+BLK-tag sectors at +104, zero) / 208 (+`sched_kicks` at +200, zero) bytes |
| 36 | klug | ENOSYS | — | the kernel log ring (dmesg). Not handled yet — the 1.13.0 re-sync |
| 37 | execwait | EMULATE | — | **exec band (v1.10.0):** load a static ELF from a PATH + run to completion, return its exit code (agnsh's `run`). Loop-level: fork a traced grandchild that execve's the path token via `_child_exec` (the top-level program's path), then park the caller on the coined pid until it exits — the `spawn#3` + `waitpid#4` fusion. cmdline `"PATH args.."` space-tokenized, argv[0]=path |
| 38–39 | fbinfo / blit | ENOSYS | — | the framebuffer pair. A hardware band: permanent ENOSYS or a headless emulation is an open decision ([roadmap](../development/roadmap.md) 1.x) |
| 40 | uptime_ms | EMULATE | — | `CLOCK_MONOTONIC` in the supervisor → ms |
| 41 | sleep_ms | EMULATE | — | `nanosleep` in the supervisor; ≤0 → 0; cap 1 h |
| 42 | kbscan | EMULATE | — | **v1.11.0:** the raw Set-1 scancode drain, synthesized from mirshi's stdin (the tty armed raw + non-blocking on the first call; a pipe works too) — cyim's per-key channel |
| 43 | spawn_path | EMULATE | — | **exec band (v1.10.1):** NON-blocking from-disk spawn — fork a traced grandchild that execve's the path (the `_spawn_from_path` core, shared with execwait#37), inject the coined agnos pid NOW; the caller reaps it via `waitpid#4`. The cyrius stdlib `exec_*` path (`_agnos_spawn_path` + `sys_waitpid`) |
| 44 | sched_yield | ENOSYS | — | not handled yet — the 1.13.0 re-sync |
| 45 | getrandom | EXECUTE | `getrandom` (318) | `(buf,len,flags)` identical; number differs |
| 46 | time_unix | EXECUTE | `time` (201) | a1 forced NULL (seconds in rax); fail→`0` |
| 47 | sock_connect | EMULATE ² | — | net band client (v1.1.0): conn_id slot table + `--net-allow` egress |
| 48 | sock_send | EMULATE ² | — | net band client (v1.1.0): pvm-staged `send` (`MSG_NOSIGNAL`). **v1.12.2:** the ~8 s window expiring with nothing sent answers 0 (the committed count, the kernel's D6 rule), not −1 |
| 49 | sock_recv | EMULATE ² | — | net band client (v1.1.0): **inverted EOF** (0=WOULD_BLOCK, −1=EOF) |
| 50 | sock_close | EMULATE ² | — | net band (v1.1.0): free the slot; a LISTEN slot reaps children (v1.2.0) |
| 51 | udp_bind | EMULATE ² | — | net band UDP (v1.3.0): bound DGRAM socket; loopback-default |
| 52 | udp_send | EMULATE ² | — | net band UDP (v1.3.0): per-datagram egress; packed `(sport<<16)\|dport` |
| 53 | udp_recv | EMULATE ² | — | net band UDP (v1.3.0): sender `addr_out` {ip@0, port@8}; no EOF |
| 54 | udp_unbind | EMULATE ² | — | net band UDP (v1.3.0): free the SLOT_UDP |
| 55 | icmp_echo | EMULATE ² | — | net band ICMP (v1.4.0): unprivileged `SOCK_DGRAM`+`IPPROTO_ICMP` ping; RTT ms (≥0, sub-ms=0) / −1; bounded ~3s |
| 56 | sock_listen | EMULATE ² | — | net band server (v1.2.0): bind+listen; loopback-default (`--net-listen-any`) |
| 57 | sock_accept | EMULATE ² | — | net band server (v1.2.0): `accept4` → a fresh conn_id |
| 58 | lseek | EXECUTE | `lseek` (8) | `(fd,offset,whence)` identical |
| 59 | flock | EXECUTE ⁶ | `flock` (73) | advisory locks (v1.8.0): execute-in-child, op codes identical (SH/EX/UN/+NB); the sole child-bound delta. **v1.12.2:** an fd that is not a file or a directory, or outside [0, 32), is −1 before the EXECUTE, as on the kernel |
| 60 | winsize | EMULATE ⁷ | — | tty sizing (v1.9.0): `(cols<<16)\|rows` from the controlling terminal's `TIOCGWINSZ` (80×24 default if no tty); the whole direction-1 graphics surface |
| 61 | net_config | EMULATE ² | — | net band (v1.3.0): reads the real netns gateway/DNS/host-IP (field 1 netmask 0-unset) |
| 62 | exec_redirect | EMULATE | — | **exec band (v1.10.2):** one-shot ARM — the next from-path exec (execwait#37 / spawn_path#43) routes the child's src_fd (e.g. 1=stdout) to the CALLER's dst_fd. Consumed in `_spawn_from_path`: **steal dst_fd from the caller via `pidfd_getfd`** (files AND pipes) + `dup3` onto src_fd in the grandchild. No restore — mirshi's child is a separate process |
| 63 | symlink | EXECUTE | `symlink` (88) | **exec band (v1.10.2):** two paths staged; target is a **literal string**, linkpath a real path (same `(path,len,path,len)` shape as `link#32`). `--root` deferred (a raw target isn't a confinable path) |

| 95 | uptime_us | EMULATE | — | **v1.11.3:** `CLOCK_MONOTONIC` in the supervisor → µs, the same epoch as `uptime_ms#40` (never −1: the host clock always works). ⚠ Linux #95 is `umask` — the skip keeps it from running in the child |
| 109 | sock_send_dl | EMULATE ² ⁸ | — | **v1.12.1 (agnos 1.57.13):** `sock_send#48` with a caller ceiling. Conn checked first (−1 even for len ≤ 0), len ≤ 0 → 0; `timeout_us` 0 = exactly #48, < 0 = one non-blocking attempt, > 0 = wait ≤ min(ceiling, 8 s) for space; an expired wait → **0** (committed count), not −1. ⚠ Linux #109 is `setpgid` |
| 110 | console_mode | EMULATE ⁸ | — | **v1.12.1 (agnos 1.57.13):** `(set, clear)` → the console's previous flags / −1. `CM_NOECHO` hides echo on the host tty and **dies with its holder**, `CM_FLUSH` = `tcflush(TCIFLUSH)`, `CM_NOSERIAL` per process (reported only). Unknown bits → −1 with nothing changed. ⚠ Linux #110 is `getppid` |
| 111 | fd_kind | EMULATE ⁸ | — | **v1.12.1 (agnos 1.57.13):** fd → `FdKind` (1 CONSOLE … 10 DEVICE) / −1. Emulated event fds by slot; a real fd via `pidfd_getfd` + `fstat` + `TCGETS` in the supervisor; fd < 0, ≥ 32 or closed → −1. ⚠ Linux #111 is `getpgrp` |

**#62 exec_redirect + #63 symlink are handled** (the exec-band re-sync, v1.10.x), as are `uptime_us#95` (v1.11.3) and the agnos 1.57.13 band `sock_send_dl#109` / `console_mode#110` / `fd_kind#111` (v1.12.1 — footnote ⁸). Any other number > 63 (and the undefined 0–61 gaps) → **ENOSYS**.

¹ **Under `--root`** ([ADR 0009](../adr/0009-rootfs-confinement-openat2-in-child.md)) the
filesystem ops re-anchor at the child's rootfd: `open`→`openat2` (437, `RESOLVE_IN_ROOT`),
`mkdir`→`mkdirat` (258), `rmdir`→`unlinkat` (263, `AT_REMOVEDIR`), `unlink`→`unlinkat` (263),
`rename`→`renameat2` (316), `link`→`linkat` (265), `stat`→`newfstatat` (262), with the path
lexically sanitized (`sanitize_rootrel`). The fd-based ops (`read`/`write`/`lseek`/`dup`/
`close`/`getdents`) ride a fd from a confined `open`, so they are transitively confined.
Without `--root`, the peers in the table above apply (transparent pass-through).

² **Net band (post-v1 extension, `--net`).** #47–50 (TCP client, v1.1.0), #56/#57 (TCP server,
v1.2.0), #51–54 (UDP) + `net_config#61` (v1.3.0), and `icmp_echo#55` (ICMP, v1.4.0) are
**supervisor-EMULATE** ([ADR 0012](../adr/0012-net-band-supervisor-emulated-conn-table.md)): the
supervisor owns the sockets via an 8-slot `{fd,kind,parent}` table (TCP conn / TCP listen / UDP);
the child never holds a socket fd. (`icmp_echo#55` takes no slot — it opens a transient
unprivileged `SOCK_DGRAM`+`IPPROTO_ICMP` ping socket, round-trips one echo under a bounded ~3s
`ppoll`, and closes it.) Enabled by `--net` / `--net-allow` (egress default-deny) /
`--net-listen-any` (ingress loopback-default). **Without `--net` they return ENOSYS** (agnos `-1`).
The net band is now **complete** — no net-band number remains ENOSYS (see the
[roadmap net band arc](../development/roadmap.md)).

³ **Multi-process (v1.5.0).** `spawn#3` / `waitpid#4` / `getpid#2` are **supervisor-EMULATE**
([ADR 0013](../adr/0013-multiprocess-supervisor-fork-record-table.md)): the supervisor traces a small
process tree via a `wait4(-1)` demux loop + a fixed 16-slot per-child record table. `spawn#3` forks a
grandchild from the in-memory ELF (memfd + `execveat`; the child seccomp bound gains only `execveat`,
the fork stays supervisor-side); `waitpid#4` **parks** the caller (left stopped — *not* the supervisor)
until the target exits, then injects its exit code; `getpid#2` returns the caller's **coined agnos pid**
(root = 1, monotonic, never reused). A `MAX_CHILDREN=16` cap re-closes the process-storm vector
([ADR 0006](../adr/0006-host-resource-bounds-child-rlimits.md)). **Known limits** (ADR 0013):
`sleep_ms#41` + blocking net I/O still run in the supervisor — **head-of-line blocking** across children
(deferred rework, pairs with v1.6.0 signals); agnos `exit(>255)` is 8-bit-truncated by the host status
word; a wait deadlock (self-wait / cycle) is **broken to −1**, not diagnosed. Signals (`kill#16` et al.)
shipped in v1.6.0 (footnote ⁴).

⁴ **Signal band (v1.6.0).** `pause#14` / `kill#16` / `sigprocmask#17` / `signalfd#18` are
**supervisor-EMULATE** ([ADR 0014](../adr/0014-signal-band-supervisor-emulated-masks-signalfd.md)) over the
v1.5.0 record table — no real host signals, no real host fds. Each child record carries a **pending** mask
(`kill#16` ORs `1<<sig`, self/direct-child scope, pid 0 protected, sig 1..63) and a **blocked** mask
(`sigprocmask#17`). `signalfd#18` returns an opaque `SIGFD_BASE + slot` fd (per-child 8-slot table), a new one
on every call. Since **v1.12.2** a `read#5` on it follows the kernel's `vfs_read_signalfd`: it takes the lowest
signal that is pending **and watched — the blocked mask is not consulted**, because a signalfd consumer blocks
its signals first and reads exactly those. It stores that number as **4 bytes** and answers 4, clearing the
pending bit **after** the write (deliver-then-consume, so a failed write never loses the signal). It answers
0 when nothing is pending (non-blocking) and −1 for a count below 4. `close#6` frees the slot. Masks are agnos `1<<sig` (bit N =
signal N, **not** libc's `1<<(sig-1)`). `pause#14` is a **bounded yield** (returns 0; idles a 1 ms supervisor
quantum if nothing pending) — it never blocks forever, protecting `_agnos_sock_recv_block`'s TLS/HTTP poll
loop. `SIGFD_BASE = 0x20000000` keeps **bit 30 clear** so it never collides with the agnos userland's own
socket-fd tag `AGNOS_SOCK_TAG = 0x40000000`. **Known limits**: `pause` head-of-line-blocks other children for
the 1 ms quantum (the `sleep_ms#41` class); the signalfd is **non-blocking**, like the kernel's (a read with
nothing pending returns 0, not a park). See [ADR 0014](../adr/0014-signal-band-supervisor-emulated-masks-signalfd.md).

⁵ **I/O-multiplexing band (v1.7.0).** `epoll#19–21` + `timerfd#22–23` are **supervisor-EMULATE**; `pipe#25`
is **EXECUTE-in-child** ([ADR 0015](../adr/0015-io-mux-emulated-epoll-timerfd-executed-pipe.md)). A server's
epoll watches SOCKETS (supervisor-held host fds) + signalfds (a mask) + timerfds (a deadline) — none real
child fds — so epoll/timerfd MUST be supervisor-side. **timerfd** is a stored `CLOCK_MONOTONIC` deadline
(`TIMERFD_BASE+slot`, no real Linux timerfd); `read#5` delivers the u64 expiration count (deliver-then-consume,
seconds capped at `TIMERFD_SEC_CAP` + negative-reject). **epoll** is a per-child instance (`EPOLL_BASE+slot`,
4 instances × an 8-watch list of raw ids); `epoll_wait#21` is a **heterogeneous bounded-yield** pass (the
`pause#14` model, **never** a park — a readiness event has no `wait4` wake source): `ppoll` the socket host fds
+ mask-test signalfds + clock-test timerfds, merge, write packed 12 B `{u32 EPOLLIN; u64 raw-id}` events (0 =
nothing ready, valid non-blocking). The tag ladder (SIGFD bit29 > TIMERFD bit28 > EPOLL bit27 > PIPE bit26, all
bit-30-clear) lets `read#5`/`close#6` tier by a `>= MIN_EMU_BASE` front gate. **pipe#25** runs real Linux
`pipe2`(`O_CLOEXEC`) in the child — every agnos pipe use is intra-process (no fork; `spawn#3` passes no fds) —
with a 2×i32→2×u64 exit-stop repack + an enter-stop output-buffer write-probe (fail-clean, no fd leak); the
sole child-seccomp delta (`pipe2=293`). **Known limits**: **socket-watching is best-effort** — a program
watches the bit-30-tagged socket fd and epoll resolves `id & 7` → conn slot; exact for sequential server flows,
but the guest/mirshi socket-slot maps can diverge under connect-failure churn (a coordinated agnos-kernel +
mirshi-shim fix lands later; guarded by a wait-time `SLOT_FREE` re-validation). A **real child fd** (stdin, a
pipe end) is **not epoll-watchable** (not supervisor-observable). A **blocking** pipe read with no writer wedges
the single-threaded supervisor (the write-before-read / self-pipe pattern avoids it; a watchable/non-blocking
pipe is the reserved `PIPE_BASE` follow-up). `epoll_wait`'s ≤1 ms `ppoll` head-of-line-blocks other children
(the `pause#14` class). The ABI-ambiguity defaults (epoll mask=EPOLLIN, op 2=whole-clear, timerfd flags
relative) are baked pending a real consumer. See [ADR 0015](../adr/0015-io-mux-emulated-epoll-timerfd-executed-pipe.md).

⁶ **Info getters + advisory locks (v1.8.0).** `getuid#15` / `uname#34` / `sysinfo#35` are **supervisor-EMULATE**
(synthesized), `flock#59` is **EXECUTE-in-child**
([ADR 0016](../adr/0016-info-getters-emulated-flock-executed.md)) — the ENOSYS long-tail. `getuid`/`geteuid`
→ 0 (always root; never the host uid). `uname#34` writes the agnos-NATIVE 64 B struct (4×16 NUL-padded at
0/16/32/48 = `sysname="AGNOS"` / `nodename="agnos"` / `release="mirshi"` / `machine="x86_64"`, NOT Linux
`utsname`); `sysinfo#35` writes the agnos-NATIVE 40 B struct (5×u64 at 0/8/16/24/32 = `uptime_secs` /
`totalram` / `freeram` / `procs` / `cpus`, NOT the ~112 B Linux struct) from **live host values** (host
`sysinfo#99` for uptime/RAM×`mem_unit`; `_child_count` for procs; `sched_getaffinity` popcount for cpus). Both
**hard-reject −1 if `len` < the struct size** (no partial fill). `flock#59` renumbers to Linux `flock(73)`
(op codes identical) — a real inode-keyed advisory lock on the child's real fd; the sole child-seccomp delta.
The info getters add **zero** child syscalls (all supervisor-side). **Value assumptions** (no in-tree consumer;
revisit per one): `uname.release="mirshi"` marks the shim vs the kernel's `_AGNOS_VERSION`; `nodename="agnos"`
matches the kernel default; `sysinfo.procs` is mirshi's live agnos-process count vs the kernel's high-water.
The canonical layouts are the sibling `agnos` repo's `docs/development/agnos-userland-abi.md` §4.3/§4.4 +
`kernel/core/syscall.cyr` writers. See [ADR 0016](../adr/0016-info-getters-emulated-flock-executed.md).

⁷ **tty sizing (v1.9.0).** `winsize#60` is **supervisor-EMULATE**
([ADR 0017](../adr/0017-winsize-emulated-tiocgwinsz.md)) — the **entire direction-1 graphics surface** (there
is no `fbinfo`/`blit` in the agnos ABI). A pure supervisor return (no child buffer, like `uptime_ms#40`):
mirshi reads the controlling terminal's size via `TIOCGWINSZ` on its own stdio (the child inherits it) and
returns `(cols<<16)|rows` — cols high, rows low, matching the kernel's `fb_winsize` packing and darshana's
`tty_winsize` unpack. No tty (redirected stdio / a plain container) → an **80×24 virtual default**. mirshi
**always returns a usable size (never −1)** — faithful to real agnos (the framebuffer is always up on iron,
so `winsize` never −1 there; darshana treats a size as "is a tty"). Supervisor-side `ioctl` → no child-seccomp
delta; `--root`-orthogonal. See [ADR 0017](../adr/0017-winsize-emulated-tiocgwinsz.md).

⁸ **The agnos 1.57.13 band (v1.12.1).** The cyrius 6.7.11+ agnos stdlib issues three newer numbers; each
probes first and falls back on −1, so before v1.12.1 programs ran under mirshi with the pre-1.57.13 behaviour
and a stray `ENOSYS agnos#N` line. All three are **supervisor-EMULATE**, with no child buffer except #109's
`pvm_read` of the payload, so there is no child-seccomp delta.
- **`sock_send_dl#109`** rides the net band (`--net`; without it, ENOSYS like #48). The stdlib's socket write
  path (`sys_write` on a tagged fd, `tls_native`) probes it with `#109(conn, buf, 0, 0)` on the first write,
  which is why the conn check comes before the length check. The 8 s cap is the kernel's D6 window
  (`TCP_PROGRESS_US`).
- **`console_mode#110`** treats the host terminal as the console: the first of mirshi's fds 0/1/2 that is a tty
  (as for `winsize#60`; `fd_kind#111` answers CONSOLE for each). The mode is one global cell
  plus its **holder** (the process that last set a mode bit); it applies to whoever reads, and it dies with the
  holder on every death path (the trace loop's exit hook, and a lazy liveness check on every call), so a
  program killed with echo off leaves the tty echoing. `CM_NOECHO` clears `ECHO | ECHONL` and clearing it puts
  back the bits it found; `CM_NOECHO | CM_FLUSH` in one call is `TCSETSF`. If mirshi itself is ended by HUP, INT,
  QUIT or TERM while it hides the echo, a handler armed by the first hide gives the echo back and re-raises,
  so mirshi dies with the same status (not as a container's PID 1, and not for SIGKILL). With no tty on any of
  the three fds the mode is tracked and reported but nothing changes, so scripted input survives. With stdin
  piped and stderr on a terminal, that terminal is the console and the pipe keeps its bytes. While `kbscan#42`
  has the tty raw, the echo bits are left to it. mirshi restores the echo at exit.
- **`fd_kind#111`** answers mirshi's emulated signalfd / timerfd / epoll ids by slot (open → 7 / 9 / 8, freed →
  −1) **before** the kernel's 32-entry bound, because under mirshi they are `BASE + slot` ids rather than small
  fds. A real fd is duplicated into the supervisor with `pidfd_getfd`, `fstat`'d and asked `TCGETS`: a terminal
  is `FDK_CONSOLE`, another char device (`/dev/null`) `FDK_DEVICE`. A socket-tagged id (bit 30) is the stdlib's
  own handle → −1, as on the kernel.

See [ADR 0018](../adr/0018-agnos-1-57-13-band-fd-kind-console-mode-send-dl.md).

## The runnable surface (v1)

- **M1 — process + console**: `exit#0`, `write#1`, `read#5`, `getpid#2`, `mmap#27`/`munmap#28`,
  `sync#12`, `getrandom#45`, `time_unix#46`, `uptime_ms#40`, `sleep_ms#41`.
- **M2 — filesystem**: `open#7`, `close#6`, `lseek#58`, `dup#8`, `mkdir#9`, `rmdir#10`,
  `unlink#30`, `rename#31`, `link#32`, `stat#33`, `getdents#29`.

Everything else was **ENOSYS** at the v1.0 cut. Since then the **net band** (#47–57, #61, v1.1.0–v1.4.0
— footnote ²), **multi-process** (`spawn#3`/`waitpid#4` + `getpid#2` now coined, v1.5.0 — footnote ³),
the **signal band** (`pause#14`/`kill#16`/`sigprocmask#17`/`signalfd#18`, v1.6.0 — footnote ⁴), and the
**I/O-multiplexing band** (`epoll#19–21`/`timerfd#22–23`/`pipe#25`, v1.7.0 — footnote ⁵) shipped as post-v1
extensions, as were the **info-getters + advisory-locks band** (`getuid#15`/`uname#34`/`sysinfo#35`/`flock#59`,
v1.8.0 — footnote ⁶) and **tty sizing** (`winsize#60`, v1.9.0 — footnote ⁷). **Direction 1 is now
feature-complete**: every *defined, non-kernel-only* agnos syscall is handled. The only remaining ENOSYS rows
are the agnos-**kernel**-only ops (`mount#11`/`umount#24`/`reboot#13`/`write_boot_checkpoint#26` — permanent by
design). #36 / #38–39 / #44 and the agnos numbers past #63 that mirshi does not handle yet are the
[roadmap](../development/roadmap.md)'s 1.13 re-sync. The exec-band re-sync landed **#37 execwait + #43 spawn_path + #62 exec_redirect + #63 symlink**. What remains on the [roadmap](../development/roadmap.md) is
the **v2.0.0 direction-2 "swallow"** (Linux binaries on the agnos kernel).

## Known gaps (carried forward, documented not fixed)

- **`getdents#29`**: records overflowing the agnos buffer are **dropped** (the agnos call
  re-reads from the saved fd offset on the next call); `d_ino` u64 is **truncated to u32**
  in the agnos dirent. Bounded to a 4096-byte scratch page per call.
- **`stat#33`**: the agnos 48 B struct carries mode/nlink/size/ino/blocks/mtime; sub-second
  mtime nsec is dropped (agnos has no nsec field).
- **Multi-process (`spawn#3`/`waitpid#4`, ³)**: `sleep_ms#41` + blocking net I/O run in the
  single-threaded supervisor, so while one child blocks the others don't advance (**head-of-line
  blocking** — deferred rework); agnos `exit(>255)` is 8-bit-truncated by
  the host status word; a wait deadlock (self-wait / cycle) is broken to agnos −1, not diagnosed; the
  process tree is capped at `MAX_CHILDREN=16`. See [ADR 0013](../adr/0013-multiprocess-supervisor-fork-record-table.md).
- **Signal band (`pause#14`/`signalfd#18`, ⁴)**: `pause#14`'s 1 ms yield **head-of-line-blocks** other
  children for the quantum (the `sleep_ms#41` class); the signalfd is **non-blocking**, as on the kernel —
  a `read` with nothing pending returns 0 (the poll-with-`pause` idiom). Host-originated signals (a
  terminal Ctrl-C, a host `kill`) still bypass the agnos model ([roadmap](../development/roadmap.md)
  1.15.x). `SIGKILL`/`SIGSTOP` unmaskability is not special-cased (agnos delivers via signalfd, not
  default actions). See [ADR 0014](../adr/0014-signal-band-supervisor-emulated-masks-signalfd.md).
- **I/O-mux band (`epoll#19–21`/`timerfd#22–23`/`pipe#25`, ⁵)**: **socket-watching is best-effort** — epoll
  resolves a watched socket by `id & 7` → conn slot, exact for sequential server flows but divergent under
  connect-failure churn (a coordinated agnos+shim fix lands later; wait-time `SLOT_FREE`-revalidated). A
  **real child fd** (stdin, a pipe end) is **not epoll-watchable** (not supervisor-observable). A **blocking**
  pipe read with no writer wedges the single-threaded supervisor (write-before-read / self-pipe avoids it;
  the watchable/non-blocking pipe is the reserved `PIPE_BASE` follow-up). `epoll_wait`'s ≤1 ms `ppoll`
  head-of-line-blocks other children (the `pause#14` class); timerfd/signalfd reads are non-blocking. The
  ABI-ambiguity defaults (epoll mask=EPOLLIN, op 2=whole-clear, timerfd flags relative) await a real consumer.
  See [ADR 0015](../adr/0015-io-mux-emulated-epoll-timerfd-executed-pipe.md).
- **Info getters (`uname#34`/`sysinfo#35`, ⁶)**: `uname` **value assumptions** — `release="mirshi"` marks the
  shim (the real kernel writes `_AGNOS_VERSION`), `nodename="agnos"` matches the kernel default (no
  `sethostname` yet); `sysinfo.procs` is mirshi's live agnos-process count vs the kernel's `proc_count`
  high-water (a cosmetic stat). `uptime`/`totalram`/`freeram`/`cpus` are the real host facts (degrade to 0/1 if
  the host reads fail). All await confirmation against a real agnos consumer. See [ADR 0016](../adr/0016-info-getters-emulated-flock-executed.md).
- **The agnos 1.57.13 band (⁸)**: `console_mode#110`'s `CM_FLUSH` discards the tty's input at once, even a line
  another process is half-way through; the kernel waits for that reader to finish its line first. A SIGKILL of
  mirshi (or any fatal signal when it is a container's PID 1) leaves a hidden echo hidden. After a job-control
  stop the shell may restore its own tty modes, and mirshi does not hide the echo again on SIGCONT. `sock_send_dl#109` sends one chunk of at most 4096 bytes per call, like #48 (the
  caller loops).
