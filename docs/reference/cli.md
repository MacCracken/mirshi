# mirshi — CLI contract (frozen)

> **Frozen at v0.9.0.** The command-line surface of the `mirshi` supervisor. Source of
> truth is `src/main.cyr` (parsing + `usage`) and the `MirshiPtrace` exit-code constants
> in `src/intercept.cyr`; pinned by `scripts/it/cli.sh`. Changing a flag, the synopsis, or
> an exit code is a deliberate contract change — update the code, this doc, and the pin.

## Synopsis

```
mirshi [--selftest-trace] [--no-seccomp] [--root <dir>] <agnos-elf>
```

Runs `<agnos-elf>` (an agnos-target static ELF) as a native Linux process by trapping +
translating its agnos-ABI syscalls — no QEMU, shared host kernel. **Flags must precede
`<agnos-elf>`**; parsing stops at the first non-flag argument (which is the target). Any
arguments after the target are ignored (the agnos child is run with a fixed `argv` —
mirshi does not forward a child argv in v1).

## Flags

| flag | effect |
|---|---|
| *(none)* | **Run mode** (default): translate + execute the agnos syscalls. Bounding seccomp **on**; filesystem **unconfined** (a loud stderr warning is printed — see below). |
| `--selftest-trace` | **Trap-log mode (M0)**: `PTRACE_SYSEMU`-trap every syscall and emit the bare agnos syscall stream (`name#nr(args)`) to **stdout**; translate/execute **nothing**. seccomp and `--root` do not apply in this mode (the child's syscalls never reach the kernel). Tears down on agnos `exit#0`. |
| `--no-seccomp` | Disable the bounding seccomp allowlist on the child (default: **on**). Measures/debugs the raw trap+translate path; the child is then bounded only by the rlimits + (if set) `--root`. |
| `--root <dir>` | **Confine** the child's filesystem to `<dir>`, kernel-enforced + unprivileged ([ADR 0009](../adr/0009-rootfs-confinement-openat2-in-child.md)): `open#7`→`openat2 RESOLVE_IN_ROOT`, the `*at` family for mutation/metadata, anchored at a per-child rootfd. Requires a `<dir>` argument (else `usage`). Run mode only. **Fail-closed**: if `<dir>` won't open, the child is aborted (`BOUND_FAILED`), never run unconfined. |

## Modes at a glance

- **`mirshi <elf>`** — run, seccomp-bounded, **unconfined fs** (+ warning). The container
  mount namespace is the fs boundary for the v1 Docker vehicle.
- **`mirshi --root <dir> <elf>`** — run, seccomp-bounded, fs confined to `<dir>` (the
  bare-CLI confinement; the Docker vehicle does not need it).
- **`mirshi --selftest-trace <elf>`** — trap-log only, no translation (the M0 proof).
- **`mirshi --no-seccomp <elf>`** — run without the bounding filter (benchmark/debug).

## Standard streams

- The child's **stdout/stderr** pass through (e.g. `write#1` to fd 1/2 runs in the child).
- **`--selftest-trace`** writes the trap log to **stdout**.
- mirshi's own diagnostics go to **stderr**, including:
  - `mirshi: WARNING — no --root: child has UNCONFINED host filesystem access` (run mode,
    no `--root`).
  - `mirshi: ENOSYS agnos#<n> -> -1` (an out-of-surface syscall degraded to the agnos
    error sentinel; see [the syscall matrix](syscall-coverage.md)).
  - fail-closed aborts: `--root open failed …`, `seccomp bound failed to install …`,
    `execve failed`, `fork failed`, `waitpid failed`.

## Exit codes

mirshi propagates the child's fate; its own failures use a high reserved band.

| code | meaning |
|---|---|
| `0`–`255` | the agnos child's own exit code (`exit#0`), propagated verbatim (e.g. `42`). |
| `128 + N` | the child was terminated by signal `N`. |
| `2` | **usage** — bad invocation (no `<agnos-elf>`, or `--root` without a `<dir>`). |
| `125` | `WAIT_FAILED` — mirshi's `waitpid` failed irrecoverably. |
| `126` | `BOUND_FAILED` — the seccomp filter or `--root` rootfd could not be set up; the child was **aborted fail-closed**, never run unbounded/unconfined. |
| `127` | `EXECVE_FAILED` — `execve(<agnos-elf>)` failed (missing / non-ELF / wrong-arch), or the child exited before tracing could begin (bad ELF). |
| `1` | `fork` failed. |

## Examples

```sh
mirshi ./hello                      # run an agnos hello-world (seccomp on, fs unconfined + warning)
mirshi --root ./rootfs ./ls /       # run confined to ./rootfs
mirshi --selftest-trace ./hello     # log the agnos syscall stream, translate nothing
mirshi --no-seccomp ./catbig.agnos  # run unbounded (benchmark/debug)
```

In the **Docker vehicle** the image's `ENTRYPOINT` is `mirshi`, so `docker run agnos-mirshi
/bin/hello` is `mirshi /bin/hello` inside the container — the mount namespace is the fs
boundary, so `--root` is not needed there (see [the fan-out guide](../guides/docker-fanout.md)).
