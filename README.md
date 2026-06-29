# mirshi

> **mir**ror + **shim** — the bidirectional AGNOS↔Linux syscall-ABI translation layer.

Written in [Cyrius](https://github.com/MacCracken/cyrius), zero external dependencies.

## What it is

mirshi is a **userland syscall-translation supervisor** — the WSL1 / Wine / gVisor "pico-process" model, **not** kernel emulation and **not** a VM. One translation core, run from either side:

- **Direction 1 — AGNOS→Linux** (v1, build-first): supervise an **agnos-compiled static ELF running as a native Linux process**, intercept its agnos-ABI syscalls, and map them onto host Linux syscalls. **No QEMU, shared host kernel.** → agnos userland runs in a plain Docker container: multi-container test fan-out at scale + cloud-deployability (agnos presents as an ordinary Linux container).
- **Direction 2 — Linux→AGNOS** (v2+, the "swallow" stage): run Linux binaries **on the agnos kernel**, the permanent compat layer.

### Why it's needed (not a number remap)

agnos redefines the `Sys` enum to its own numbers — `exit`=0 on agnos vs 60 on Linux, the net band `#45-#57` is a sovereign `sock_*`/`udp_*`/`icmp` ABI, `mmap#27` is 2 MB-granular. So an agnos static ELF doing `syscall(0,…)` hits Linux `read` without translation. Each agnos syscall gets a per-number **handler** that maps-with-arg-translation, **emulates** in userspace, or returns `ENOSYS`. agnos bins are static (no libc) → no `LD_PRELOAD`; interception is supervisor-side (ptrace → seccomp-user-notify).

## Discipline (what mirshi is NOT)

mirshi-in-Docker runs agnos userland on the **host** Linux kernel — it validates **userland concurrency + Linux-app compat at scale**, but does **not** exercise the agnos kernel's own SMP scheduler or net stack. It **complements, never replaces** QEMU+KVM (real kernel) + iron (hardware truth). Each surface owns a distinct bug class.

## Status

**v0.1.0 — scaffold.** v1 target = *AGNOS + mirshi runs in a plain Docker container, no QEMU.* See [docs/development/roadmap.md](docs/development/roadmap.md).

## Build

```sh
cyrius deps                              # resolve stdlib deps
cyrius build src/main.cyr build/mirshi    # compile (Linux-target supervisor)
cyrius test                              # run tests
```

## License

GPL-3.0-only
