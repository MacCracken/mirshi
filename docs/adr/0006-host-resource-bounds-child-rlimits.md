# 0006 — Host-resource bounds via kernel-enforced child rlimits

**Status**: Accepted
**Date**: 2026-06-30

## Context

mirshi is a sandbox-class trust boundary: it runs foreign-ish agnos binaries and
translates their syscalls while holding host privilege. The 0.6.0 hardening
milestone requires that *"a child can't exhaust host fds / memory / PIDs via the
translation"* ([roadmap](../development/roadmap.md) 0.6.0). Two exhaustion vectors
are reachable through the translated surface as shipped in 0.1.0–0.5.0:

- **Memory** — agnos `mmap#27` ([ADR 0002](0002-execute-in-child-translation.md))
  is renumbered to Linux `mmap` and executed in-child; each call reserves ≥ 2 MB of
  address space (the dispatcher rounds up to the agnos 2 MB granule). A
  `while (1) mmap#27` storm had **no bound** — it could reserve memory until the
  host refused, and a variant that *faults* the pages would drive real RSS into an
  OOM.
- **File descriptors** — `open#7` / `dup#8` create fds in the child with **no
  bound**; an open-storm could exhaust the descriptor table (and host file-table
  memory).

The **PID / process** vector named in the roadmap is *already* closed structurally:
the bounding seccomp allowlist ([ADR 0004](0004-docker-vehicle-bounding-seccomp.md),
`src/seccomp.cyr`) carries no `clone`/`fork`/`vfork`/`clone3`, and agnos `spawn#3`
has no Linux peer so it dispatches `STRAT_ENOSYS` — a process storm cannot reach a
host `clone` at all.

So the real choice is **how** to bound the two reachable vectors: enforce in the
kernel, or account per-syscall in the supervisor.

## Decision

**Bound the two reachable exhaustion vectors with kernel-enforced rlimits set on
the child before `execve` — `RLIMIT_AS` (address space) and `RLIMIT_NOFILE` (open
fds) — and do *not* add per-syscall accounting in the dispatcher.** Scope:

- `src/limits.cyr` — `apply_child_rlimits()` calls `prlimit64(pid=0, …)` (NR 302;
  the stdlib has no rlimit wrapper, so the call is raw, matching the `src/seccomp.cyr`
  prctl/seccomp idiom). Caps: **`RLIMIT_AS` = 1 GiB**, **`RLIMIT_NOFILE` = 256**.
  Both soft and hard are set to the cap (lowering the hard limit needs no privilege;
  the child cannot raise them back).
- Installed in `_child_exec` **after `PTRACE_TRACEME`, before** `apply_child_bound`
  (seccomp) — so `prlimit64` needs **no** allowlist entry, and once the seccomp
  filter is up the child can never change its own limits (`prlimit64` is not
  allowlisted → `SIGSYS`).
- **Always on**, independent of `--no-seccomp`: a generous safety floor, not a
  debug-toggleable filter. Best-effort — a failed `prlimit64` is non-fatal (the run
  continues under the host defaults).
- **No `RLIMIT_NPROC`** — redundant with the seccomp fork bound, and a per-real-uid
  ceiling risks false `EAGAIN` if the container uid is shared.

When a storm hits a cap the kernel returns `-ENOMEM` / `-EMFILE` in-child, which the
existing return mapping (`linux_ret_to_agnos`) turns into the agnos failure sentinel
(`mmap#27` → `0`, `open#7`/`dup#8` → `-1`) — a clean **in-ABI** failure the agnos
allocator already handles, never a supervisor crash.

The caps are sized from the observed legit footprint (a CLI tool's whole-run address
space is low tens of MB: a ~70 KB ELF + an 8 MB stack reservation + 2 MB heap chunks
+ the supervisor image the child carries until `execve`). 1 GiB is ~4× the worst
plausible legit run yet hard-stops a storm at ~500 × 2 MB maps; 256 fds is vast
headroom for a tool that opens a handful of files. Both were verified to fire on an
**unlimited** host: a 2 MB-map storm bounded at **511 maps ≈ 1 GiB**, an `open("/")`
storm at **253 fds** (256 − stdin/out/err).

