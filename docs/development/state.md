# mirshi — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures
> (durable); this file is **state** (volatile).

## Version

**0.1.0** — 2026-06-29. M0 = scaffold + the trap loop (interception proven before translation).

## Toolchain

- **Cyrius pin**: `6.3.5` (in `cyrius.cyml [package].cyrius`)

## Source

**M0 trap loop** — shipped in 0.1.0; completes the M0 milestone. x86_64 Linux only.

- `src/main.cyr` — supervisor entry: argv dispatch. `mirshi [--selftest-trace] <agnos-elf>`.
- `src/intercept.cyr` — the impure trap mechanism: `fork`/`PTRACE_TRACEME`/`execve`
  + the `PTRACE_SYSEMU` wait loop, syscall-stop vs exit/signal classification,
  single-resume-site signal forwarding, agnos-`exit#0` teardown. Defines the ptrace
  ABI the Linux stdlib peer lacks (`SYS_PTRACE=101`, `PTRACE_*`, `WIFSTOPPED`/`WSTOPSIG`).
- `src/decode.cyr` — pure decode/format (no syscalls): x86_64 `user_regs_struct`
  offsets, the agnos number→name/arity/pointer-arg tables, and `format_event`.

Logs the full agnos syscall stream; translates nothing (interception proven
before translation — see [`../adr/0001-ptrace-sysemu-intercept.md`](../adr/0001-ptrace-sysemu-intercept.md)).
Next module the architecture map reserves: `src/translate.cyr` (M1).

## Tests

- `tests/mirshi.tcyr` — primary suite (smoke + the pure M0 decode/format layer;
  25 assertions, hermetic, passes on `cyrius test`)
- `scripts/it/m0_trap.sh` — M0 integration test: the real fork+ptrace path over
  `tests/fixtures/hi.cyr` vs the golden `tests/fixtures/hi.expected.log`. Wired as
  a CI step after `cyrius test`; needs ptrace of a same-uid child (no extra privilege
  on ubuntu-latest; `--cap-add=SYS_PTRACE --security-opt seccomp=unconfined` in a container).
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
- v1 scope = direction 1 (AGNOS→Linux), headless CLI, no QEMU. Net band / multi-proc /
  graphics / the Linux→AGNOS swallow direction are post-v1 (see roadmap "Out of scope").
- Complements QEMU+KVM (real kernel) + iron (hardware truth); does not replace them.

## Next

See [`roadmap.md`](roadmap.md) — M0 trap loop is done. Next is **M1** (v0.2.0):
`src/translate.cyr` — the per-agnos-number handler table for the minimal runnable
set (`exit#0`, `write#1`, `read#5`, `getpid#2`, `mmap#27`/`munmap#28`, `sync#12`,
`getrandom#45`, `time_unix#46`, `uptime_ms#40`, `sleep_ms#41`), injecting translated
returns via `PTRACE_SETREGS` so an agnos `hello` + stdin `cat` run correctly.
