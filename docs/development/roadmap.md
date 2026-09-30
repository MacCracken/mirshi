# mirshi — Roadmap

> **Forward-looking sequencing** — what ships next, in what order, against what gates. The completed
> v0.1.0 → v1.4.0 detail has been retired to [`../../CHANGELOG.md`](../../CHANGELOG.md) (per-release)
> and [`state.md`](state.md) (live snapshot); this file keeps only a compact shipped-ledger + the
> planned minors.
>
> **Discipline** ([ADR 0011](../adr/0011-mirshi-qemu-iron-boundary-discipline.md)): mirshi runs agnos
> userland on the *host* Linux kernel — it validates **userland concurrency + Linux-app compat at
> scale**, NOT the agnos kernel's own SMP scheduler / net stack. It **complements, never replaces**
> QEMU+KVM (real kernel) + iron (hardware truth). Each surface owns a distinct bug class.

## The core technical problem

agnos redefines the `Sys` enum to its own numbers (`exit`=0 vs Linux 60; the net band #47–57/#61 is a
sovereign `sock_*`/`udp_*`/`icmp` ABI; `mmap#27` is 2 MB-granular; `sock_recv#49` has inverted EOF;
`spawn#3` runs an **in-memory** ELF). So translation is a **per-number handler table**, not a remap:
each agnos syscall either (a) **executes** in the child (renumber + arg-translate to a Linux peer),
(b) is **emulated** supervisor-side over Linux primitives, or (c) returns **ENOSYS**. agnos binaries
are **static, no libc** → no `LD_PRELOAD`; interception is supervisor-side (ptrace today; seccomp-notify
studied and **deferred-by-data**, [ADR 0005](../adr/0005-seccomp-notify-feasibility.md)).

## Shipped (v0.1.0 → v1.10.2)

The functional v1 surface, the pre-1.0 quality arc, the v1.0 clean cut, the post-v1 net band,
multi-process, signals, I/O multiplexing, the info-getter long-tail, and tty sizing are **done** —
**direction 1 is feature-complete** (every defined, non-kernel-only agnos syscall is handled). Full per-release detail:
[`../../CHANGELOG.md`](../../CHANGELOG.md). Frozen per-number contract:
[`../reference/syscall-coverage.md`](../reference/syscall-coverage.md). Ledger:

