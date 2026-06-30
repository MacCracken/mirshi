# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

0.9.0 freeze + docs cleanup (in progress) — no behavior change; freeze the v1 contracts +
consolidate the docs before the v1.0.0 cut.

### Docs
- **Frozen translation-table contract** — [`docs/reference/syscall-coverage.md`](docs/reference/syscall-coverage.md):
  the canonical, exhaustive per-number (agnos 0–61) AGNOS→Linux matrix — disposition
  (EXECUTE / EMULATE / EXIT / ENOSYS), the Linux peer, the `--root` re-anchored peers, the
  arg/return notes, the runnable v1 surface, and the carried-forward gaps. Mirrors the code
  and is **pinned by tests** (`tests/mirshi.tcyr` `xlat-coverage`: every number's disposition
  asserted, +38 assertions → 161 total). Adversarially audited row-by-row against the code.
- **Frozen CLI contract** — [`docs/reference/cli.md`](docs/reference/cli.md): the synopsis,
  flags (`--selftest-trace` / `--no-seccomp` / `--root <dir>`), modes, streams, and the
  exit-code map (child code / `128+sig` / `2` usage / `125` wait / `126` bound / `127` execve).
  Pinned by `scripts/it/cli.sh` (usage on misuse + `EXECVE_FAILED`), wired into CI.
- New `docs/reference/` section (frozen contracts); indexed in `CLAUDE.md`.

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
