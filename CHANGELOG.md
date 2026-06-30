# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