| Band | Versions | What |
|---|---|---|
| **Functional v1 surface** | v0.1–v0.5 | M0 trap loop → M1 process/console → M2 filesystem → M3 Docker vehicle + fan-out → M4 seccomp-notify feasibility (deferred-by-data) |
| **Pre-1.0 quality arc** | v0.6–v0.9 | hardening → security sweep (default-deny seccomp proven) → rootfs confinement (`--root`) → optimizations (exit-stop single-register I/O) → freeze + docs |
| **v1.0 — the clean cut** | v1.0.0 | a representative AGNOS userland in a `FROM scratch` Docker container, **no QEMU**, seccomp-bounded, fan-out-ready |
| **Net band (post-v1)** | v1.1–v1.4 | TCP client → TCP server → UDP + `net_config` → ICMP: the sovereign net band (#47–57, #61), supervisor-EMULATE, egress default-deny ([ADR 0012](../adr/0012-net-band-supervisor-emulated-conn-table.md)) — **complete** |
| **Multi-process (post-v1)** | v1.5.0 | `spawn#3`/`waitpid#4`/`getpid#2` — the **agnsh crown jewel**: a parent spawns in-memory-ELF children + waits their exit codes, to arbitrary depth, under one `wait4(-1)` supervisor; opaque-monotonic pids, `MAX_CHILDREN` storm bound, deadlock guard ([ADR 0013](../adr/0013-multiprocess-supervisor-fork-record-table.md)) |
| **Signals (post-v1)** | v1.6.0 | `pause#14`/`kill#16`/`sigprocmask#17`/`signalfd#18` — the shell's notification half: supervisor-emulated pending/blocked masks over the record table, `kill` self/child-scoped, a **bounded-yield** `pause`, and an opaque `signalfd` whose `read#5` delivers the raw signal number ([ADR 0014](../adr/0014-signal-band-supervisor-emulated-masks-signalfd.md)) |
| **I/O multiplexing (post-v1)** | v1.7.0 | `epoll#19–21`/`timerfd#22–23`/`pipe#25` — the **event loop**: epoll + timerfd **supervisor-emulated** (a heterogeneous **bounded-yield** `epoll_wait` — `ppoll` sockets + mask-test signalfds + clock-test timerfds), `pipe` **execute-in-child**; the tag ladder + `_emu_classify` read#5/close#6 front gate; socket-watching best-effort ([ADR 0015](../adr/0015-io-mux-emulated-epoll-timerfd-executed-pipe.md)) |
| **Info getters + locks (post-v1)** | v1.8.0 | `getuid#15`/`uname#34`/`sysinfo#35`/`flock#59` — the **ENOSYS long-tail**: the info getters **supervisor-emulated** (synthesized agnos-native structs — `getuid`→0, `uname`/`sysinfo` from live host values, never leaking host identity), `flock` **execute-in-child** (real inode-keyed advisory lock) ([ADR 0016](../adr/0016-info-getters-emulated-flock-executed.md)) |
| **tty sizing (post-v1)** | v1.9.0 | `winsize#60` — the **whole direction-1 graphics surface** (no `fbinfo`/`blit` exists): **supervisor-emulated** `(cols<<16)\|rows` from the controlling terminal's `TIOCGWINSZ` (80×24 default, always a usable size), consumer-verified against darshana ([ADR 0017](../adr/0017-winsize-emulated-tiocgwinsz.md)). **Direction 1 feature-complete.** |

## Planned — the direction-2 major

**Direction 1 (AGNOS→Linux) is feature-complete** — every defined, non-kernel-only agnos syscall is
handled (the matrix's only ENOSYS rows are the agnos-kernel-only ops + the undefined ABI gaps). What
remains is the mirror half:

### v2.0.0 — Direction 2: the Linux→AGNOS "swallow"
Run **Linux** binaries **on the agnos kernel** — the permanent compat layer, the mirror half of the
mirror-shim, and a **major** bump. An entirely separate validation surface: the same translation core
run from the other side. Per [ADR 0011](../adr/0011-mirshi-qemu-iron-boundary-discipline.md) this still
never replaces QEMU+iron.

## Not planned (agnos-kernel-only / permanent ENOSYS)

`mount#11` / `umount#24` / `reboot#13` / `write_boot_checkpoint#26` are agnos-**kernel** operations with
no meaningful host-Linux translation (on agnos itself they stub or halt); mirshi returns ENOSYS by
design. The undefined agnos# gaps (36–39, 42–44) are ABI holes, not syscalls. Neither is a milestone.

## Moving the cyrius pin to 6.6.6

**Current pin: `cyrius = "6.6.2"` (cyrius.cyml:7).** Pure pin bump — nothing in
mirshi's source needs to change.

**The Windows `O_APPEND`/`O_TRUNC` corruption fix does not apply to mirshi, and
the grep hits are a false positive worth writing down.** `AO_TRUNC` / `AO_APPEND`
appear at `src/translate.cyr:60-61` (and the assertions at
`tests/mirshi.tcyr:201-202`, plus `docker/tools/cp.cyr:14` and
`docker/tools/rdtest.cyr:12`) — those are **AGNOS** open flags being translated
to Linux ones, not PE opens. mirshi's product is "run agnos-compiled userland as
native Linux processes in a plain Docker container, shared host kernel"
(cyrius.cyml:4); there is no PE target and no `_TARGET_PE` / `CYRIUS_TARGET_WIN`
guard anywhere in `src/`. 6.6.6's `_pe_open_flags` fix is a non-event here.

**Checked and clear on the rest of the 6.6.6 list:**

- **Global redeclaration** — `var r = main();` appears at `src/main.cyr:153` and
  `src/test.cyr:10`. Those are two alternative *entry points*, never co-linked,
  so neither the new "last definition wins from program start" behaviour nor the
  new different-type/size compile error can fire.
- **The new compile errors** — zero `struct` declarations, zero `async` fns,
  zero `operator` fns, zero top-level `{ }` blocks, zero `ret2`/`rethi` pair
  returns, zero SIMD-typed returns. `src/decode.cyr:64` has the repo's only
  `: cstring` — it is a *return* type (`fn agnos_nr_name(nr): cstring`), and the
  6.6.6 tightening is about a literal int passed into a `: cstring` **parameter**,
  so it does not apply.
- **assert.cyr now pulls in vec.cyr transitively** — `[deps] stdlib` already
  names both `assert` and `vec`, and mirshi defines no `vec_*` of its own, so
  there is nothing to collide.
- **`lib/regression.cyr` is vendored** (with `lib/regression_agnos.cyr` and
  `lib/io.cyr`) but mirshi calls no `regression_*` helper from `src/`,
  `programs/` or `tests/` — the only hits are comments in `lib/net.cyr:489` and
  `lib/regression_agnos.cyr`. The new per-verb deadline
  (`CYRIUS_CHECK_TIMEOUT`, 120 s; ssh/scp 900 s, `-2` on timeout) and
  `PR_SET_PDEATHSIG` change nothing here — though the shell harnesses under
  `scripts/it/` run their own children and are worth a look if any legitimately
  runs past two minutes.

**Verify after bumping:** re-run `cyrius deps` so the vendored fold picks up
6.6.6's rewritten `lib/io.cyr` and `lib/regression.cyr`, then `cyrius build` +
`cyrius test`. Measured: `cyrius build` under 6.6.2 and under 6.6.6 both exit 0
with the same single diagnostic.
