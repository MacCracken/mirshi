# mirshi — Roadmap

> Milestone plan through v1.0. State lives in [`state.md`](state.md); this file is the
> sequencing — what ships, in what order, against what gates.
>
> **v1.0 = "AGNOS + mirshi runs in a plain Docker container, no QEMU"** (user, 2026-06-29):
> agnos-compiled userland runs as native Linux processes under mirshi's syscall translation,
> shared host kernel, no full-system emulation. This is **direction 1 (AGNOS→Linux)** of the
> mirror-shim; direction 2 (Linux→AGNOS swallow) is v2+.
>
> **Discipline** ([[feedback_qemu_test_agnos_userland]]): mirshi runs agnos userland on the
> *host* Linux kernel — it validates **userland concurrency + Linux-app compat at scale**, NOT
> the agnos kernel's own SMP scheduler / net stack. It **complements, never replaces** QEMU+KVM
> (real kernel) + iron (hardware truth). Each surface owns a distinct bug class —
> [ADR 0011](../adr/0011-mirshi-qemu-iron-boundary-discipline.md).

## The core technical problem

agnos redefines the `Sys` enum to its own numbers (`exit`=0 vs Linux 60, the net band #47-#57 is
a sovereign sock_*/udp_*/icmp ABI, `mmap#27` 2 MB-granular, `sock_recv` inverted-EOF, `execwait#37`
run-to-completion). So translation is a **per-number handler table**, not a remap: each agnos syscall
either (a) maps to a Linux syscall with arg translation, (b) is **emulated** in userspace over Linux
primitives, or (c) returns `ENOSYS`. agnos bins are **static, no libc** → no `LD_PRELOAD`; interception
must be supervisor-side (ptrace or seccomp-user-notify).

## Milestones (toward v1)

### M0 — Scaffold + the trap loop (v0.1.0) — ✅ shipped 2026-06-29
- `cyrius init --bin` scaffold (mirshi is a **Linux-target** Cyrius binary supervising **agnos-target** ELFs).
- **✅ The real M0 work — the trap loop:** a supervisor that `fork`+`exec`s an agnos static ELF and **traps every syscall** via `ptrace(PTRACE_SYSEMU)` (fastest bring-up — full register read/rewrite), logging the agnos syscall number + args. **Acceptance met:** `mirshi --selftest-trace <agnos-elf>` traps + logs a trivial agnos binary's complete stream (`getpid#2`, `write#1`, `exit#0`) — interception proven *before* any translation. Mechanism: `src/intercept.cyr` (SYSEMU loop) + `src/decode.cyr` (pure agnos#→name/arity/ptr-arg decode), proven by `scripts/it/m0_trap.sh`. Why SYSEMU not SYSCALL: [`../adr/0001-ptrace-sysemu-intercept.md`](../adr/0001-ptrace-sysemu-intercept.md).

### M1 — Core translation: process + console (hello-world runs) (v0.2.0) — ✅ shipped 2026-06-29
Handler table (`src/translate.cyr` pure + `src/dispatch.cyr` impure) for the minimal runnable set:
`exit#0` (→`exit_group`), `write#1` (stdout/stderr), `read#5` (stdin), `getpid#2`, `mmap#27`/`munmap#28`
(→ Linux `mmap`, 2 MB granularity), `sync#12`, `getrandom#45`, `time_unix#46`/`uptime_ms#40`/`sleep_ms#41`.
**Acceptance met:** agnos `hello` (write+exit) + stdin `cat` run correctly under `mirshi <elf>`, exit codes
propagate (incl. non-zero, e.g. 42), no QEMU; a heap fixture proves `mmap#27` runs in-child (no segfault).
Model — execute-in-child via `PTRACE_SYSCALL` register rewrite + emulate the buffer-less timers:
[`../adr/0002-execute-in-child-translation.md`](../adr/0002-execute-in-child-translation.md). Proven by
`scripts/it/m1_run.sh`.

