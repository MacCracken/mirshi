# 0004 — The Docker vehicle (FROM scratch) + child bounding seccomp

**Status**: Accepted
**Date**: 2026-06-29

## Context

M3 is the v1 *vehicle*: package mirshi + an agnos userland so `docker run` an
agnos binary works in a plain container with **no QEMU**, and demonstrate the
multi-container fan-out (boot N containers, throw concurrent agnos-userland
workloads across heterogeneous Linux hosts — the near-term test-fleet win).

Two design questions:

1. **What base image?** mirshi (Linux-target) and the agnos tools (agnos-target)
   are all statically linked with no libc.
2. **How to bound the child?** A container normally gets Docker's default seccomp
   profile as a strong bound — but that profile blocks `ptrace`, which mirshi
   needs. Running `--security-opt seccomp=unconfined` (or adding
   `CAP_SYS_PTRACE`) to enable ptrace *removes* that bound. So the child runs
   effectively unconfined unless mirshi re-establishes a bound itself.

While bringing up the mirshi-side seccomp filter, an empirical kernel-ordering
fact surfaced that is load-bearing: **on this kernel seccomp is evaluated at
syscall entry AFTER the `PTRACE_SYSCALL` rewrite**, so the filter sees mirshi's
*output* (the translated Linux number, or `0xFFFFFFFF` for the `orig_rax=-1`
skip), **not** the agnos input. A naive "allow agnos numbers `[0..61]`" filter
let `hello` print, then killed it with `SIGSYS` (exit 159) — because `exit#0` was
rewritten to `exit_group#231`, which `> 61`.

## Decision

- **`FROM scratch` image.** The image contains only `/mirshi`, the agnos-target
  ELFs under `/bin`, and a tiny `/data` rootfs. Static no-libc binaries need no
  base OS, shell, or loader — which *guarantees* no QEMU and a tiny (~58 KB)
  attack surface. `ENTRYPOINT ["/mirshi"]`, so `docker run agnos-mirshi /bin/X`
  runs `mirshi /bin/X`. Built by `docker/build.sh` (compile on host → stage →
  `docker build`); proven by `docker/smoke.sh`; fan-out by `docker/fanout.sh`.
- **Child bounding seccomp = an allowlist of mirshi's OUTPUT syscalls.** Because
  seccomp sees mirshi's post-rewrite numbers, the filter (`src/seccomp.cyr`,
  installed in the child after `PTRACE_TRACEME`, before `execve`, with
  `PR_SET_NO_NEW_PRIVS`) allows exactly the Linux syscalls the dispatcher emits
  (`read`/`write`/`open`/…/`getdents64`/`exit_group`/`getrandom`), the `0xFFFFFFFF`
  skip sentinel, and the child's own `execve`/`exit`; everything else is
  `SECCOMP_RET_KILL_PROCESS`. Default-on in run mode, `--no-seccomp` opt-out, and
  **off in trace mode** (SYSEMU leaves agnos numbers unrewritten, so the
  output-allowlist would not fit).
- **Container run recipe** (documented): `--cap-add=SYS_PTRACE
  --security-opt seccomp=unconfined` for stock Docker whose default profile
  blocks ptrace.

The seccomp default-deny **completeness proof** (and per-arg tightening) is the
0.7.0 security sweep; M3 ships the working allowlist bound + `NO_NEW_PRIVS`.

## Consequences

- **Positive** — the image is tiny and demonstrably QEMU-free; the acceptance
  (`docker run` an agnos tool, correct output/exit) and fan-out are proven in CI
  (`docker/smoke.sh`). The bound caps the child to mirshi's translation output:
  even a *mis-translation bug* that rewrote to a dangerous syscall (`mount`,
  `ptrace`, `bpf`, …) is `SIGSYS`-killed rather than executed.
- **Negative / owned** — the allowlist is **coupled to the translation set**: a
  future milestone that translates to a new Linux syscall must add it to
  `_bound_allowlist` or the child is killed when it runs. This coupling is called
  out in `src/seccomp.cyr`.
- **Negative** — what the bound actually catches is a *mirshi* mis-translation,
  not a malicious agnos syscall (mirshi already neutralizes those by rewriting
  every trapped call). It is defense-in-depth on mirshi's own correctness, not a
  primary control. Honest framing matters; the primary control is the ptrace
  interception + the container boundary.
- **Neutral** — `FROM scratch` means no in-container debugging tools; the build
  is host-compile-then-package (a fully in-Docker multi-stage build with the
  toolchain in a builder stage is a possible future refinement).

## Alternatives considered

- **A minimal base (alpine/debian-slim)** instead of scratch — ergonomic (a
  shell for debugging) but ships a libc + busybox/coreutils (more surface) and
  makes the "no QEMU / nothing but mirshi" property something you assert rather
  than something the image structurally guarantees. Rejected for the v1 vehicle;
  a debug variant could layer a shell on top.
- **Rely on the container's seccomp profile for the bound** — impossible as the
  primary mechanism: the profile must be loosened (`seccomp=unconfined` / cap-add)
  for mirshi's ptrace, which removes it. The mirshi-side filter exists precisely
  to compensate.
- **Allow the agnos number range `[0..61]`** — refuted empirically: seccomp sees
  mirshi's *post-rewrite* Linux numbers, so this killed every translated call
  (`exit_group#231`, `getdents64#217`, `getrandom#318`, …). The output-allowlist
  is the only correct shape given the kernel ordering.
