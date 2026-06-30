# mirshi — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures
> (durable); this file is **state** (volatile).

## Version

**0.8.0** — 2026-06-30. Optimizations (measure-first hot-path). The ~30 µs per-syscall tax is
dominated by the two `PTRACE_SYSCALL` stops (irreducible under ptrace); the byte-identical lever
is trimming register I/O within them. Ships the **exit-stop single-register I/O**
([ADR 0010](../adr/0010-ptrace-exit-stop-single-register-io.md)) — `PTRACE_PEEKUSER` reads only
`rax`, `PTRACE_POKEUSER` writes it back only when it changed (~5–7 % off the syscall-dense tax,
byte-identical) — plus a 0-alloc-per-syscall gate (`scripts/it/alloc_clean.sh`) and the honest
reconciliation that **ptrace stays the documented default** (no transparent pass-through fast-path
exists in direction 1; the seccomp-notify hybrid is deferred-by-data). 0.7.1 = rootfs confinement
(`--root`, audit class-(c), [ADR 0009](../adr/0009-rootfs-confinement-openat2-in-child.md)):
`--root <dir>` confines the child's filesystem via `openat2 RESOLVE_IN_ROOT` (open) +
the `*at` family with lexical `sanitize_rootrel` (mutation/metadata) + `RESOLVE_NO_MAGICLINKS`;
the container vehicle stays namespace-confined. 0.7.0 = security sweep (audit + hardening:
seccomp proven default-deny, x32 mask, fail-closed install); 0.6.0 = hardening (rlimits /
group-stop / child-hang, ADRs 0006-0008); 0.5.0 = M4 seccomp-notify feasibility + benchmark
([ADR 0005](../adr/0005-seccomp-notify-feasibility.md)); 0.4.0 = M3 Docker vehicle
(functional v1 surface complete); 0.3.0 = M2 fs; 0.2.0 = M1 translation; 0.1.0 = M0 trap loop.

## Toolchain

- **Cyrius pin**: `6.3.12` (in `cyrius.cyml [package].cyrius`)

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
  `rename#31`, `link#32`, `stat#33`, `getdents#29`. Path policy = transparent
  pass-through (rootfs isolation deferred to M3 / hardening to 0.7.0).

## Tests

- `tests/mirshi.tcyr` — primary suite (smoke + the pure M0 decode/format layer +
  the M1 translation contract + the M2 fs contract; **105 assertions**, hermetic)
- `scripts/it/m0_trap.sh` — M0 integration test: the real fork+ptrace trap path over
  `tests/fixtures/hi.cyr` vs the golden `tests/fixtures/hi.expected.log`.
- `scripts/it/m1_run.sh` — M1 integration test: agnos `hello`/`cat`/`exit42`/`heapuser`
  run under real translation (`heapuser` is the mmap-in-child regression gate).
- `scripts/it/m2_fs.sh` — M2 fs integration test: agnos open/read/write/close/cp/
  mkdir/rename/link/unlink/stat/getdents against a sandboxed temp rootfs (HOST EFFECTS).
- `docker/smoke.sh` — M3 docker gate: build the `agnos-mirshi` image, `docker run`
  agnos tools (correct output, no qemu in image), and a fan-out. The four `scripts/it/*`
  + `docker/smoke.sh` are CI steps after `cyrius test`; the ptrace ITs need a same-uid
  child (no extra privilege on ubuntu-latest;
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

Then 0.9.0 freeze+docs → v1.0.0.