### M2 — Filesystem syscalls (real agnos CLI tools run) (v0.3.0) — ✅ shipped 2026-06-29
`open#7`/`close#6`/`read`/`write`/`lseek#58`/`stat#33`/`getdents#29`/`mkdir#9`/`rmdir#10`/`unlink#30`/
`rename#31`/`link#32`/`dup#8` — map agnos VFS semantics onto a Linux container rootfs: translate agnos
`AO_*` open flags → Linux `O_*` (values differ — `AO_CREAT=0x100` vs Linux 64), the `a4=r10` 4th-arg ABI,
and the agnos `dirent` layout. ⚠ **symlink gap** (mirrors the ark-v2 finding): agnos `#32` is hardlink,
there is **no symlink syscall** — mirshi follows agnos's surface. **Acceptance met:** agnos `cat`/`cp`/`ls`/
`stat`-class fixtures read+write a (sandboxed) rootfs under mirshi — `cp` copies, `ls` lists with types,
`stat` reports mode/size — proven by `scripts/it/m2_fs.sh`. Mechanism — red-zone path staging
(`process_vm_*`) + exit-stop struct repack: [`../adr/0003-fs-redzone-path-staging.md`](../adr/0003-fs-redzone-path-staging.md).
Known gaps: transparent path pass-through (rootfs isolation = M3, escape hardening = 0.7.0); `getdents`
overflow-drop + ino u64→u32 truncation.

### M3 — The Docker image + multi-container fan-out (the v1 vehicle) (v0.4.0) — ✅ shipped 2026-06-29
A `Dockerfile` building an image that carries **mirshi (Linux-target)** + an **agnos userland set
(agnos-target ELFs)**, `ENTRYPOINT ["mirshi"]`; `docker run` an agnos binary with **no QEMU in the image**.
mirshi runs the child under a **bounding seccomp policy**. Document multi-container fan-out (boot N containers,
throw concurrent tests across heterogeneous Linux hosts — the near-term win). **Acceptance met:**
`docker run agnos-mirshi /bin/hello|catfile|ls` runs in a **`FROM scratch`** container (proven no qemu binary
present), correct output/exit; N-container fan-out demonstrated (`docker/fanout.sh`); proven by `docker/smoke.sh`
(a CI gate). Bounding seccomp = an allowlist of the translation's output syscalls (default-on, run mode);
mechanism + the seccomp-after-ptrace finding: [`../adr/0004-docker-vehicle-bounding-seccomp.md`](../adr/0004-docker-vehicle-bounding-seccomp.md).
The container mount namespace is also where M2's transparent path pass-through gets its rootfs boundary.

### M4 — seccomp-user-notify migration (scale) (v0.5.0) — ⚖ reframed (feasibility + benchmark shipped 2026-06-29; full hybrid deferred-by-data)
**Finding:** a *full* replacement of the ptrace loop with `SECCOMP_RET_USER_NOTIF` is **architecturally
impossible** — the kernel's `seccomp_notif_resp` (`{id,val,error,flags}`) cannot **renumber** a syscall, and
`mmap` must execute in the child's address space (only ptrace's renumber can do that). See
[`../adr/0005-seccomp-notify-feasibility.md`](../adr/0005-seccomp-notify-feasibility.md). The realistic M4 is a
**hybrid** (notify for the emulatable hot path; ptrace `SECCOMP_RET_TRACE` for the `mmap`/renumber residue).
**Shipped (v0.5.0):** the ptrace **benchmark baseline** (`docs/benchmarks.md`, `scripts/bench/`) + the
feasibility ADR + the documented hybrid design. **Deferred by data:** the benchmark shows realistic workloads
are ~5× native (only `getpid`-dense microbenchmarks are ~100×), so the dual-mechanism hybrid is **not yet
justified** — build it when a real workload proves syscall-bound. `FLAG_CONTINUE` is the 0.7.0 TOCTOU 0-day class.

> **Feature scope freezes here.** 0.1.0–0.5.0 above land the functional v1 surface (direction-1
> headless CLI). 0.6.0–0.9.0 below are the **pure-quality closing arc** (the ecosystem's canonical
> pre-1.0 close, cf. tarka/prajna): harden → security-sweep → optimize → freeze+docs → clean cut. The
> net band / multi-proc / graphics / swallow stay **post-v1** (see "Out of scope"); they do NOT block v1.

