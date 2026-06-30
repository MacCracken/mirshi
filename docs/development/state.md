# mirshi — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures
> (durable); this file is **state** (volatile).

## Version

**0.2.0** — 2026-06-29. M1 = core translation (agnos binaries run as native Linux processes, no QEMU).
0.1.0 = M0 scaffold + trap loop.

## Toolchain

- **Cyrius pin**: `6.3.5` (in `cyrius.cyml [package].cyrius`)

## Source

**M0 trap loop** (0.1.0) + **M1 core translation** (0.2.0). x86_64 Linux only.
`mirshi <agnos-elf>` runs (translates+executes); `--selftest-trace` is the M0
trap-log mode.

- `src/main.cyr` — supervisor entry: argv dispatch. `mirshi [--selftest-trace] <agnos-elf>`.
- `src/intercept.cyr` — the impure core: `fork`/`PTRACE_TRACEME`/`execve`, `_attach`,
  and the two loops — `_trace_log` (M0 `PTRACE_SYSEMU`, trap+log) and `_trace_run`
  (M1 `PTRACE_SYSCALL` enter/exit, translate+execute). Defines the ptrace ABI the
  Linux stdlib peer lacks (`SYS_PTRACE=101`, `PTRACE_*`, `WIFSTOPPED`/`WSTOPSIG`).
- `src/decode.cyr` — pure decode (no syscalls): x86_64 `user_regs_struct` offsets,
  the agnos number→name/arity/pointer-arg tables, and `format_event`.
- `src/translate.cyr` — PURE agnos→Linux translation (unit-tested): number remap,
  number-aware return mapping, 2 MB mmap round-up, 6-arg mmap synthesis.
- `src/dispatch.cyr` — the impure dispatcher: execute-in-child / supervisor-emulate /
  ENOSYS register rewrites for the M1 minimal set.

Translation model: execute-in-child via `PTRACE_SYSCALL` register rewrite, emulate
only the buffer-less timers — see [`../adr/0002-execute-in-child-translation.md`](../adr/0002-execute-in-child-translation.md).
M1 set: `exit#0` (→`exit_group`), `write#1`, `read#5`, `getpid#2`, `mmap#27`/`munmap#28`,
`sync#12`, `getrandom#45`, `time_unix#46`, `uptime_ms#40`, `sleep_ms#41`.

## Tests

- `tests/mirshi.tcyr` — primary suite (smoke + the pure M0 decode/format layer +
  the M1 translation contract; **64 assertions**, hermetic, passes on `cyrius test`)
- `scripts/it/m0_trap.sh` — M0 integration test: the real fork+ptrace trap path over
  `tests/fixtures/hi.cyr` vs the golden `tests/fixtures/hi.expected.log`.
- `scripts/it/m1_run.sh` — M1 integration test: agnos `hello`/`cat`/`exit42`/`heapuser`
  run under real translation (output + exit-code asserted; `heapuser` is the mmap-in-child
  regression gate). Both ITs are CI steps after `cyrius test`; they need ptrace of a
  same-uid child (no extra privilege on ubuntu-latest;
  `--cap-add=SYS_PTRACE --security-opt seccomp=unconfined` in a container).
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

See [`roadmap.md`](roadmap.md) — M0 + M1 done. Next is **M2** (v0.3.0): filesystem
syscalls (`open#7`/`close#6`/`lseek#58`/`stat#33`/`getdents#29`/`mkdir#9`/`rmdir#10`/
`unlink#30`/`rename#31`/`link#32`/`dup#8`) — translate agnos `AO_*` open flags → Linux
`O_*` (values differ), the agnos `dirent` layout, and the 48 B vs 144 B `stat` repack,
onto a container rootfs. ⚠ agnos `#32` is hardlink — no symlink syscall (the ark-v2 gap).
