# mirshi — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures
> (durable); this file is **state** (volatile).

## Version

**1.5.0** — 2026-07-01. **Multi-process — the agnsh crown jewel** ([ADR 0013](../adr/0013-multiprocess-supervisor-fork-record-table.md)).
agnos `spawn#3` / `waitpid#4` / `getpid#2` now run: a parent spawns children from **in-memory ELF images** and
waits their exit codes, to arbitrary depth, under one supervisor. `_trace_run` is now a `wait4(-1, __WALL)`
demux over a fixed 16-slot **per-child record table**; `spawn#3` supervisor-forks a traced grandchild
(`process_vm_readv` the ELF → `memfd` → `execveat AT_EMPTY_PATH`; the child seccomp bound gains only
`execveat`); `waitpid#4` **parks** the caller (stopped, not the supervisor) until the target exits; `getpid#2`
returns the caller's **coined agnos pid** (root=1, opaque monotonic, never reused — bidirectional-ready).
A `MAX_CHILDREN=16` cap re-closes the process-storm vector (ADR 0006); a deadlock guard stops a self-wait/
cycle from wedging the single-threaded supervisor. Proven by `scripts/it/spawn.sh` / `waitpid.sh` / `getpid.sh`
/ `spawn_storm.sh` (cap + no-leak + 3-level grandchild depth); `spawn#3` + `waitpid#4` adversarially reviewed
(the deadlock wedge was found + fixed). **Known limits**: head-of-line blocking (`sleep`/blocking I/O in the
supervisor), 8-bit exit truncation, deadlock-break-to-−1 — all documented (ADR 0013). Pin → `6.3.22`.
**1.4.0** — Net band ICMP (the arc's finale): agnos `icmp_echo#55` round-trips via an **unprivileged**
`SOCK_DGRAM`+`IPPROTO_ICMP` ping socket (never `SOCK_RAW`/`CAP_NET_RAW`); egress-checked; RTT ms; fail-closed.
**The sovereign net band (#47–57, #61) is complete.**
**1.3.0** — Net band UDP + net_config: `udp_bind#51`/`send#52`/`recv#53`/`unbind#54` supervisor-emulated (a
`SLOT_UDP` in the unified slot table; per-datagram egress on send; the sender `addr_out` repack on recv);
`net_config#61` reads the **real container-netns config** (gateway from `/proc/net/route`, DNS from
`/etc/resolv.conf`, host-IP via a getsockname trick; netmask 0-unset). **1.2.0** — Net band TCP server: `sock_listen#56`/`accept#57`
supervisor-emulated; `close#50` on a listener reaps its children; ingress loopback-default (`--net-listen-any`
to expose). **1.1.0** — Net band TCP client (the first post-v1
expansion): `sock_connect#47`/`send#48`/`recv#49`/`close#50` supervisor-emulated (the conn_id slot table;
child never holds a socket fd; seccomp allowlist unchanged); egress **default-deny** (`--net`/`--net-allow`,
SSRF-hardened, brute-force-verified over all 2³²); proven by an agnos HTTP-GET round-trip. **1.0.0** — the
clean cut: AGNOS userland in Docker, no QEMU — a representative agnos CLI
userland (`hello`/`echo`/`catfile`/`ls`/`cp`) runs under mirshi in a plain `FROM scratch` container,
fan-out-ready, seccomp-bounded (`docker/smoke.sh`); the v1 definition met, capping the 0.6→0.9 quality
arc. 0.9.0 = freeze + docs cleanup: froze the v1 contracts — the per-number **syscall-coverage
matrix** ([`../reference/syscall-coverage.md`](../reference/syscall-coverage.md), test-pinned for
agnos# 0–61) + the **CLI contract** ([`../reference/cli.md`](../reference/cli.md)) + the
**boundary-discipline ADR** ([ADR 0011](../adr/0011-mirshi-qemu-iron-boundary-discipline.md)).
0.8.0 = optimizations: **exit-stop single-register I/O** ([ADR 0010](../adr/0010-ptrace-exit-stop-single-register-io.md),
~5–7 % off the syscall-dense tax, byte-identical) + a 0-alloc gate; ptrace stays the documented default.
0.7.1 = rootfs confinement
(`--root`, audit class-(c), [ADR 0009](../adr/0009-rootfs-confinement-openat2-in-child.md)):
`--root <dir>` confines the child's filesystem via `openat2 RESOLVE_IN_ROOT` (open) +
the `*at` family with lexical `sanitize_rootrel` (mutation/metadata) + `RESOLVE_NO_MAGICLINKS`;
the container vehicle stays namespace-confined. 0.7.0 = security sweep (audit + hardening:
seccomp proven default-deny, x32 mask, fail-closed install); 0.6.0 = hardening (rlimits /
group-stop / child-hang, ADRs 0006-0008); 0.5.0 = M4 seccomp-notify feasibility + benchmark
([ADR 0005](../adr/0005-seccomp-notify-feasibility.md)); 0.4.0 = M3 Docker vehicle
(functional v1 surface complete); 0.3.0 = M2 fs; 0.2.0 = M1 translation; 0.1.0 = M0 trap loop.

## Toolchain

- **Cyrius pin**: `6.3.22` (in `cyrius.cyml [package].cyrius`)

## Source

**M0 trap loop** (0.1.0) + **M1 core translation** (0.2.0). x86_64 Linux only.
`mirshi <agnos-elf>` runs (translates+executes); `--selftest-trace` is the M0
trap-log mode.

- `src/main.cyr` — supervisor entry: argv dispatch. `mirshi [--selftest-trace] <agnos-elf>`.
- `src/intercept.cyr` — the impure core: `fork`/`PTRACE_TRACEME`/`execve`, `_attach`,
  and the two loops — `_trace_log` (M0 `PTRACE_SYSEMU`, trap+log) and `_trace_run`
  (M1 `PTRACE_SYSCALL` enter/exit, translate+execute). Defines the ptrace ABI the
  Linux stdlib peer lacks (`SYS_PTRACE=101`, `PTRACE_*`, `WIFSTOPPED`/`WSTOPSIG`).
  0.8.0: the EXIT stop does single-register I/O — `PTRACE_PEEKUSER` reads only `rax`,
  `PTRACE_POKEUSER` writes it back only when the agnos return changed
  ([ADR 0010](../adr/0010-ptrace-exit-stop-single-register-io.md)).
- `src/decode.cyr` — pure decode (no syscalls): x86_64 `user_regs_struct` offsets,
  the agnos number→name/arity/pointer-arg tables, and `format_event`.
- `src/translate.cyr` — PURE agnos→Linux translation (unit-tested): number remap,
  return mapping, 2 MB mmap round-up + 6-arg synthesis, and the M2 fs helpers
  (`ao_to_o`, `dtype_to_agnos`, the stat 144→48 + getdents dirent repacks).
- `src/scratch.cyr` — M2 child-memory staging: `process_vm_readv`/`writev` + the
  red-zone `stage_at` (NUL-terminated paths / Linux structs into the stopped child).
- `src/dispatch.cyr` — the impure dispatcher: execute-in-child / emulate / ENOSYS
  rewrites (M1) + the 13 fs handlers incl. the stat/getdents exit-stop repack (M2).
- `src/seccomp.cyr` — M3 bounding seccomp: a classic-BPF allowlist of the
  translation's output syscalls, installed on the child (default-on in run mode).
- `src/limits.cyr` — 0.6.0 host-resource bounds: kernel-enforced child rlimits
  (`RLIMIT_AS` 1 GiB / `RLIMIT_NOFILE` 256) set before the seccomp filter, capping
  the `mmap#27` / `open#7` exhaustion vectors ([ADR 0006](../adr/0006-host-resource-bounds-child-rlimits.md)).
- `docker/` — the v1 vehicle: a `FROM scratch` image (mirshi + agnos tools, no
  QEMU), `build.sh`/`fanout.sh`/`smoke.sh`, and `tools/*.cyr`.

Translation model: execute-in-child via `PTRACE_SYSCALL` register rewrite
([`../adr/0002`](../adr/0002-execute-in-child-translation.md)); fs calls stage
paths in the child red zone + repack output structs at the exit stop
([`../adr/0003`](../adr/0003-fs-redzone-path-staging.md)).
- M1 set: `exit#0`, `write#1`, `read#5`, `getpid#2`, `mmap#27`/`munmap#28`, `sync#12`,
  `getrandom#45`, `time_unix#46`, `uptime_ms#40`, `sleep_ms#41`.
- M2 set: `open#7`, `close#6`, `lseek#58`, `dup#8`, `mkdir#9`, `rmdir#10`, `unlink#30`,
  `rename#31`, `link#32`, `stat#33`, `getdents#29`. Path policy = transparent pass-through by
  default; under `--root` the path surface is kernel-confined (0.7.1, [ADR 0009](../adr/0009-rootfs-confinement-openat2-in-child.md)).
  The full per-number contract is frozen in [`../reference/syscall-coverage.md`](../reference/syscall-coverage.md).
- Net band (1.1.0 client + 1.2.0 server + 1.3.0 UDP/net_config + 1.4.0 ICMP,
  [ADR 0012](../adr/0012-net-band-supervisor-emulated-conn-table.md)): `sock_*#47–50/56/57` + `udp_*#51–54`
  supervisor-emulated over a unified 8-slot `{fd, kind, parent}` table (TCP conn / TCP listen / UDP;
  `close#50` reaps a listener's children). `net_config#61` reads the real netns gateway/DNS/host-IP.
  `icmp_echo#55` opens a transient unprivileged `SOCK_DGRAM`+`IPPROTO_ICMP` ping socket, round-trips one echo
  under a bounded ~3s `ppoll`, and returns the RTT ms (no slot). Egress default-deny (`--net`/`--net-allow`,
  per-datagram on UDP, per-destination on ICMP); ingress loopback-default (`--net-listen-any`). **The net band
  is complete** — no net-band number (#47–57, #61) remains ENOSYS.
- Multi-process (1.5.0, [ADR 0013](../adr/0013-multiprocess-supervisor-fork-record-table.md)):
  `spawn#3`/`waitpid#4`/`getpid#2` supervisor-emulated over a `wait4(-1, __WALL)` demux loop + a fixed
  16-slot per-child record table. `spawn#3` supervisor-forks a traced grandchild from the in-memory ELF
  (`process_vm_readv` → `memfd` → `execveat`; child bound gains only `execveat`); `waitpid#4` parks the caller
  (stopped, not the supervisor) until the target exits; `getpid#2` returns the caller's coined agnos pid
  (root=1, opaque monotonic, never reused — bidirectional-ready). `MAX_CHILDREN=16` storm bound + a deadlock
  guard. Known limits: head-of-line blocking (`sleep`/blocking I/O), 8-bit exit truncation (ADR 0013).

## Tests

- `tests/mirshi.tcyr` — primary suite (smoke + the pure M0 decode/format layer + the M1/M2
  translation contract + the **frozen syscall-coverage** pin (`xlat-coverage`: every agnos#
  0–61's disposition) + the pure net helpers/egress policy (1.1.0) + net_config parsers (1.3.0) +
  the multi-process record table / storm bound / ELF-size bounds (1.5.0); **248 assertions**, hermetic)
- `scripts/it/m0_trap.sh` — M0 integration test: the real fork+ptrace trap path over
  `tests/fixtures/hi.cyr` vs the golden `tests/fixtures/hi.expected.log`.
- `scripts/it/m1_run.sh` — M1 integration test: agnos `hello`/`cat`/`exit42`/`heapuser`
  run under real translation (`heapuser` is the mmap-in-child regression gate).
- `scripts/it/m2_fs.sh` — M2 fs integration test: agnos open/read/write/close/cp/
  mkdir/rename/link/unlink/stat/getdents against a sandboxed temp rootfs (HOST EFFECTS).
- `docker/smoke.sh` — the **v1 docker gate**: build the `FROM scratch` `agnos-mirshi` image
  and run the representative userland (`hello`/`echo`/`catfile`/`ls`/`cp` — console + fs
  read/list/write) in plain containers (correct output, no qemu in image), plus a 4-container
  fan-out. The `scripts/it/*` gates + `docker/smoke.sh` are CI steps after `cyrius test`; the
  ptrace ITs need a same-uid child (no extra privilege on ubuntu-latest;
  `--cap-add=SYS_PTRACE --security-opt seccomp=unconfined` in a container).
- `scripts/it/fault_inject.sh` — 0.6.0 hardening gate (CI step, after M2): throws
  misbehaving/hostile children (bad pointers, SIGSEGV, unknown syscalls, syscall
  storm, spawn fork-bomb, and `mmap#27` / `open#7` resource-exhaustion storms) and
  asserts the supervisor stays stable + the host is untouched (9 cases).
- `scripts/it/groupstop.sh` — 0.6.0 hardening gate (CI step, after fault_inject): an
  external `SIGSTOP` to the agnos child (a ptrace group-stop) must leave the child
  runnable — mirshi resumes it and it runs to completion, no hang.
- `scripts/it/supervisor_hardening.sh` — 0.6.0 hardening gate (CI step, after
  groupstop): the supervisor's own robustness — mirshi's RSS stays flat under an
  emulated-timer (`uptime_ms#40`) storm (no per-call heap leak), and terminating
  mirshi mid-hang leaves no orphan / no zombie (`PTRACE_O_EXITKILL`).
- `scripts/it/alloc_clean.sh` — 0.8.0 optimization gate (CI step, after supervisor): the
  per-syscall hot path allocates NOTHING per translated call — storms the EXECUTE
  pass-through (`getpid#2`) and fs path-staging (`stat#33`) classes and asserts mirshi's
  RSS stays flat (the bump allocator never frees, so a per-call alloc is linear growth).
  Teeth-verified; complements supervisor_hardening's emulate-path (`uptime#40`) check.
- `scripts/it/confine.sh` — 0.7.1 path-confinement gate (CI step, after supervisor):
  under `--root`, `open#7` escapes (abs / `..` / symlink) are clamped to the root and
  path-mutation ops denied; self-validating (proves the escape leaks without `--root`).
- `scripts/it/cli.sh` — 0.9.0 CLI-freeze gate (CI step, after confine): pins the frozen CLI
  contract ([`../reference/cli.md`](../reference/cli.md)) — usage on misuse (no args / `--root`
  without a dir → exit 2) + the `EXECVE_FAILED` (127) exit code + the fail-closed `--net-allow`.
- `scripts/it/net_client.sh` — 1.1.0 net-band TCP-client gate (CI step, after cli): mirshi's
  emulated `sock_connect#47`/`close#50` establish + tear down a real TCP connection to a local
  server, and `--net-allow` egress is enforced (un-allowed dst → agnos -1). Needs python3.
- `scripts/it/net_io.sh` — 1.1.0 net-band send/recv gate (CI step, after net_client): an agnos
  HTTP-GET round-trip (`connect`/`send`/`recv`-loop-to-EOF/`close`) proving `send#48`/`recv#49` +
  the inverted-EOF end-to-end against a local server. Needs python3.
- `scripts/it/net_server.sh` — 1.2.0 net-band TCP-server gate (CI step, after net_io): an agnos
  server (`sock_listen#56`/`accept#57`/recv/send/`close#50`-reap) accepts a real python client and
  replies, in both bind modes (loopback default + `--net-listen-any`). Needs python3.
- `scripts/it/net_udp.sh` — 1.3.0 net-band UDP gate (CI step, after net_server): an agnos UDP client
  (`udp_bind#51`/`send#52`/`recv#53`/`unbind#54`) round-trips against a python echo server — the reply
  + the sender `addr_out` {ip,port} + per-datagram egress denial. Needs python3.
- `scripts/it/net_config.sh` — 1.3.0 net_config#61 gate (CI step, after net_udp): mirshi's netns
  gateway/DNS (from `/proc/net/route` + `/etc/resolv.conf`) match the environment's own files; netmask
  0-unset, bad field -1, `--net` gating. Needs python3.
- `scripts/it/net_icmp.sh` — 1.4.0 net-band ICMP gate (CI step, after net_config): an agnos client
  pings 127.0.0.1 under mirshi via the unprivileged `SOCK_DGRAM`+`IPPROTO_ICMP` path (RTT ≥ 0) and
  per-destination egress is enforced; SKIPs gracefully where `net.ipv4.ping_group_range` / the sandbox
  forbids unprivileged ICMP. Needs python3.
- `scripts/it/spawn.sh` — 1.5.0 spawn#3 gate (CI step, after net_icmp): an agnos parent reads a child
  ELF and `sys_spawn#3`s it (memfd + execveat of the in-memory ELF); both run under one supervisor.
- `scripts/it/waitpid.sh` — 1.5.0 waitpid#4 gate (after spawn): parent spawns + `waitpid#4`s the exact
  exit code via both park+wake (live child) and the zombie fast-path; reaped-pid + self-wait → −1.
- `scripts/it/getpid.sh` — 1.5.0 getpid#2 gate (after waitpid): the root sees agnos pid 1, a spawned
  child sees its own coined pid 2 (per-child pid model).
- `scripts/it/spawn_storm.sh` — 1.5.0 fork-storm/depth gate (after getpid): spawn past `MAX_CHILDREN=16`
  returns −1 (no host process leak), and a 3-level root→child→grandchild tree proves the flat table.
- `tests/mirshi.bcyr` — benchmark stub (no-op)
- `tests/mirshi.fcyr` — fuzz stub

## Dependencies

Direct (declared in `cyrius.cyml`):

- stdlib — string, fmt, alloc, io, vec, str, syscalls, assert, bench, args

## Consumers

Intended: the **agnos CI/test fleet** (multi-container userland-concurrency fan-out),
**cloud deployment** (agnos-as-a-Linux-container), and later the **Linux-on-agnos
swallow** layer. None wired yet (scaffold).

## Target & boundary

- mirshi itself is a **Linux-target** Cyrius binary; it supervises **agnos-target** ELFs.
- v1 scope = direction 1 (AGNOS→Linux), headless CLI, no QEMU. The net band (v1.1–v1.4) + multi-process
  (v1.5.0) shipped post-v1; signals / epoll-timerfd-pipe / winsize / the Linux→AGNOS swallow are the
  remaining planned minors (see the [roadmap](roadmap.md)).
- Complements QEMU+KVM (real kernel) + iron (hardware truth); does not replace them.

## Next

See [`roadmap.md`](roadmap.md) — M0–M3 (functional v1 surface) + M4 (seccomp-notify
feasibility + benchmark) done. Now the **pure-quality closing arc** toward v1.0:
**0.6.0 hardening** — ✅ shipped 2026-06-30:
- **Host-resource bounds** ([ADR 0006](../adr/0006-host-resource-bounds-child-rlimits.md))
  — kernel-enforced child rlimits cap the `mmap#27` / `open#7` exhaustion vectors;
  PID vector already closed by the seccomp allowlist. Verified firing on an unlimited
  host (mmap storm bounds at ~1 GiB, open storm at 253 fds).
- **Fault-injection harness** wired into CI as the hardening gate (9 cases), with the
  zombie check rewritten to find mirshi's grandchild agnos zombies (not `--ppid $$`).
- **Group-stop signal handling** ([ADR 0007](../adr/0007-group-stop-signal-handling.md))
  — both trace loops discriminate a ptrace group-stop via `PTRACE_GETSIGINFO` and
  suppress it (resume with no signal). Correctness/robustness, not a hang fix.
- **Child-hang robustness** ([ADR 0008](../adr/0008-child-hang-supervisor-robustness.md))
  — a hung child is handled by design (block-mirror + `PTRACE_O_EXITKILL` + `waitpid`
  status), no watchdog; the scoping fixed a real supervisor-emulate heap leak
  (`uptime_ms#40` / `sleep_ms#41` per-call alloc → one-time static).

**0.7.0 security sweep** — ✅ shipped 2026-06-30 (phased: *harden now, confine next*).
The [audit](../audit/2026-06-30-audit.md) (32 findings; **seccomp proven default-deny**;
TOCTOU safe-by-design; `mmap` synth hardened) + the cheap hardening — fail-**closed**
seccomp install, x32-bit mask, 0600/0700 create modes. The **blocker tier is class-(c)
path-escape** (no in-supervisor path confinement; bare-CLI child reaches arbitrary host
paths, PoC-confirmed) — bounded by the container mount NS in the v1 vehicle, fixed
properly by the **0.7.1** supervisor rootfs confinement.

**0.7.1 rootfs confinement** — ✅ shipped 2026-06-30:
`--root <dir>` confines the full path surface ([ADR 0009](../adr/0009-rootfs-confinement-openat2-in-child.md)),
kernel-enforced + unprivileged. Bite 1: `open#7` → `openat2 RESOLVE_IN_ROOT` (abs/traversal/
symlink clamped; all fd-based ops transitively confined). Bite 2: `mkdir`/`rmdir`/`unlink`/
`rename`/`link`/`stat` → the `*at` family with the path lexically sanitized
(`sanitize_rootrel`: strip `/`, reject `..` — unit-tested; brute-force-verified no bypass).
Bite 3: `RESOLVE_NO_MAGICLINKS` (block proc magic-link escapes). Gate `scripts/it/confine.sh`.
The Docker vehicle stays namespace-confined (no `--root` needed). The audit's class-(c)
blocker tier is closed.

**0.8.0 optimizations** — ✅ shipped 2026-06-30: measure-first hot-path work. The ~30 µs
per-syscall tax is dominated by the two `PTRACE_SYSCALL` stops (irreducible under ptrace); the
byte-identical lever is trimming the register I/O within them. **Exit-stop single-register I/O**
([ADR 0010](../adr/0010-ptrace-exit-stop-single-register-io.md)) — `PTRACE_PEEKUSER` reads only
`rax`, `PTRACE_POKEUSER` writes it back only when it changed (~5–7 % off the syscall-dense tax,
byte-identical). **0-alloc-per-syscall gate** `scripts/it/alloc_clean.sh` (teeth-verified).
Reconciled two unachievable roadmap premises: no transparent pass-through fast-path exists in
direction 1 (even `write#1` needs the `-errno`→`-1` remap), and the seccomp-notify hybrid stays
deferred-by-data → **ptrace is the documented default**
(see [ADR 0005](../adr/0005-seccomp-notify-feasibility.md)).

**0.9.0 freeze + docs cleanup** — ✅ shipped 2026-06-30 (no behavior change): froze the v1
contracts. The per-number AGNOS→Linux **syscall-coverage matrix** ([`../reference/syscall-coverage.md`](../reference/syscall-coverage.md))
— exhaustively test-pinned for agnos# 0–61 (`xlat-coverage`, 166 assertions) and adversarially
audited row-by-row vs the code. The **CLI contract** ([`../reference/cli.md`](../reference/cli.md))
— flags, modes, exit-code map — pinned by `scripts/it/cli.sh`. The **boundary discipline**
([ADR 0011](../adr/0011-mirshi-qemu-iron-boundary-discipline.md)): mirshi *complements, never
replaces* QEMU+KVM + iron, promoted from prose to a cited decision. Guides cross-linked; ADR
index complete (0001–0011); CHANGELOG complete from 0.1.0.

**1.0.0 — the clean cut** — ✅ shipped 2026-06-30: **AGNOS userland in Docker, no QEMU**
(direction 1, headless CLI). A representative agnos CLI userland (`hello`/`echo`/`catfile`/`ls`/`cp`
— console + fs read/list/write) runs as native Linux processes under mirshi in a plain `FROM scratch`
container, fan-out-ready + seccomp-bounded — proven end-to-end by `docker/smoke.sh` (5 tools + no-QEMU
+ 4-container fan-out). The **v1 definition is met**; the 0.6→0.9 quality arc (hardened · audited ·
confined · optimized · frozen) is the foundation. Registry publishing is a documented post-v1 ops step
([`../guides/docker-fanout.md`](../guides/docker-fanout.md)), not gated by the v1 definition.

**1.1.0 — net band, TCP client** — ✅ shipped 2026-06-30: the **first post-v1 expansion**
([ADR 0012](../adr/0012-net-band-supervisor-emulated-conn-table.md)). A sandboxed agnos child can open TCP
connections through mirshi — `sock_connect#47`/`send#48`/`recv#49`/`close#50` **supervisor-emulated** (an
8-slot `conn_id→host fd` table; the child never holds a socket fd; the seccomp allowlist unchanged). Egress
is **default-deny** (`--net`/`--net-allow`, SSRF-hardened, brute-force-verified over all 2³²). Proven by an
agnos HTTP-GET round-trip (`scripts/it/net_io.sh`) — the inverted `recv#49` EOF validated live; the
socket/send/recv handlers adversarially reviewed (no fd/slot leak, OOB, SIGPIPE-kill, or overflow).

**1.2.0 — net band, TCP server** — ✅ shipped 2026-06-30: agnos server tools accept inbound TCP through
mirshi — `sock_listen#56` (bind+listen) / `sock_accept#57`, supervisor-emulated over a unified 8-slot
`{fd, kind, parent}` table (conn / listen); `sock_close#50` on a listener **reaps its accepted children**.
Ingress is **loopback-only by default** (`--net-listen-any` binds all interfaces) — the safe posture, so a
sandboxed child's server isn't network-reachable unless asked. Proven by an agnos server accepting a real
client (`scripts/it/net_server.sh`, both bind modes); the server + reap handlers adversarially reviewed (no
fd/slot leak, double/cross-close, or OOB; the reap invariant pinned in a comment).

**1.3.0 — net band, UDP + net_config** — ✅ shipped 2026-06-30: agnos UDP tools (dig/DNS-class) send +
receive datagrams — `udp_bind#51`/`send#52`/`recv#53`/`unbind#54` supervisor-emulated (a `SLOT_UDP` in the
unified table; **per-datagram egress** on send; the sender `addr_out` {ip,port} repack on recv; no EOF).
`net_config#61` reads the **real container-netns config** (gateway from `/proc/net/route`, DNS from
`/etc/resolv.conf`, host-IP via a getsockname trick; netmask 0-unset; bad field -1). Proven by an agnos UDP
round-trip + net_config matching the environment's files (`scripts/it/net_udp.sh` + `net_config.sh`); the UDP
+ net_config handlers adversarially reviewed (no leak/OOB/over-read/crash).

**1.4.0 — net band, ICMP (the arc's finale)** — ✅ shipped 2026-06-30: agnos `icmp_echo#55` (yo/ping) RTTs a
host through mirshi via an **unprivileged** `SOCK_DGRAM`+`IPPROTO_ICMP` ping socket (**never** `SOCK_RAW`/
`CAP_NET_RAW` — a privilege a sandbox deputy must not hold). A **pure** supervisor op (no child buffer):
egress-check → one echo request → bounded ~3s `ppoll(POLLIN)` → the monotonic-clock RTT ms (≥0; sub-ms=0);
fail-closed to −1 on any error (`ping_group_range` denial / send fail / timeout). Proven live
(`scripts/it/net_icmp.sh`; `icmp_echo(1.1.1.1)`=6 ms vs host `ping`=6.48 ms; SKIPs where the kernel forbids
unprivileged ICMP); the handler adversarially reviewed (**CLEAN** — no fd leak on any exit, fail-closed). **The
sovereign net band (#47–57, #61) is now COMPLETE.**

**Post-v1** (see [`roadmap.md`](roadmap.md) planned minors): the **sovereign net band** #47–57/#61
(TCP client + server + UDP + net_config + ICMP, 1.1–1.4) **and multi-process** (`spawn#3`/`waitpid#4`/
`getpid#2` — the agnsh crown jewel, v1.5.0) are **complete**. Remaining planned minors: **signals**
(`pause#14`/`kill#16`/`sigprocmask#17`/`signalfd#18` — v1.6.0, next); **I/O mux** (epoll #19–21 /
timerfd #22–23 / `pipe#25`); **info getters + `flock#59`** (`getuid#15`/`uname#34`/`sysinfo#35`);
**`winsize#60`** tty sizing; and **direction 2** — the Linux→AGNOS "swallow" (run Linux binaries on the
agnos kernel — the permanent compat layer), v2+. Each is
its own validation surface; the translation core built here runs from both
sides. The mirshi/QEMU/iron discipline ([ADR 0011](../adr/0011-mirshi-qemu-iron-boundary-discipline.md))
holds: mirshi owns userland + Linux-compat-at-scale, never the agnos kernel or hardware truth.