## Consequences

- **Positive** — the two reachable host-exhaustion vectors are closed with
  **zero supervisor hot-path cost** and **no TOCTOU**: the kernel enforces the bound
  in the child's own address space; the supervisor never counts or decrements
  `mmap`/`munmap`/`open`/`close`. The failure degrades to an in-contract agnos
  sentinel, so legit OOM-handling code paths exercise normally. The control is set
  before seccomp and unraisable thereafter.
- **Negative / owned** — the caps are **whole-child, coarse** (not per-call policy)
  and are **fixed constants** (no CLI override yet); a genuinely memory-hungry-but-
  legit future tool could need the 1 GiB raised. `RLIMIT_AS` counts *virtual*
  address space, so a tool that reserves (but never faults) a large sparse mapping is
  charged for it — acceptable for the agnos CLI surface, revisit if a consumer needs
  sparse VMAs. **`RLIMIT_AS` bounds virtual address space, NOT resident memory**: a
  hostile child that *faults* its mapped pages can drive real host RSS toward the
  ~1 GiB cap. Because there is exactly one child per mirshi invocation (no
  clone/fork), this is a **~1 GiB RSS floor per mirshi process**, not unbounded — but
  the host must not treat `RLIMIT_AS` as a resident-memory ceiling. The Docker vehicle
  ([ADR 0004](0004-docker-vehicle-bounding-seccomp.md)) **should** layer a cgroup
  `memory.max` around the container for the absolute resident bound; `RLIMIT_AS` is
  the in-process floor that also applies to the bare CLI / the ptrace ITs where no
  cgroup is present.
- **Negative / owned** — `prlimit64` is best-effort and its failure is currently
  swallowed (no diagnostic, to honor the no-I/O-between-`TRACEME`-and-`execve`
  discipline). A *silently* defeated cap is instead caught at the **test** layer: the
  fault harness asserts each storm bounds at the expected count (mmap ≈ 511, fd = 253),
  so a regression that disables the cap — whether a code change or a `prlimit64`
  failure — fails CI rather than passing unnoticed.
- **Neutral** — the fault-injection harness (`scripts/it/fault_inject.sh`) gains an
  mmap-storm and an open-storm case and is wired into CI as a gate; the cap *values*
  are a tuning surface the 0.8.0 optimization / real-consumer work may revisit.

## Alternatives considered

- **Per-syscall accounting in the dispatcher** (a running `_mmap_total` / `_fd_count`
  incremented on `mmap`/`open`, decremented on `munmap`/`close`, with the sentinel
  injected past a cap) — rejected: it adds supervisor hot-path cost and bookkeeping
  to every memory/fd call, must correctly track `munmap`/`close`/`dup` to avoid
  drift, and only bounds *virtual* reservation anyway (it cannot stop a child from
  faulting pages it already mapped). The kernel already does this accounting for
  free and more correctly via rlimits.
- **`RLIMIT_DATA` instead of / with `RLIMIT_AS`** — `RLIMIT_DATA` includes mmap'd
  anonymous memory only since Linux 4.7 and is kernel-version-sensitive; `RLIMIT_AS`
  is the portable, unambiguous total-address-space bound that sandbox tooling uses.
- **`RLIMIT_NPROC` for the PID vector** — unnecessary: the seccomp allowlist has no
  `clone`/`fork` and `spawn#3` is `ENOSYS`, so a process storm is already structurally
  impossible; `RLIMIT_NPROC` is per-uid and would add a false-`EAGAIN` footgun for no
  gain.
- **legacy `setrlimit(160)`** — works (same 16-byte struct on x86_64) but `prlimit64`
  is the modern canonical path, accepts `pid=0` for self, and matches mirshi's
  explicit-modern-syscall-number style (`getdents64#217`, `getrandom#318`).
- **Container-level cgroup memory/pids limits** — a real complementary control at the
  Docker layer, but it bounds the *whole container*, not the per-child translation
  surface, and is absent when mirshi runs outside a container (the bare CLI / the
  ptrace ITs). The child rlimit is the supervisor's own floor; cgroups stack on top.
