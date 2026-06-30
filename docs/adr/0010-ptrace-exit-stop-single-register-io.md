# 0010 — ptrace exit-stop single-register I/O (the ptrace optimization ceiling)

**Status**: Accepted
**Date**: 2026-06-30

## Context

0.8.0 is the optimization milestone. We measured first ([`../benchmarks.md`](../benchmarks.md)):
the per-syscall tax is ~30 µs and is **dominated by the two `PTRACE_SYSCALL` stops**
(supervisor↔child context-switch round-trips), with the register copies a secondary term
and the translation arithmetic at single-digit nanoseconds. That cost model bounds what is
achievable and forces an honest reconciliation with two aspirational roadmap lines:

- *"a fast-path for pure pass-through numbers (let the kernel run them, no supervisor
  round-trip)."* The only primitive that skips the supervisor entirely is a seccomp
  `RET_ALLOW`, which runs the trapped number **as a Linux syscall without renumbering**.
  Auditing `agnos_to_linux_nr` + `linux_ret_to_agnos`: **no agnos syscall is fully
  transparent.** Every call but `write#1` has a number-different Linux peer (so it *must* be
  renumbered at the enter stop — `RET_ALLOW` can't do that), and even `write#1` (the lone
  number-identical map) can't be allowed through, because agnos wants a **bare `-1`** on
  error while Linux `write` returns `-errno`. So a true zero-round-trip pass-through path
  **does not exist in direction 1** — every agnos syscall needs supervisor mediation.
- *"the seccomp-notify path the documented default."* [ADR 0005](0005-seccomp-notify-feasibility.md)
  already found a full notify replacement architecturally impossible and the **hybrid
  deferred-by-data** (realistic workloads are ~3–5× native, only microbenchmarks are
  syscall-bound). So **ptrace remains the documented default**; that roadmap phrasing is
  superseded by ADR 0005 + the benchmark.

What *is* available, byte-identically, is trimming the **register I/O within the stops we
must take**. The enter stop genuinely needs the full register set (it reads `nr` + up to 4
args and rewrites `orig_rax` + 1–6 arg registers — `_cf_two`/`synth_mmap_regs` touch 5–6).
But the **exit stop needs exactly one register: `rax`** (the raw kernel return). The 0.7.1
loop nonetheless paid a full 216-byte `GETREGS` + an unconditional 216-byte `SETREGS` there.

## Decision

**At the syscall-EXIT stop, do single-register I/O: read only `rax` with `PTRACE_PEEKUSER`
(8 bytes), map it to the agnos convention, and write it back with `PTRACE_POKEUSER` (8
bytes) only when it actually changed. Leave the ENTER stop on `GETREGS`/`SETREGS`. Build no
pass-through fast-path and no seccomp-notify hybrid — neither is available/justified.**

- **Exit stop** (`src/intercept.cyr` `_trace_run`): `PTRACE_PEEKUSER(REG_RAX)` → `raw`;
  `agret = STRAT_EXECUTE ? fs_exit_return(…) : _xlat_emu_ret`; `if (agret != raw)
  PTRACE_POKEUSER(REG_RAX, agret)`. The syscall-dense **success** path then costs one
  8-byte peek and **no write-back at all** (getpid/read/write/lseek/mmap/getrandom returns
  pass through unchanged; `stat` success stays 0 with its output already repacked into child
  memory by `fs_exit_return`, a `process_vm_writev` independent of the register write-back).
  Only error returns (`-errno`→`-1`, mmap/time→0), the `getdents` repack count, and the
  EMULATE/ENOSYS injection (raw `rax` = `-ENOSYS`) differ → `POKEUSER` fires.
- **Why byte-identical**: at a syscall-exit the supervisor only ever wrote `rax`. `rcx`/`r11`
  are kernel-restored on return and every other GP register is child-preserved, so touching
  exactly `rax`, only when it differs, leaves the child resuming with precisely the `rax` the
  unconditional `SETREGS` path would have set. (`REG_RAX = 80` is the offset into `struct
  user` too, since `user_regs_struct` is its leading member, so `PEEK/POKEUSER` reuse the
  same constant — no new magic number. The raw `PEEKUSER` ABI writes the word to the `data`
  pointer and returns `0/-errno`; `POKEUSER` takes the value in `data`; `rax` is a plain GP
  register so `putreg` writes it unmasked.)
- **Scope out**: the ENTER stop stays full-register — it is write-heavy and multi-register,
  where one `SETREGS` beats 5–6 single-word `POKEUSER` calls. The asymmetry (exit touches
  exactly one register, enter touches many) is what makes single-register I/O a win at the
  exit stop specifically. `_trace_log` (selftest/SYSEMU) has no exit stop and is unchanged.

## Consequences

- **Positive** — byte-identical (verified: 123 unit + `m1_run`/`m2_fs`/`confine` ITs cover
  success/error/repack/confined classes; A/B vs HEAD). Measured **~5–7 % lower per-syscall
  tax** on syscall-dense workloads (getpid ~5.4–6.6 %, getrandom ~6.9 %), negligible on
  buffer-heavy ones (`cat` is already amortized over few large calls). Arguably **safer**
  than the old path: `POKEUSER` touches strictly fewer bytes than a 216-byte `SETREGS`.
- **Negative / owned** — this is **register-I/O trimming, not a structural win**: it does
  not remove a stop, so the headline ×-native multiple barely moves. ~5–7 % is near the
  **ptrace optimization ceiling** for byte-identical changes; the only lever that removes a
  stop is the seccomp-notify hybrid (ADR 0005), deferred-by-data. `PEEK/POKEUSER` at
  `REG_RAX=80` is x86_64-specific (as is the whole supervisor).
- **Neutral** — a future consumer with a *proven* syscall-bound real workload (not a
  microbenchmark) is the trigger to revisit the seccomp-notify hybrid; until then ptrace +
  single-register exit I/O is the default. The 0-alloc-per-syscall property (the hot path
  allocates its buffers once per child, before the loop) is locked by a separate gate.

## Alternatives considered

- **Elide only the exit `SETREGS` (keep `GETREGS`)** — the first form built. Byte-identical
  and simpler, but **dominated**: it leaves the unconditional 216-byte `GETREGS` on every
  call, so it saved ~3.6 % on getpid vs ~5.4 % for `PEEK/POKEUSER`, which subsumes it (same
  `agret != raw` guard) and also kills the `GETREGS`. Rejected in favor of the dominant form.
- **`seccomp RET_ALLOW` pass-through for "transparent" numbers** — the roadmap's
  zero-round-trip idea. **Impossible**: no agnos call is transparent (see Context) — every
  one needs renumbering and/or the `-errno`→`-1` return remap, neither of which `RET_ALLOW`
  can do without breaking byte-identity.
- **Single-register `POKEUSER` at the ENTER stop too** — loses: the enter rewrite is
  multi-register (`orig_rax` + 1–6 args), so a per-register poke would issue *more* syscalls
  than one `SETREGS`. Kept the enter stop on `GETREGS`/`SETREGS`.
- **Build the seccomp-notify hybrid now** — the only change that removes a stop, but
  deferred-by-data per ADR 0005 (realistic workloads aren't syscall-bound, and notify wins
  *least* on the buffer-bearing calls that dominate them). Not built.
