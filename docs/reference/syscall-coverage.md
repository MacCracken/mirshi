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
| 2 | getpid | EXECUTE | `getpid` (39) | number differs |
| 3 | spawn | EMULATE | — | multi-process (v1.5.0): supervisor forks a **traced** grandchild from the in-memory ELF (memfd + `execveat`), returns a coined agnos pid; handled at the loop level, not `agnos_to_linux_nr` |
| 4 | waitpid | EMULATE | — | multi-process (v1.5.0): blocks on the target agnos pid (parks the caller stopped — not the supervisor — until it exits), returns its exit code directly; loop-level, not `agnos_to_linux_nr` |
| 5 | read | EXECUTE | `read` (0) | number differs; EOF `0` passes |
| 6 | close | EXECUTE | `close` (3) | |
| 7 | open | EXECUTE | `open` (2) ¹ | path staged (NUL-term); `AO_*`→`O_*` ([`ao_to_o`](../../src/translate.cyr)); mode 0600 on `O_CREAT` |
| 8 | dup | EXECUTE | `dup` (32) | |
| 9 | mkdir | EXECUTE | `mkdir` (83) ¹ | path staged; mode 0700 |
| 10 | rmdir | EXECUTE | `rmdir` (84) ¹ | path staged |
| 11 | mount | ENOSYS | — | stub |
| 12 | sync | EXECUTE | `sync` (162) | |
| 13 | reboot | ENOSYS | — | |
| 14 | pause | ENOSYS | — | signals — post-v1 |
| 15 | getuid | ENOSYS | — | |
| 16 | kill | ENOSYS | — | signals — post-v1 |
| 17 | sigprocmask | ENOSYS | — | signals — post-v1 |
| 18 | signalfd | ENOSYS | — | signals — post-v1 |
| 19 | epoll_create | ENOSYS | — | epoll — post-v1 |
| 20 | epoll_ctl | ENOSYS | — | epoll — post-v1 |
| 21 | epoll_wait | ENOSYS | — | epoll — post-v1 |
| 22 | timerfd_create | ENOSYS | — | post-v1 |
| 23 | timerfd_settime | ENOSYS | — | post-v1 |
| 24 | umount | ENOSYS | — | stub |
| 25 | pipe | ENOSYS | — | post-v1 |
| 26 | write_boot_checkpoint | ENOSYS | — | agnos-kernel-only |
| 27 | mmap | EXECUTE | `mmap` (9) | a1=length → 6-arg synth: anon/private, `PROT_READ\|WRITE`, fd=-1, 2 MB round-up; fail→`0` |
| 28 | munmap | EXECUTE | `munmap` (11) | length 2 MB round-up (matches mmap granularity) |
| 29 | getdents | EXECUTE | `getdents64` (217) | one-page scratch staged; Linux→agnos dirent repack at exit (cap 4096) |
| 30 | unlink | EXECUTE | `unlink` (87) ¹ | path staged |
| 31 | rename | EXECUTE | `rename` (82) ¹ | two paths staged; a4=r10 |
| 32 | link | EXECUTE | `link` (86) ¹ | two paths staged; **HARDLINK** (agnos has no symlink syscall) |
| 33 | stat | EXECUTE | `stat` (4) ¹ | path staged; Linux 144 B → agnos 48 B repack at exit |
| 34 | uname | ENOSYS | — | |
| 35 | sysinfo | ENOSYS | — | |
| 36–39 | *(undefined)* | ENOSYS | — | gaps in the agnos ABI mirror |
| 40 | uptime_ms | EMULATE | — | `CLOCK_MONOTONIC` in the supervisor → ms |
| 41 | sleep_ms | EMULATE | — | `nanosleep` in the supervisor; ≤0 → 0; cap 1 h |
| 42–44 | *(undefined)* | ENOSYS | — | gaps in the agnos ABI mirror |
| 45 | getrandom | EXECUTE | `getrandom` (318) | `(buf,len,flags)` identical; number differs |
| 46 | time_unix | EXECUTE | `time` (201) | a1 forced NULL (seconds in rax); fail→`0` |
| 47 | sock_connect | EMULATE ² | — | net band client (v1.1.0): conn_id slot table + `--net-allow` egress |
| 48 | sock_send | EMULATE ² | — | net band client (v1.1.0): pvm-staged `send` (`MSG_NOSIGNAL`) |
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
| 59 | flock | ENOSYS | — | |
| 60 | winsize | ENOSYS | — | graphics — post-v1 |
| 61 | net_config | EMULATE ² | — | net band (v1.3.0): reads the real netns gateway/DNS/host-IP (field 1 netmask 0-unset) |

Any number > 61 (and the undefined gaps) → **ENOSYS**.

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

## The runnable surface (v1)

- **M1 — process + console**: `exit#0`, `write#1`, `read#5`, `getpid#2`, `mmap#27`/`munmap#28`,
  `sync#12`, `getrandom#45`, `time_unix#46`, `uptime_ms#40`, `sleep_ms#41`.
- **M2 — filesystem**: `open#7`, `close#6`, `lseek#58`, `dup#8`, `mkdir#9`, `rmdir#10`,
  `unlink#30`, `rename#31`, `link#32`, `stat#33`, `getdents#29`.

Everything else was **ENOSYS** at the v1.0 cut. Since then the **net band** (#47–57, #61) shipped as a
post-v1 extension under `--net` (v1.1.0–v1.4.0 — footnote ²). Still ENOSYS, as **planned post-v1 minors**
(see the [roadmap](../development/roadmap.md)): multi-process (#3/#4), signals (#14, #16–18),
epoll/timerfd/pipe (#19–25), info getters (#15/#34/#35), `flock#59`, and `winsize#60`.

## Known gaps (carried forward, documented not fixed)

- **`getdents#29`**: records overflowing the agnos buffer are **dropped** (the agnos call
  re-reads from the saved fd offset on the next call); `d_ino` u64 is **truncated to u32**
  in the agnos dirent. Bounded to a 4096-byte scratch page per call.
- **`link#32`**: hardlink only — agnos has **no symlink syscall**, so mirshi follows that
  surface (mirrors the ark-v2 finding).
- **`stat#33`**: the agnos 48 B struct carries mode/nlink/size/ino/blocks/mtime; sub-second
  mtime nsec is dropped (agnos has no nsec field).
