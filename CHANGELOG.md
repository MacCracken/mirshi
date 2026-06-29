# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
