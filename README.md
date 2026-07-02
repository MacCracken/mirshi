# mirshi

> **mir**ror + **shim** — the bidirectional AGNOS↔Linux syscall-ABI translation layer.

Written in [Cyrius](https://github.com/MacCracken/cyrius), zero external dependencies.

## What it is

mirshi is a **userland syscall-translation supervisor** — the WSL1 / Wine / gVisor "pico-process" model, **not** kernel emulation and **not** a VM. One translation core, run from either side:

- **Direction 1 — AGNOS→Linux** (v1, shipped): supervise an **agnos-compiled static ELF running as a native Linux process**, intercept its agnos-ABI syscalls, and map them onto host Linux syscalls. **No QEMU, shared host kernel.** → agnos userland runs in a plain Docker container: multi-container test fan-out at scale + cloud-deployability (agnos presents as an ordinary Linux container).
- **Direction 2 — Linux→AGNOS** (v2+, the "swallow" stage): run Linux binaries **on the agnos kernel**, the permanent compat layer.

### Why it's needed (not a number remap)

agnos redefines the `Sys` enum to its own numbers — `exit`=0 on agnos vs 60 on Linux, the net band `#47–57` + `net_config#61` is a sovereign `sock_*`/`udp_*`/`icmp` ABI, `mmap#27` is 2 MB-granular. So an agnos static ELF doing `syscall(0,…)` hits Linux `read` without translation. Each agnos syscall gets a per-number **handler** that maps-with-arg-translation, **emulates** in userspace, or returns `ENOSYS`. agnos bins are static (no libc) → no `LD_PRELOAD`; interception is supervisor-side (ptrace).

## Runs today (direction 1)

- **Process + console** — `exit`/`write`/`read`/`getpid`/`mmap`/timers/`getrandom`.
- **Filesystem** — `open`/`read`/`write`/`stat`/`getdents`/`mkdir`/`rename`/`link`/… on a container rootfs, with optional kernel-enforced `--root` confinement ([ADR 0009](docs/adr/0009-rootfs-confinement-openat2-in-child.md)).
- **Network** — the sovereign net band is **complete**: TCP client + server, UDP, ICMP, and `net_config`, supervisor-emulated with **default-deny egress** (`--net` / `--net-allow`), [ADR 0012](docs/adr/0012-net-band-supervisor-emulated-conn-table.md).
- **Multi-process** — `spawn#3`/`waitpid#4`/`getpid#2`: a parent spawns children from in-memory ELF images and waits their exit codes, to arbitrary depth, under one `wait4(-1)` supervisor (per-child record table, opaque-monotonic pids, `MAX_CHILDREN` storm bound), [ADR 0013](docs/adr/0013-multiprocess-supervisor-fork-record-table.md).
- **Signals** — `pause#14`/`kill#16`/`sigprocmask#17`/`signalfd#18`: supervisor-emulated pending/blocked masks over the record table — self/child-scoped `kill`, a bounded-yield `pause`, and an opaque `signalfd` whose `read` delivers the raw signal number, [ADR 0014](docs/adr/0014-signal-band-supervisor-emulated-masks-signalfd.md).
- **I/O multiplexing** — `epoll#19–21`/`timerfd#22–23`/`pipe#25`: a server multiplexes a timerfd + a signalfd + a socket on one `epoll` set (epoll + timerfd supervisor-emulated with a heterogeneous **bounded-yield** `epoll_wait`; `pipe` execute-in-child), [ADR 0015](docs/adr/0015-io-mux-emulated-epoll-timerfd-executed-pipe.md).
- **The Docker vehicle** — a `FROM scratch` `agnos-mirshi` image runs agnos tools with **no QEMU**, seccomp-bounded and fan-out-ready.

See the [syscall-coverage matrix](docs/reference/syscall-coverage.md) for the frozen per-number contract, the [CLI reference](docs/reference/cli.md) for flags, and the [roadmap](docs/development/roadmap.md) for what's next.

## Discipline (what mirshi is NOT)

mirshi-in-Docker runs agnos userland on the **host** Linux kernel — it validates **userland concurrency + Linux-app compat at scale**, but does **not** exercise the agnos kernel's own SMP scheduler or net stack. It **complements, never replaces** QEMU+KVM (real kernel) + iron (hardware truth). Each surface owns a distinct bug class ([ADR 0011](docs/adr/0011-mirshi-qemu-iron-boundary-discipline.md)).

## Status

**Direction 1 (AGNOS→Linux) runs the net band, multi-process, signals, and I/O multiplexing.** v1.0 cut the hardened / audited / optimized / frozen foundation (agnos userland in Docker, no QEMU); v1.1–v1.4 added the full net band (TCP client + server, UDP, ICMP); v1.5.0 added **multi-process** (`spawn`/`waitpid`); v1.6.0 added **signals** (`kill`/`sigprocmask`/`signalfd`); v1.7.0 added **I/O multiplexing** (`epoll`/`timerfd`/`pipe`) — a server multiplexes timers, signals, and sockets on one epoll set. The authoritative version is [`VERSION`](VERSION) + [`CHANGELOG.md`](CHANGELOG.md); the live state snapshot is [`docs/development/state.md`](docs/development/state.md). Next up — info getters (`uname`/`sysinfo`) + `flock`, and the direction-2 swallow — see the [roadmap](docs/development/roadmap.md).

## Build

```sh
cyrius deps                               # resolve stdlib / sibling deps
cyrius build src/main.cyr build/mirshi    # compile (Linux-target supervisor)
cyrius test                               # run [build].test + tests/*.tcyr
```

Then run an agnos ELF: `build/mirshi ./hello` (see [getting started](docs/guides/getting-started.md)
and the [runnable examples](docs/examples/README.md)).

## License

GPL-3.0-only
