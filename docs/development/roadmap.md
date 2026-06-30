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
> (real kernel) + iron (hardware truth). Each surface owns a distinct bug class.

## The core technical problem

agnos redefines the `Sys` enum to its own numbers (`exit`=0 vs Linux 60, the net band #45-#57 is
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

### 0.7.0 — Security CVE / 0-day sweep
mirshi is a **sandbox-class trust boundary** — it runs foreign-ish agnos binaries and translates their syscalls
while holding host privilege (a classic **confused-deputy** surface). Adversarial review (the kavach / net-syscall
sweep model) of the escape classes: **(a)** child-memory-read **TOCTOU** (`process_vm_readv` / `/proc/pid/mem` —
args re-read after a check; **the documented seccomp-notify `FLAG_CONTINUE` TOCTOU is the headline 0-day class** —
never `FLAG_CONTINUE` a security-relevant syscall, perform it in the supervisor); **(b)** can the child reach the
host syscall table *around* the translation (seccomp bounding-policy completeness — default-deny, no gap)? **(c)**
path-translation escapes (traversal / symlink / the agnos-VFS→host-FS mapping reaching unintended host paths);
**(d)** arg-confusion letting a translated call touch a host resource the agnos ABI never granted. Acceptance:
documented sweep (`docs/audit/YYYY-MM-DD-audit.md`), every reachable finding fixed, the seccomp policy proven
default-deny, escape attempts in the fault harness contained.

### 0.8.0 — Optimizations
The per-syscall hot path is the whole cost model for the fan-out-at-scale goal: minimize trap→read-args→translate→
return overhead — a **fast-path for pure pass-through numbers** (let the kernel run them, no supervisor round-trip),
fewer/batched `process_vm_readv` calls, a cheap dispatch over the handler table, and the **ptrace-vs-seccomp-notify**
bench made rigorous. Allocation-clean hot path (no per-syscall churn). Acceptance: `docs/benchmarks.md` shows the
per-syscall overhead + the realistic-workload (a real agnos tool) wall-clock, with the seccomp-notify path the
documented default; numerics/behavior byte-identical to 0.7.0.

### 0.9.0 — Freeze + docs cleanup
Freeze the **translation-table contract** (the per-agnos-syscall mapped / emulated / `ENOSYS` matrix) + the CLI;
document the full syscall-coverage matrix, the Docker usage + multi-container fan-out guide, the discipline doc
(mirshi vs QEMU vs iron), and ADRs for the load-bearing decisions (intercept mechanism, the `FLAG_CONTINUE`
security rule, the boundary-vs-QEMU). CHANGELOG complete from 0.1.0. No behavior change — freeze + docs only.

### v1.0.0 — clean cut: AGNOS userland in Docker, no QEMU (direction 1, headless CLI)
The clean cut of the hardened/audited/optimized/frozen foundation: a representative agnos **CLI userland**
(kriya coreutils + iam/mihi sysinfo + bannermanor + non-net tools) runs in a plain Docker container under mirshi,
fan-out-ready, seccomp-bounded. **Acceptance = the v1 definition: AGNOS + mirshi runs in a docker container, no
QEMU**, with every v1.0 criterion met across the 0.6–0.9 arc:
- [ ] Translation-table contract **frozen** + per-syscall documented + tested (0.9.0)
- [ ] ≥1 real agnos tool green end-to-end in-container; the Docker image published
- [ ] Security audit pass — sandbox-escape classes swept, seccomp default-deny proven (0.7.0)
- [ ] Benchmarks captured (per-syscall + workload; ptrace vs seccomp-notify) (0.8.0)
- [ ] Hardening: fault-injection harness green, host-resource bounds enforced (0.6.0)
- [ ] CHANGELOG complete from 0.1.0; ADRs for the load-bearing decisions

## Out of scope for v1 (post-v1 / v2+)

- **Sovereign net band #45-#57 over Linux sockets** — the `conn_id` ABI, inverted `recv` EOF, UDP/ICMP.
  **First post-v1 expansion** (high-value: unblocks running the net tools / `agora` / `descent` in mirshi
  containers — the "meatier tests at scale" goal). Its own arc (socket-semantics emulation is real work).
- **Multi-process agnos** (`spawn#3`/`execwait#37`/`spawn_path#43`/`waitpid#4`) — run **agnsh with child
  exec** (the crown-jewel target). Needs per-child supervisor spawning + run-to-completion semantics.
  Likely v1.x once single-process is solid.
- **Graphics** (`fbinfo#38`/`blit#39`/`winsize#60`) — a headless container has no framebuffer; stub or a
  virtual-FB later.
- **Signals / epoll / timerfd / pipe** (`#16`-`#25`) — as consumers need them.
- **Direction 2 — Linux→AGNOS "swallow"** (run Linux binaries on the agnos kernel) — **v2+**, the permanent
  compat layer ([[project_agnos_empire_defense_layers]]); an entirely separate validation surface, same
  translation core run from the other side.
