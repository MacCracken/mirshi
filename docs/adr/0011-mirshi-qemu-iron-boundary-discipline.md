# 0011 — The mirshi / QEMU / iron boundary discipline

**Status**: Accepted
**Date**: 2026-06-30

## Context

mirshi runs agnos-compiled userland as **native Linux processes on the host kernel**
(direction 1: a ptrace pico-process supervisor, NOT kernel emulation, NOT a VM). That is
exactly what makes it valuable — it is cheap to start, packs densely, fans out across a
container fleet, and deploys to the cloud, all with **no QEMU and no agnos kernel in the
loop**. That same convenience is a hazard: it is tempting to treat a green mirshi run as
evidence that "agnos works," and to let the slow, heavier validation surfaces atrophy.

There are three distinct validation surfaces, each owning a **different bug class**:

- **mirshi** — agnos *userland* on the *host Linux* kernel. Exercises the agnos-ABI →
  Linux-ABI translation, userland concurrency, and Linux-app compatibility **at scale**.
- **QEMU + KVM** — agnos userland on the *real agnos kernel*. Exercises the agnos kernel
  itself: its SMP scheduler, syscall entry, VFS, the sovereign net stack, memory management.
- **iron** (real hardware) — the whole stack on *real devices*. Exercises hardware truth:
  timing, firmware, drivers, interrupts, the things no emulator faithfully reproduces.

A bug in the agnos *kernel's* SMP scheduler, its net stack, or a driver is **invisible to
mirshi by construction** — mirshi never runs that code; it substitutes the host Linux
kernel. So mirshi can be 100 % green while the agnos kernel is broken, and vice versa.

## Decision

**mirshi *complements*, never *replaces*, QEMU+KVM and iron. Each surface gates its own
bug class; a green result on one is never accepted as evidence for another. mirshi owns
userland-concurrency + Linux-compat-at-scale validation — it does NOT validate
agnos-kernel SMP / scheduler / net-stack / driver / boot behavior, which remain QEMU's and
iron's jobs.**

| surface | runs on | validates (its bug class) | does NOT validate |
|---|---|---|---|
| **mirshi** | host Linux kernel | agnos-ABI translation, userland concurrency, Linux-app compat, fan-out at scale | the agnos kernel — SMP, scheduler, net stack, drivers, boot |
| **QEMU+KVM** | emulated machine, **real agnos kernel** | agnos kernel logic: SMP scheduler, syscall entry, VFS, sovereign net band, MM | hardware-specific timing / firmware / driver truth |
| **iron** | real hardware | hardware truth: timing, firmware, drivers, interrupts, real devices | nothing above it (it is ground truth) — but it is slow + scarce |

Concretely: CI keeps the QEMU and iron gates as first-class, **not** demoted because
mirshi is faster. mirshi is the **fan-out / compat** tier (run N agnos tools across a
container fleet); QEMU is the **real-kernel** tier; iron is the **hardware-truth** tier.
A feature touching the agnos kernel is not "done" on a mirshi pass alone.

## Consequences

- **Positive** — names the boundary explicitly so the team can reason about *which* surface
  a given test result speaks for. mirshi's speed/scale is harnessed for what it is actually
  authoritative about (userland + compat), without overclaiming kernel correctness. The v1
  goal ("AGNOS + mirshi in a plain Docker container, no QEMU") is delivered **without**
  eroding the kernel/hardware validation discipline.
- **Negative / owned** — two-or-three-surface validation is more process than "just run
  mirshi." The standing risk is **convenience drift**: a green mirshi fleet *feels* like
  proof, and the slower QEMU/iron gates can quietly rot. Countering that is a discipline
  cost we accept and must actively defend (CI keeps those gates first-class).
- **Neutral** — direction 2 (the Linux→AGNOS "swallow", v2+) runs the same translation core
  from the other side; it is a *fourth* surface with its own bug class (Linux-app compat on
  the agnos kernel) and does not change this boundary.

## Alternatives considered

- **Full-system emulation (QEMU) as the only validation path** — faithful to the real
  kernel, but slow and heavy: it does not fan out cheaply across a container fleet and is
  poor for the userland-compat-at-scale and cloud-deploy goals. Rejected as the *sole* path
  — it stays the real-kernel tier, complemented by mirshi for scale.
- **Replace QEMU with mirshi** — the convenience temptation this ADR exists to refuse.
  mirshi runs agnos userland on the *host* kernel, so it cannot validate the agnos kernel at
  all; replacing QEMU with it would silently delete an entire bug class. Rejected.
- **Leave the discipline implicit** (in CLAUDE.md + the roadmap prose only) — it was, and
  that is precisely how convenience drift starts. Promoted to an ADR so the boundary is a
  cited, load-bearing decision rather than folklore.
