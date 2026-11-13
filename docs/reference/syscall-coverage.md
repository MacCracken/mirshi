# mirshi — syscall coverage matrix (the frozen translation contract)

> **Frozen at v0.9.0.** This is the canonical, per-number contract for direction 1
> (AGNOS→Linux): every agnos syscall is either **mapped** to a Linux peer (executed in
> the child), **emulated** in the supervisor, rewritten as the special **exit**, or
> returns **ENOSYS**. The source of truth is the code (`src/translate.cyr` +
> `src/dispatch.cyr` + `src/decode.cyr`); this table mirrors it and is **pinned by
> tests** (`tests/mirshi.tcyr`: `xlat-nr`, `fs-nr`, `xlat-coverage` assert
> `agnos_to_linux_nr` for every number 0–63 and each handled number above it, plus boundaries). Changing a row is a
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

## Matrix (agnos# 0–63, and the handled numbers above)

| # | name | disp. | Linux peer | notes |
|--:|------|:-----:|-----------:|-------|
| 0 | exit | EXIT | `exit_group` (231) | code in a1; terminates, no exit stop |
| 1 | write | EXECUTE | `write` (1) | `(fd,buf,len)` identical; err→`-1` |
| 2 | getpid | EMULATE ³ | — | multi-process (v1.5.0): returns the caller's **coined agnos pid** (root=1), not host `getpid`(39) — else children would see clashing host pids; loop-supplied `_cur_rec` |
| 3 | spawn | EMULATE ³ | — | multi-process (v1.5.0): supervisor forks a **traced** grandchild from the in-memory ELF (memfd + `execveat`), returns a coined agnos pid; handled at the loop level, not `agnos_to_linux_nr` |
| 4 | waitpid | EMULATE ³ | — | multi-process (v1.5.0): blocks on the target agnos pid (parks the caller stopped — not the supervisor — until it exits), returns its exit code directly; loop-level, not `agnos_to_linux_nr` |
| 5 | read | EXECUTE | `read` (0) | number differs; EOF `0` passes |
| 6 | close | EXECUTE | `close` (3) | **v1.12.3:** fd < 0 or ≥ 32 → −1 (the kernel's table); a free fd < 32 → 0, not EBADF; a closed emulated fd → 0. |
| 7 | open | EXECUTE | `open` (2) ¹ | path staged (NUL-term); `AO_*`→`O_*` ([`ao_to_o`](../../src/translate.cyr)); mode 0600 on `O_CREAT` **v1.12.3:** `AO_MODE` (0x4000) sets the create mode from bits 32..63 (above 07777 → −1); a path with an interior NUL, or of length 0, → −1. |
| 8 | dup | EMULATE | — | **v1.12.3:** the kernel's identity — returns its argument (Linux `dup` minted fds the kernel never would) |
| 9 | mkdir | EXECUTE | `mkdir` (83) ¹ | path staged; mode 0700 |
| 10 | rmdir | EXECUTE | `rmdir` (84) ¹ | path staged |
| 11 | mount | ENOSYS | — | stub |
| 12 | sync | EXECUTE | `sync` (162) | |
| 13 | reboot | ENOSYS | — | |
| 14 | pause | EMULATE ⁴ | — | signals (v1.6.0): **bounded yield** — returns 0 (idle a quantum, or immediately if a deliverable signal is pending); never wedges the recv poll loop; loop-level |
| 15 | getuid | EMULATE ⁶ | — | info getters (v1.8.0): `getuid`/`geteuid` → **0** (always root; never the host uid) |
| 16 | kill | EMULATE ⁴ | — | signals (v1.6.0): sets `1<<sig` in the target's pending mask; self/direct-child scope, pid 0 protected, sig 1..63; loop-level **v1.12.3:** signal 0 is the kernel's probe → 0 (authorized target, nothing posted). |
| 17 | sigprocmask | EMULATE ⁴ | — | signals (v1.6.0): read/apply/write the caller's blocked mask (`SIG_BLOCK`/`UNBLOCK`/`SETMASK`), oldset round-trip. **v1.12.2:** `set` is required (NULL → −1, as on the kernel); `how` ≥ 2 stores the set verbatim |
| 18 | signalfd | EMULATE ⁴ | — | signals (v1.6.0): opaque `SIGFD_BASE+slot` fd (per-child slot table). **v1.12.2, the kernel's contract:** every call is a new signalfd (fd and flags not consulted); `read#5` stores the lowest pending & watched signal — the blocked mask not consulted — as a **4-byte** number and answers 4, 0 when nothing is pending, −1 for a count < 4; `close#6` frees the slot |
| 19 | epoll_create | EMULATE ⁵ | — | I/O-mux (v1.7.0): a per-child epoll instance (`EPOLL_BASE+slot`), an 8-watch list of raw agnos ids |
| 20 | epoll_ctl | EMULATE ⁵ | — | I/O-mux (v1.7.0): op 1=ADD (dedup, 8-cap), op 2=CLEAR (whole list; fd ignored) **v1.12.3:** an unknown op → 0 (the kernel falls through); op 3 SET → −1 until implemented. |
| 21 | epoll_wait | EMULATE ⁵ | — | I/O-mux (v1.7.0): heterogeneous **bounded-yield** readiness — `ppoll` sockets + mask-test signalfds + clock-test timerfds; packed 12 B events; never parks **v1.12.3:** `max < 0`, reserved bits above 32, a timed wait with room for no record, or a NULL events pointer → −1. |
| 22 | timerfd_create | EMULATE ⁵ | — | I/O-mux (v1.7.0): a supervisor-side deadline (`TIMERFD_BASE+slot`); no real Linux timerfd |
| 23 | timerfd_settime | EMULATE ⁵ | — | I/O-mux (v1.7.0): arm a `CLOCK_MONOTONIC` deadline (seconds; capped); `read#5` delivers the expiration count |
| 24 | umount | ENOSYS | — | stub |
| 25 | pipe | EXECUTE ⁵ | `pipe2` (293) | I/O-mux (v1.7.0): run **in the child** (`O_CLOEXEC`); exit-stop 2×i32→2×u64 repack; the sole child-bound delta. Not via `agnos_to_linux_nr` (intercepted before it) |
| 26 | write_boot_checkpoint | ENOSYS | — | agnos-kernel-only |
| 27 | mmap | EXECUTE | `mmap` (9) | a1=length → 6-arg synth: anon/private, `PROT_READ\|WRITE`, fd=-1, 2 MB round-up; fail→`0` **v1.12.3:** a length ≤ 0 is one 2 MB unit (the kernel's floor), as is `munmap#28`'s. |
| 28 | munmap | EXECUTE | `munmap` (11) | length 2 MB round-up (matches mmap granularity) |
| 29 | getdents | EXECUTE | `getdents64` (217) | one-page scratch staged; Linux→agnos dirent repack at exit (cap 4096) **v1.12.3:** records padded to 8 (the kernel's writer); a buffer that holds no record, or a negative size, → −1. |
| 30 | unlink | EXECUTE | `unlink` (87) ¹ | path staged |
| 31 | rename | EXECUTE | `rename` (82) ¹ | two paths staged; a4=r10 |
| 32 | link | EXECUTE | `link` (86) ¹ | two paths staged; a **HARDLINK** (symlinks are `symlink#63`) |
| 33 | stat | EXECUTE | `stat` (4) ¹ | path staged; Linux 144 B → agnos 48 B repack at exit |
| 34 | uname | EMULATE ⁶ | — | info getters (v1.8.0): synthesized agnos-native 64 B struct (4×16 = sysname=AGNOS/nodename=agnos/release=mirshi/machine=x86_64); `len<64`→−1 |
| 35 | sysinfo | EMULATE ⁶ | — | info getters (v1.8.0): agnos-native 40 B struct (5×u64 = uptime/totalram/freeram/procs/cpus) from live host values; `len<40`→−1. **v1.11.3:** the kernel's length tiers — writes exactly 40 / 104 (+per-core user/kernel ticks at +40, host `/proc/stat`) / 200 (+BLK-tag sectors at +104, zero) / 208 (+`sched_kicks` at +200, zero) bytes |
| 36 | klug | EMULATE ⁹ | — | **v1.13.0:** 0 bytes — mirshi keeps no agnos kernel log, and the host's (dmesg) is never read; `len` < 0 → −1. ⚠ Linux #36 is `getitimer` |
| 37 | execwait | EMULATE | — | **exec band (v1.10.0):** load a static ELF from a PATH + run to completion, return its exit code (agnsh's `run`). Loop-level: fork a traced grandchild that execve's the path token via `_child_exec` (the top-level program's path), then park the caller on the coined pid until it exits — the `spawn#3` + `waitpid#4` fusion. cmdline `"PATH args.."` space-tokenized, argv[0]=path |
| 38–39 | fbinfo / blit | ENOSYS | — | the framebuffer pair, left out of the 1.13 re-sync on purpose: a hardware band, so permanent ENOSYS or a headless emulation is an open decision ([roadmap](../development/roadmap.md) 1.x). `winsize#60` is the graphics surface mirshi answers |
| 40 | uptime_ms | EMULATE | — | `CLOCK_MONOTONIC` in the supervisor → ms |
| 41 | sleep_ms | EMULATE | — | `nanosleep` in the supervisor; 0 → 0, **negative → −1** (v1.12.3, the kernel); cap 1 h |
| 42 | kbscan | EMULATE | — | **v1.11.0:** the raw Set-1 scancode drain, synthesized from mirshi's stdin (the tty armed raw + non-blocking on the first call; a pipe works too) — cyim's per-key channel |
| 43 | spawn_path | EMULATE | — | **exec band (v1.10.1):** NON-blocking from-disk spawn — fork a traced grandchild that execve's the path (the `_spawn_from_path` core, shared with execwait#37), inject the coined agnos pid NOW; the caller reaps it via `waitpid#4`. The cyrius stdlib `exec_*` path (`_agnos_spawn_path` + `sys_waitpid`) **v1.12.3:** `a2 = len | flags` decoded — `SPAWN_F_ARGV` (bit 16, a NUL-separated argv blob, 2..1024 B, 1..16 entries) and `SPAWN_F_CLEANFD` (bit 17); −2 table full, −6 bad arguments or more than 16 tokens; under `--root` the path resolves inside the root. |
| 44 | sched_yield | EMULATE ⁹ | — | **v1.13.0:** 0 (the ptrace stop is already a scheduling point). ⚠ Linux #44 is `sendto` |
| 45 | getrandom | EXECUTE | `getrandom` (318) | `(buf,len,flags)` identical; number differs **v1.12.3:** a length ≤ 0 → 0 and the flags are ignored, as on the kernel (EMULATE for that case). |
| 46 | time_unix | EXECUTE | `time` (201) | a1 forced NULL (seconds in rax); fail→`0` |
| 47 | sock_connect | EMULATE ² | — | net band client (v1.1.0): conn_id slot table + `--net-allow` egress **v1.12.3:** port 1..65535, else −1. |
| 48 | sock_send | EMULATE ² | — | net band client (v1.1.0): pvm-staged `send` (`MSG_NOSIGNAL`). **v1.12.2:** the ~8 s window expiring with nothing sent answers 0 (the committed count, the kernel's D6 rule), not −1 |
| 49 | sock_recv | EMULATE ² | — | net band client (v1.1.0): **inverted EOF** (0=WOULD_BLOCK, −1=EOF) |
| 50 | sock_close | EMULATE ² | — | net band (v1.1.0): free the slot; a LISTEN slot reaps children (v1.2.0) |
| 51 | udp_bind | EMULATE ² | — | net band UDP (v1.3.0): bound DGRAM socket; loopback-default **v1.12.3:** port 1..65535; no `SO_REUSEADDR`, so a bound port → −1. |
| 52 | udp_send | EMULATE ² | — | net band UDP (v1.3.0): per-datagram egress; packed `(sport<<16)\|dport` **v1.12.3:** len ≤ 0 → 0, len > 1472 → −1, then buffer / source port / egress; answers the frame length (payload + 42). |
| 53 | udp_recv | EMULATE ² | — | net band UDP (v1.3.0): sender `addr_out` {ip@0, port@8}; no EOF **v1.12.3:** maxlen ≤ 0 → 0 first; the datagram is taken only after `buf` and `addr_out` were written (a bad one → −1, datagram kept). |
| 54 | udp_unbind | EMULATE ² | — | net band UDP (v1.3.0): free the SLOT_UDP |
| 55 | icmp_echo | EMULATE ² | — | net band ICMP (v1.4.0): unprivileged `SOCK_DGRAM`+`IPPROTO_ICMP` ping; RTT ms (≥0, sub-ms=0) / −1; bounded ~3s |
| 56 | sock_listen | EMULATE ² | — | net band server (v1.2.0): bind+listen; loopback-default (`--net-listen-any`) **v1.12.3:** the argument decoded as the kernel does (port 1..65535, class 0 ANY / 1 LOOPBACK, other bits 0); a LOOPBACK listener stays on 127.0.0.1 under `--net-listen-any`. |
| 57 | sock_accept | EMULATE ² | — | net band server (v1.2.0): `accept4` → a fresh conn_id |
| 58 | lseek | EXECUTE | `lseek` (8) | `(fd,offset,whence)` identical **v1.12.3:** a whence outside 0..2 → −1. |
| 59 | flock | EXECUTE ⁶ | `flock` (73) | advisory locks (v1.8.0): execute-in-child, op codes identical (SH/EX/UN/+NB); the sole child-bound delta. **v1.12.2:** an fd that is not a file or a directory, or outside [0, 32), is −1 before the EXECUTE, as on the kernel |
| 60 | winsize | EMULATE ⁷ | — | tty sizing (v1.9.0): `(cols<<16)\|rows` from the controlling terminal's `TIOCGWINSZ` (80×24 default if no tty); the whole direction-1 graphics surface |
| 61 | net_config | EMULATE ² | — | net band (v1.3.0): reads the real netns gateway/DNS/host-IP (field 1 netmask 0-unset) **v1.12.3:** fields 4..11 (the kernel's counters) → 0. |
| 62 | exec_redirect | EMULATE | — | **exec band (v1.10.2):** one-shot ARM — the next from-path exec (execwait#37 / spawn_path#43) routes the child's src_fd (e.g. 1=stdout) to the CALLER's dst_fd. Consumed in `_spawn_from_path`: **steal dst_fd from the caller via `pidfd_getfd`** (files AND pipes) + `dup3` onto src_fd in the grandchild. No restore — mirshi's child is a separate process |
| 63 | symlink | EXECUTE | `symlink` (88) | **exec band (v1.10.2):** two paths staged; target is a **literal string**, linkpath a real path (same `(path,len,path,len)` shape as `link#32`). `--root` deferred (a raw target isn't a confinable path) |

| 81 | readdir | EMULATE ⁹ ¹ | — | **v1.13.0:** `(path, buf, max)` → records. The path is a NUL-terminated string in a 256-byte window (all of it readable and a NUL inside, else −1); then `max` ≤ 0 → 0, > 16777216 → −1; not found (the empty path included) → −2, not a directory → −4. 64-byte records: the name (≤ 62 bytes, cut on a UTF-8 boundary) + NUL, zero-filled, byte 63 = `RD_DIR` 1 \| `RD_CUT` 2; `.`/`..` skipped; always from the top. The supervisor opens and walks the directory (`getdents64`; a `DT_UNKNOWN` entry is asked with `newfstatat` no-follow). ⚠ Linux #81 is `fchdir` |
| 95 | uptime_us | EMULATE | — | **v1.11.3:** `CLOCK_MONOTONIC` in the supervisor → µs, the same epoch as `uptime_ms#40` (never −1: the host clock always works). ⚠ Linux #95 is `umask` — the skip keeps it from running in the child |
| 99 | proclist | EMULATE ⁹ | — | **v1.13.0:** `(buf, max)` → records; `max` < 1 or > 16777216 → −1. One 64-byte record per process in mirshi's table, in table order: +0 pid, +8 state (2 the caller, 1 another live one, 6 parked in `waitpid#4`/`execwait#37`, 7 exited and unreaped), +16 ppid, +24 the 32-byte NUL-padded name (the basename of the target / of `#37`/`#43`'s path; empty for `spawn#3`), +56 0. ⚠ Linux #99 is `sysinfo` |
| 100 | icmp_echo_ex | EMULATE ² | — | **v1.13.0:** `icmp_echo#55` with the caller's reply wait: `timeout_ms` ≤ 0 → the 3 s default, clamped to 60 s. ⚠ Linux #100 is `times` |
| 101 | readdir_at | EMULATE ⁹ ¹ | — | **v1.13.0:** `#81` with a cursor (`a4` = r10, an i64 read and written): after the `max` checks the cursor must be readable (−1); `*cursor` < 0 → 0, untouched. A spent budget parks the cursor on the record not taken; the end of the directory stores −1. The cursor is the Linux `d_off` cookie (opaque; `lseek` to it when > 0), so `#81`'s byte-offset rules and −5 do not apply. ⚠ Linux #101 is `ptrace` |
| 102 | lstat | EXECUTE ¹ | `lstat` (6) | **v1.13.0:** `stat#33` without following the final symlink — the same staging and 144 → 48 B repack. ⚠ Linux #102 is `getuid` |
| 103 | statfs | EMULATE ⁹ ¹ | — | **v1.13.0:** `(path, pathlen, buf)` → 0 / −1. The path is read as `stat`'s is (1..4096 bytes, no interior NUL) and must resolve. 32 bytes = 4 × u64: bsize (Linux `f_frsize`, or `f_bsize` when 0), blocks, bfree, bavail — Linux `statfs` on the path, or `fstatfs` on it opened inside the root. ⚠ Linux #103 is `syslog` |
| 104 | mountlist | EMULATE ⁹ | — | **v1.13.0:** `(buf, max)` → 1; `max` < 1 or > 13421772 → −1. One 80-byte record: backend 1 (ext2), prefixlen 1, `"/"` NUL-padded to 64. The host's mount table is never read. ⚠ Linux #104 is `getgid` |
| 106 | sock_peer | EMULATE ² | — | **v1.13.0:** `conn_id` → `(peer_ip << 16) \| peer_port` (kernel-ip4 form, host-order port) for one of the caller's live connections (`getpeername`); a listener, a UDP socket, a free slot or a failed `getpeername` → −1. ⚠ Linux #106 is `setgid` |
| 107 | spawn_limits | EMULATE ⁹ | — | **v1.13.0:** −1, the kernel's "not supported" answer, until mirshi enforces the caps (the process band, [roadmap](../development/roadmap.md) 1.13.2). ⚠ Linux #107 is `geteuid` |
| 108 | sched_yield_to | EMULATE ⁹ | — | **v1.13.0:** 0 for self, a live direct child or the live direct parent (the kernel's `yt_auth_ok`); anything else → −1. ⚠ Linux #108 is `getegid` |
| 109 | sock_send_dl | EMULATE ² ⁸ | — | **v1.12.1 (agnos 1.57.13):** `sock_send#48` with a caller ceiling. Conn checked first (−1 even for len ≤ 0), len ≤ 0 → 0; `timeout_us` 0 = exactly #48, < 0 = one non-blocking attempt, > 0 = wait ≤ min(ceiling, 8 s) for space; an expired wait → **0** (committed count), not −1. ⚠ Linux #109 is `setpgid` |
| 110 | console_mode | EMULATE ⁸ | — | **v1.12.1 (agnos 1.57.13):** `(set, clear)` → the console's previous flags / −1. `CM_NOECHO` hides echo on the host tty and **dies with its holder**, `CM_FLUSH` = `tcflush(TCIFLUSH)`, `CM_NOSERIAL` per process (reported only). Unknown bits → −1 with nothing changed. ⚠ Linux #110 is `getppid` |
| 111 | fd_kind | EMULATE ⁸ | — | **v1.12.1 (agnos 1.57.13):** fd → `FdKind` (1 CONSOLE … 10 DEVICE) / −1. Emulated event fds by slot; a real fd via `pidfd_getfd` + `fstat` + `TCGETS` in the supervisor; fd < 0, ≥ 32 or closed → −1. ⚠ Linux #111 is `getpgrp` |
| 115 | fsync | EXECUTE ⁹ | `fsync` (74) | **v1.13.0:** fd < 0 or ≥ 32 → −1 without a call; otherwise Linux `fsync` on the child's fd, its errors → −1 (a pipe or a terminal is EINVAL there, as the kernel refuses what is not a file or a directory). ⚠ Linux #115 is `getgroups` |

**#62 exec_redirect + #63 symlink are handled** (the exec-band re-sync, v1.10.x), as are `uptime_us#95` (v1.11.3), the agnos 1.57.13 band `sock_send_dl#109` / `console_mode#110` / `fd_kind#111` (v1.12.1 — footnote ⁸), and the 1.13.0 re-sync band `#81` / `#99`–`#104` / `#106`–`#108` / `#115` (footnote ⁹). Any other number > 63 (and the undefined 0–61 gaps) → **ENOSYS**.

¹ **Under `--root`** ([ADR 0009](../adr/0009-rootfs-confinement-openat2-in-child.md), amended v1.12.3):
`open#7` runs in the child as `openat2(ROOTFD, path, RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS)`. Since v1.12.3
`mkdir` / `rmdir` / `unlink` / `rename` / `link` / `stat` / `readlink` run **in the supervisor**: each resolves
its parent directory with the same `openat2` flags on a supervisor-held root fd, then calls `mkdirat` /
`unlinkat` / `renameat2` / `linkat` / `readlinkat` on that fd (`stat`: `openat2(O_PATH)` + `fstat`; v1.13.0
`lstat#102` the same with `O_NOFOLLOW`, so a final symlink is described, not followed). `..`
clamps at the root, as on the kernel. The v1.13.0 supervisor-side path calls resolve the same way:
`readdir#81` / `readdir_at#101` open the directory with `openat2(O_DIRECTORY, RESOLVE_IN_ROOT |
RESOLVE_NO_MAGICLINKS)`, and `statfs#103` `fstatfs`es the path opened inside the root. The fd-based ops (`read`/`write`/`lseek`/`close`/`getdents`) ride
fds from a confined `open`, and the child holds no other fd: it starts with 0–2 and ROOTFD only. Without
`--root`, the peers in the table above apply (transparent pass-through).

² **Net band (post-v1 extension, `--net`).** #47–50 (TCP client, v1.1.0), #56/#57 (TCP server,
v1.2.0), #51–54 (UDP) + `net_config#61` (v1.3.0), and `icmp_echo#55` (ICMP, v1.4.0) are
**supervisor-EMULATE** ([ADR 0012](../adr/0012-net-band-supervisor-emulated-conn-table.md)): the
supervisor owns the sockets via an 8-slot `{fd,kind,parent}` table (TCP conn / TCP listen / UDP);
the child never holds a socket fd. (`icmp_echo#55` takes no slot — it opens a transient
unprivileged `SOCK_DGRAM`+`IPPROTO_ICMP` ping socket, round-trips one echo under a bounded ~3s
`ppoll`, and closes it.) Enabled by `--net` / `--net-allow` (egress default-deny) /
`--net-listen-any` (ingress loopback-default). **Without `--net` they return ENOSYS** (agnos `-1`).
v1.13.0 adds `icmp_echo_ex#100` (#55 with the caller's reply wait) and `sock_peer#106` (the peer of a
caller-owned connection, from `getpeername` on its slot's socket), under the same `--net` rule.
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

⁹ **The 1.13.0 re-sync band.** Thirteen agnos numbers that fell to ENOSYS up to v1.12.3, each checked against
its kernel arm at agnos `aef48206` (1.57.19). Every one is a **different Linux call**, so each is answered in the
supervisor or renumbered — never passed through. The handlers are in `src/band_resync.cyr` (the net pair in
`src/band_net.cyr`, `lstat` beside `stat` in `src/band_fs.cyr`). The child-seccomp delta is `lstat` (6) and
`fsync` (74); everything else runs in the supervisor.
- **`readdir#81` / `readdir_at#101`** open the directory in the supervisor (from mirshi's working directory —
  the child's, since mirshi has no `chdir` yet — or inside the root) and walk it with `getdents64`. The kernel
  validates the whole `max × 64`-byte buffer up front; mirshi writes the records it produces and answers −1 at
  the first it cannot write. `readdir_at`'s cursor is the host's `d_off` cookie, not ext2's byte offset: a
  caller treats it as opaque (0 starts, −1 ends), as the stdlib does, and a cookie the directory refuses to
  seek to reads as one past the end (0, cursor −1).
- **`proclist#99`** lists mirshi's own processes only — there is no kmain, idle or kernel thread to show — and
  `+56` is 0 ("neither cpu ticks nor rss present"): mirshi tracks neither.
- **`mountlist#104`** reports one ext2 root, and **`klug#36`** an empty log: the host's mount table and kernel
  log are never read.
- **`spawn_limits#107`** answers −1 until the caps are enforced (1.13.2); the cyrius stdlib treats −1 as
  "this kernel cannot cap a child".
- **`sched_yield#44` / `sched_yield_to#108`** do not yield the host CPU: the child is already stopped in ptrace.
  `#108`'s authority is the kernel's: self, a live direct child, or the live direct parent.

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
design). `fbinfo#38` / `blit#39` and the hardware bands are an open 1.x decision; the agnos numbers past #63
that mirshi does not handle yet (`#71–74`, `#96–98`, `#112–113`, …) are the [roadmap](../development/roadmap.md)'s
1.13.x re-sync, whose cheap band landed in v1.13.0 (`#36`, `#44`, `#81`, `#99`–`#104`, `#106`–`#108`, `#115` —
footnote ⁹). The exec-band re-sync landed **#37 execwait + #43 spawn_path + #62 exec_redirect + #63 symlink**. What remains on the [roadmap](../development/roadmap.md) is
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