### 0.6.0 — Hardening
Robustness of the supervisor against a **misbehaving or hostile child**: malformed/garbage syscall args
+ bad pointers (never deref a child pointer without `process_vm_readv` bounds checks), syscall-storm / tight-loop
children, child crash / hang / zombie reaping, partial reads/writes, supervisor signal handling (don't die with
the child stuck), and **host-resource bounds** (a child can't exhaust host fds/memory/PIDs via the translation).
Unsupported syscalls degrade to a clean `ENOSYS` + a logged diagnostic, never a supervisor crash. Acceptance:
a fault-injection harness (bad-pointer / storm / crash / unknown-syscall children) leaves the supervisor stable
and the host untouched.

### 0.7.0 — Security CVE / 0-day sweep (audit + hardening) — ✅ shipped 2026-06-30
mirshi is a **sandbox-class trust boundary** — it runs foreign-ish agnos binaries and translates their syscalls
while holding host privilege (a classic **confused-deputy** surface). Adversarial sweep of the escape classes:
**(a)** child-memory-read **TOCTOU** (`process_vm_readv` / `/proc/pid/mem`; the seccomp-notify `FLAG_CONTINUE`
TOCTOU is the headline 0-day class for the *future* hybrid — moot under ptrace-only); **(b)** seccomp
bounding-policy completeness (default-deny, no gap); **(c)** path-translation escapes (traversal / symlink /
the agnos-VFS→host-FS mapping reaching unintended host paths); **(d)** arg-confusion.

**Phased** (user-selected, 2026-06-30 — *harden now, confine next*). The
[audit](../audit/2026-06-30-audit.md) found the whole **blocker tier is class (c) path-escape**; (a) is
safe-by-design, (b) is **proven default-deny**, (d) is mostly clean. **This milestone (0.7.0)** ships:
the documented sweep; the seccomp **default-deny proof** + completeness hardening (x32-bit mask, the install
made **fail-closed**, filter `alloc` guards); arg-confusion least-privilege (create modes 0600/0700,
`synth_mmap_regs` confirmed no PROT_EXEC/MAP_FIXED/file-backed). Acceptance (0.7.0): documented sweep ✅,
seccomp proven default-deny ✅, the minor/bounded findings fixed ✅.

### 0.7.1 — Supervisor rootfs confinement (the path-escape blocker fix) — the "confine next" half
Close the class-(c) blockers (`open#7`/`stat#33`/`mkdir#9`/`rmdir#10`/`unlink#30`/`rename#31`/`link#32`/
`getdents#29` reach **arbitrary host paths** — no chroot, no canonicalization, no rootfs prefix; confirmed by
PoC). Fix: a supervisor-resolved **rootfs** — a `--root` opened once (`rootfd`), every path op routed through
**kernel-enforced bounded resolution** (`openat2` `RESOLVE_IN_ROOT`/`RESOLVE_BENEATH` for `open`; parent-anchored
`*at` ops for the rest), rejecting escape before staging. Unprivileged, TOCTOU-safe, defense-in-depth over the
container mount NS. Until it lands, the **container NS is the confinement boundary** (the v1 vehicle is contained;
the **bare CLI is unconfined by design**). Acceptance: every class-(c) finding fixed; escape-attempt fault-harness
cases contained (bare-CLI **and** in-container); the audit's open checkboxes closed.

### 0.8.0 — Optimizations — ✅ shipped 2026-06-30
The per-syscall hot path is the whole cost model for the fan-out-at-scale goal. **Measured first**
([`../benchmarks.md`](../benchmarks.md)): the ~30 µs tax is dominated by the **two `PTRACE_SYSCALL` stops**
(supervisor↔child context-switch round-trips), **irreducible under ptrace** — the register copies are a
secondary term and the handler-table arithmetic is single-digit ns. So the byte-identical lever is **trimming
the register I/O within the stops we must take**: the **exit-stop single-register I/O**
([ADR 0010](../adr/0010-ptrace-exit-stop-single-register-io.md)) reads only `rax` (`PTRACE_PEEKUSER`) and writes
it back (`PTRACE_POKEUSER`) only when it changed — **~5–7 % off the syscall-dense tax, byte-identical**.
**Allocation-clean hot path** proven by a 0-alloc-per-syscall gate (`scripts/it/alloc_clean.sh`, teeth-verified).
**Two premises in the original plan were found unachievable-by-design and reconciled here**: (1) a *fast-path for
pure pass-through numbers (no supervisor round-trip)* does **not exist** in direction 1 — no agnos call is fully
transparent (only `write#1` shares Linux's number, and even it needs the `-errno`→`-1` return remap, so seccomp
`RET_ALLOW` cannot pass it through); (2) the *seccomp-notify documented default* is superseded by
[ADR 0005](../adr/0005-seccomp-notify-feasibility.md) — the hybrid stays **deferred-by-data** (realistic workloads
~3–5× native, not syscall-bound, and notify wins *least* on the buffer calls that dominate them), so **ptrace
remains the documented default**. Acceptance (met): `docs/benchmarks.md` shows the per-syscall overhead + the
realistic-workload (`cat`) wall-clock ✅; the 0-alloc gate is green ✅; numerics/behavior **byte-identical to 0.7.1** ✅.

### 0.9.0 — Freeze + docs cleanup — ✅ shipped 2026-06-30
No behavior change — froze the v1 contracts + consolidated the docs. **Translation-table contract frozen**: the
per-number AGNOS→Linux **syscall-coverage matrix** ([`../reference/syscall-coverage.md`](../reference/syscall-coverage.md))
— disposition (EXECUTE/EMULATE/EXIT/ENOSYS), Linux peer, the `--root` re-anchored peers, arg/return notes, gaps —
**exhaustively test-pinned** for agnos# 0–61 (`tests/mirshi.tcyr` `xlat-coverage`) and adversarially audited
row-by-row vs the code. **CLI frozen**: [`../reference/cli.md`](../reference/cli.md) (flags, modes, exit-code map),
pinned by `scripts/it/cli.sh`. The Docker/fan-out guide is current; the **discipline doc**
([ADR 0011](../adr/0011-mirshi-qemu-iron-boundary-discipline.md): mirshi *complements, never replaces* QEMU+iron) is
in place; the load-bearing decisions all have ADRs (intercept #0001, the `FLAG_CONTINUE` rule #0005,
boundary-vs-QEMU #0011); CHANGELOG complete from 0.1.0; ADR index complete (0001–0011). Acceptance: all met ✅.

### v1.0.0 — clean cut: AGNOS userland in Docker, no QEMU (direction 1, headless CLI) — ✅ shipped 2026-06-30
The clean cut of the hardened/audited/optimized/frozen foundation: a representative agnos **CLI userland** runs
in a plain `FROM scratch` Docker container under mirshi, fan-out-ready, seccomp-bounded. Shipped with mirshi's
own demo userland — `hello` (console), `echo` (stdin), `catfile` (fs read), `ls` (getdents), `cp` (fs
write/create) — proven end-to-end by `docker/smoke.sh` (5 tools + no-QEMU + 4-container fan-out); broader agnos
ecosystem suites (kriya coreutils, iam/mihi sysinfo, bannermanor) run on the same vehicle once built
agnos-target. **Acceptance = the v1 definition: AGNOS + mirshi runs in a docker container, no QEMU** — met,
with every v1.0 criterion across the 0.6–0.9 arc:
- [x] Translation-table contract **frozen** + per-syscall documented + tested (0.9.0)
- [x] ≥1 real agnos tool green end-to-end in-container ✅ (5-tool userland + fan-out); registry **publish** = documented post-v1 ops step ([fan-out guide](../guides/docker-fanout.md)), not gated by the v1 definition
- [x] Security audit pass — sandbox-escape classes swept, seccomp default-deny proven (0.7.0)
- [x] Benchmarks captured (per-syscall + workload; ptrace vs seccomp-notify) (0.8.0)
- [x] Hardening: fault-injection harness green, host-resource bounds enforced (0.6.0)
- [x] CHANGELOG complete from 0.1.0; ADRs for the load-bearing decisions (0.9.0)

## Post-v1 — the net band arc (v1.1.0 → v1.4.0) — v1.3.0 shipped 2026-06-30

The **first post-v1 expansion**: the sovereign net band (#47–57, #61) over Linux sockets, so agnos net tools
(`http`/`ws_server`/dns, `agora`/`descent`) run under mirshi at fan-out scale. Architecture + security are fixed
in [ADR 0012](../adr/0012-net-band-supervisor-emulated-conn-table.md): **supervisor-EMULATE** — the supervisor
owns the sockets via an 8-slot `conn_id(0..7) → host fd` table, buffers stage through `process_vm` (the M2
pattern), the child never holds a socket fd, and the seccomp allowlist is **unchanged** (socket syscalls run
supervisor-side). Chosen over execute-in-child to avoid a rip-rewind loop change ([ADR 0002](../adr/0002-execute-in-child-translation.md)'s
rejected pattern) and to keep the fd + the egress choke point supervisor-side. **Egress is a shipping gate**:
`--net` opt-in + `--net-allow <CIDR>[:ports]` **default-deny** (stricter than `--root` — metadata/RFC1918/loopback
blocked, fail-closed to agnos `-1`). Client-first; the **ingress** side (v1.2.0 server) binds **loopback-only by
default** (`--net-listen-any` to expose all interfaces), so a sandboxed child's server isn't network-reachable unless asked.

| Ver | Slice | Acceptance gate | Key risk |
|---|---|---|---|
| **v1.1.0** ✅ | **TCP client** (`#47`/`48`/`49`/`50`) + `--net`/`--net-allow` egress | agnos HTTP-GET round-trip — connect/send/recv-loop-to-EOF/close (`scripts/it/net_io.sh` + `net_client.sh`) — **shipped 2026-06-30** | done ✓ |
| **v1.2.0** ✅ | **TCP server** (`sock_listen#56`/`accept#57`) + `--net-listen-any` (loopback-default ingress) | agnos server accepts a real client (`scripts/it/net_server.sh`, both bind modes) — **shipped 2026-06-30** | done ✓ |
| **v1.3.0** ✅ | **UDP** (`#51`–`54`) + `net_config#61` (real netns gateway/DNS/host-IP) | agnos UDP round-trip + net_config matches the netns config (`scripts/it/net_udp.sh` + `net_config.sh`) — **shipped 2026-06-30** | done ✓ |
| **v1.4.0** | **ICMP** (`icmp_echo#55`) | agnos ping-class tool RTTs a host | unprivileged `SOCK_DGRAM` ICMP (`ping_group_range`) — env-sensitive |

Load-bearing correctness (both pure + unit-pinned): the **inverted `recv#49` EOF** mapper (`n>0→n`, Linux
`0`→`-1` EOF, `EAGAIN`→`0` WOULD_BLOCK — a naïve reuse of the fs mapper spins agnos poll-loops forever) and the
`dst_ip`→`sockaddr_in` **byte order** (both verified in the live round-trip). `net_config#61` (deferred to
**v1.3.0**, where DNS resolution consumes it) reads the **real container-netns** interface (minor infoleak, accepted). Discipline ([ADR 0011](../adr/0011-mirshi-qemu-iron-boundary-discipline.md)): mirshi
validates net-**app** compat on the **host** kernel; the agnos **sovereign** net stack stays QEMU's job.

## Out of scope for v1 (post-v1 / v2+)

- **Sovereign net band #47-#57/#61 over Linux sockets** — **now scoped** as the v1.1.0→v1.4.0 arc above
  ([ADR 0012](../adr/0012-net-band-supervisor-emulated-conn-table.md)); the first post-v1 expansion (unblocks
  the net tools / `agora` / `descent` at fan-out scale).
- **Multi-process agnos** (`spawn#3`/`execwait#37`/`spawn_path#43`/`waitpid#4`) — run **agnsh with child
  exec** (the crown-jewel target). Needs per-child supervisor spawning + run-to-completion semantics.
  Likely v1.x once single-process is solid.
- **Graphics** (`fbinfo#38`/`blit#39`/`winsize#60`) — a headless container has no framebuffer; stub or a
  virtual-FB later.
- **Signals / epoll / timerfd / pipe** (`#16`-`#25`) — as consumers need them.
- **Direction 2 — Linux→AGNOS "swallow"** (run Linux binaries on the agnos kernel) — **v2+**, the permanent
  compat layer ([[project_agnos_empire_defense_layers]]); an entirely separate validation surface, same
  translation core run from the other side.
