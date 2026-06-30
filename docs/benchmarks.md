# mirshi — benchmarks

Per-syscall translation overhead and realistic-workload wall-clock for the
interception mechanism. Run with `scripts/bench/bench_syscall.sh` (mechanism-
agnostic: the `mech` column is the interception path — `ptrace` today, a
`seccomp-notify` row slots in once M4 lands). Overhead is reported as a
**multiple over native** (the same workload with no supervisor) because absolute
µs drifts with hardware.

## TL;DR

| workload | mech | ns/call (tax) | × native |
|---|---|---:|---:|
| `getpid` storm (200k) | ptrace | ~30,450 | ~100× |
| `getrandom` storm (200k, 16 B → child buf) | ptrace | ~30,455 | ~63× |
| `cat` a 4 MB file (64 KB reads) | ptrace | — | ~5× |
| any | seccomp-notify | *M4 — pending* | *pending* |

**Read this honestly:** the per-syscall tax is ~30 µs and dominates a *syscall-
dense* microbenchmark (getpid is ~100× native), but a *realistic* workload that
moves bytes in large buffers (`cat` with 64 KB reads) is only ~5× native, because
the trap cost amortizes over few, large syscalls. The headline win from a lower-
overhead mechanism is largest on the syscall-dense end and smallest on the
buffer-heavy end.

*(host: Linux 7.0.13 x86_64, 16 cores; N=200,000; min-of-5, warm-up discarded.
Re-run on your hardware — these are ratios, not promises.)*

## The ptrace cost model (current)

Run mode (`_trace_run`, [ADR 0002](adr/0002-execute-in-child-translation.md))
uses `PTRACE_SYSCALL`, which stops the child **twice per syscall** (enter + exit).
Each translated call pays, roughly:

- **2 ptrace stops** = 2 supervisor↔child context-switch round-trips (`waitpid`
  wakes the supervisor; `PTRACE_SYSCALL` resumes the child) — the dominant cost,
  and **irreducible under ptrace** (only seccomp-notify removes a stop).
- **Register I/O.** The **enter** rewrite needs the full register set —
  `PTRACE_GETREGS` reads `nr` + args, `PTRACE_SETREGS` writes the renumbered
  `orig_rax` + synthesized args (up to 5–6 registers) — each a 216-byte
  cross-process copy. The **exit** stop, since **0.8.0**
  ([ADR 0010](adr/0010-ptrace-exit-stop-single-register-io.md)), does
  **single-register I/O**: `PTRACE_PEEKUSER` reads only `rax` (8 bytes) and
  `PTRACE_POKEUSER` writes it back only when the agnos return differs (success
  pass-through ⇒ no write-back at all), replacing the old exit `GETREGS` +
  unconditional `SETREGS` (two 216-byte copies).

The translation *arithmetic* itself (`src/translate.cyr`: number remap, return
mapping, mmap synth) is single-digit nanoseconds — the ~30 µs is **kernel
crossings, not the handler table**. So the lever is the *number of crossings per
syscall*. 0.8.0 trims the exit-stop register copies (~5–7 % off the syscall-dense
tax, byte-identical) — near the **ptrace ceiling**; the *stop count* is what only
seccomp-notify (M4, deferred-by-data) can cut.

## The seccomp-notify projection (M4 — pending)

`seccomp-user-notify` collapses the per-call cost to **one** supervisor round-trip
(`NOTIF_RECV` → process → `NOTIF_SEND`), deleting one of the two stops and most of
the register I/O. Plausible target: **~2–4× lower per-syscall** (the ~30 µs getpid
tax → ~8–15 µs) — *to be measured, not asserted*. The gap **narrows on buffer-
bearing calls**: seccomp-notify must `process_vm_readv`/`writev` the child buffer
(a cross-address-space copy) that ptrace's execute-in-child got for free, so
`read`/`write`/`getrandom` win less than `getpid`.

⚠ seccomp-notify **cannot replace ptrace outright** — it cannot renumber a syscall
or run `mmap` in the child's address space. See
[ADR 0005](adr/0005-seccomp-notify-feasibility.md): M4 is a hybrid (notify for the
emulatable hot path, ptrace for the renumber/`mmap` residue).

## Methodology

`scripts/bench/bench_syscall.sh`:

- **Per-syscall storms** — N iterations of one agnos call, built both agnos-target
  (run under mirshi) and Linux-target (the native floor). `(mirshi − native) / N`
  isolates the trap+translate tax; the identical loop cancels.
- **Realistic workload** — an agnos `cat` of a multi-MB file vs the system `cat`.
- **min-of-REPS**, warm-up discarded, with provenance (kernel, CPUs, in-Docker?).
- Knobs: `N`, `REPS`, `MECH`, `MIRSHI_FLAGS`, `MB`.

CI runs the harness **non-gating** (absolute µs drifts with the runner); the
**0-alloc-per-syscall** assertion and fixture correctness are the gating parts
(see roadmap 0.8.0).

## Results log

- **2026-06-29 — ptrace baseline (v0.4.0).** getpid ~30.5 µs/call (~100× native),
  getrandom ~30.5 µs/call (~63×), cat-4MB ~5× native. The per-syscall floor that
  M4 (seccomp-notify hybrid) and 0.8.0 (optimization) work against.
- **2026-06-30 — 0.8.0 exit-stop single-register I/O ([ADR 0010](adr/0010-ptrace-exit-stop-single-register-io.md)).**
  A/B vs the 0.7.1 HEAD binary, same fixtures (N=150k, min-of-5/9): getpid storm
  **−5.4 to −6.6 %** (~30.7 → ~28.9 µs/call), getrandom storm **−6.9 %**
  (~31.3 → ~29.1 µs/call), `cat` unchanged within noise (already buffer-amortized).
  Byte-identical (123 unit + `m1_run`/`m2_fs`/`confine` ITs green). This is
  register-I/O trimming **within** the two stops — near the ptrace ceiling; the
  stop count itself only seccomp-notify can cut, and that stays deferred-by-data
  (realistic workloads aren't syscall-bound). **ptrace remains the documented
  default** (the roadmap's "seccomp-notify default" line is superseded by
  [ADR 0005](adr/0005-seccomp-notify-feasibility.md)). No fully-transparent
  pass-through fast-path exists in direction 1 (no agnos call shares Linux's
  number **and** return convention — even `write#1` needs `-errno`→`-1`).
