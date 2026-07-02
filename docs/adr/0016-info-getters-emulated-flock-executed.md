# 0016 — Info getters supervisor-emulated (getuid / uname / sysinfo), flock execute-in-child

**Status**: Accepted (v1.8.0 — getuid#15 / uname#34 / sysinfo#35 / flock#59)
**Date**: 2026-07-01

## Context

v1.8.0 drains the **ENOSYS long-tail** — the non-structural rows that a general agnos userland reaches
for but that no prior band needed: `getuid#15`, `uname#34`, `sysinfo#35`, `flock#59`. Three are
identity/stat **info getters**; one is an **advisory lock**. The agnos ABI (frozen; the canonical struct
layouts live in the sibling `agnos` repo, `docs/development/agnos-userland-abi.md` §4.1–4.6, with the
kernel writers in `kernel/core/syscall.cyr` — *the code is truth*):

- `getuid#15()` → **0** (spec: "always root").
- `uname#34(buf, len)` → 0/-1: writes an **agnos-NATIVE** 64-byte struct — four 16-byte NUL-padded
  fields at 0/16/32/48 = `sysname`/`nodename`/`release`/`machine` (§4.3). **Not** Linux `utsname`.
- `sysinfo#35(buf, len)` → 0/-1: writes an **agnos-NATIVE** 40-byte struct — 5×u64 LE at 0/8/16/24/32 =
  `uptime_secs`/`totalram`/`freeram`/`procs`/`cpus` (§4.4). **Not** the ~112-byte Linux `struct sysinfo`.
- Both info getters **hard-reject `-1` if `len` < the struct size — no partial fill** (the kernel's
  `if (arg2 < N) return -1`).
- `flock#59(fd, op)` → 0/-1: BSD advisory whole-file lock, inode-keyed; `op` = `LOCK_SH=1`/`LOCK_EX=2`/
  `LOCK_UN=8` (+`LOCK_NB=4`) — **bit-identical to Linux**.

## Decision

**Info getters → supervisor-EMULATE (synthesize); `flock` → EXECUTE-in-child.** The dividing line is
whether the value is *agnos-identity* (must be synthesized) or a *real host fact / kernel primitive*
(best taken from the host).

### getuid#15 → EMULATE 0
Return 0 (covers `geteuid`, same #15). The agnos environment is always root; an execute-in-child
`getuid#102` would leak the **host's** uid. No child buffer, no fault surface.

### uname#34 → EMULATE, synthesized agnos identity
Write the agnos-native 4×16 struct: `sysname="AGNOS"` / `nodename="agnos"` / `release="mirshi"` /
`machine="x86_64"`, NUL-padded, `len<64`→-1. `sysname`/`machine` are the fixed AGNOS identity (an
execute-in-child Linux `uname#63` would return `"Linux"` + the 6×65 `utsname`, wrong on both count and
value). `nodename`/`release` are **value assumptions** (see Consequences).

### sysinfo#35 → EMULATE from LIVE HOST values
Write the agnos-native 5×u64 struct, `len<40`→-1, sourcing real host facts supervisor-side:
`uptime_secs` + `totalram` + `freeram` from the host Linux `sysinfo#99` (RAM = field × `mem_unit` →
bytes, matching the agnos kernel's `pages×4096`); `procs` = mirshi's tracked **agnos**-process count
(`_child_count`); `cpus` = popcount of the process affinity mask (`sched_getaffinity`). All reads are
supervisor-side → **no child-seccomp delta**. (Execute-in-child Linux `sysinfo#99` is rejected: it
returns the wrong ~112-byte struct and would need a full repack + would still miss `cpus`.)

### flock#59 → EXECUTE-in-child (a pure renumber)
`agnos_to_linux_nr(59) = flock(73)` — the op codes are bit-identical, so it's a plain renumber running on
the child's **real** fd (an advisory lock on an fd the child already holds). This is the **sole**
child-seccomp delta in v1.8.0 (`flock(73)`). The kernel's inode-keyed advisory lock is exactly the
agnos semantics; emulating it would reimplement the kernel for no gain. A `flock` on an emulated id
(signalfd/timerfd/epoll/socket) → the child runs `flock(high-id)` → EBADF → agnos -1 (safe *and*
correct — those aren't lockable files, so no `MIN_EMU_BASE` gate is needed, unlike read#5/close#6).

## Consequences

- **Positive** — a general agnos userland's identity/stat/lock probes work: `getuid`→0, `uname`/`sysinfo`
  return well-formed agnos-native structs (with real host uptime/RAM/CPU/lock behavior where that's the
  truth), and `flock` gives real inode-keyed contention across OFDs — proven by two separate `open()`s
  contending in one process. The three info getters add **zero** child-seccomp entries (all
  supervisor-side); `flock` adds exactly one.
- **Negative / owned — `uname` value assumptions** (no in-tree consumer to confirm; documented, revisit
  per a real consumer): `nodename="agnos"` matches the kernel default (which has no `sethostname` yet),
  but the real kernel writes `release=_AGNOS_VERSION` (e.g. `"1.51.6"`) whereas **mirshi writes
  `release="mirshi"`** — a deliberate, non-drifting choice that marks the shim (a program can detect it
  ran under mirshi via `uname.release`) while `sysname="AGNOS"` still satisfies agnos-identity checks. If
  a consumer needs a version-shaped `release`, revisit.
- **Negative / owned — `sysinfo` semantics** differ subtly from the kernel: mirshi's `procs` is the
  **live** agnos-process count vs the kernel's `proc_count` high-water (the kernel comment itself calls
  this a cosmetic stat with no control-flow dependence; the live count is arguably more accurate).
  `uptime`/`totalram`/`freeram`/`cpus` are the real **host** facts (mirshi runs on that host), degrading
  to 0/1 if the host reads fail.
- **Neutral** — the freeze test's `agnos_to_linux_nr` values are unchanged: #15/#34/#35 stay -1 (EMULATE,
  dispatcher-intercepted before the mapper); #59 gains `→73` (a real execute-in-child peer). Matrix rows
  #15/#34/#35 move ENOSYS→EMULATE, #59 ENOSYS→EXECUTE.

## Alternatives considered

- **Execute-in-child `getuid`/`uname`/`sysinfo`** — rejected: they'd return **host** facts in the wrong
  shape (`getuid`→the host uid; `uname`→`"Linux"` + 6×65 `utsname`; `sysinfo`→the ~112-byte Linux
  struct), violating the agnos-native ABI + leaking host identity. Synthesis is mandatory.
- **Emulate `flock`** (a supervisor-side inode-keyed lock table) — rejected: the host kernel already
  provides exactly the agnos advisory-lock semantics on the child's real fd; a renumber is correct and
  free, and a supervisor table would be a needless reimplementation that couldn't see the child's OFDs
  cleanly.
- **`release=_AGNOS_VERSION`** (mirror the kernel's version string) — rejected: mirshi isn't the agnos
  kernel and doesn't track its version; hardcoding it would drift. `"mirshi"` is honest + non-drifting.
