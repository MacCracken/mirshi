# mirshi — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures
> (durable); this file is **state** (volatile).

## Version

**0.1.0** — scaffolded 2026-06-29 via `cyrius init`. No releases yet.

## Toolchain

- **Cyrius pin**: `6.3.5` (in `cyrius.cyml [package].cyrius`)

## Source

Initial scaffold only.

## Tests

- `tests/mirshi.tcyr` — primary suite (smoke + math; passes on `cyrius test`)
- `tests/mirshi.bcyr` — benchmark stub (no-op)
- `tests/mirshi.fcyr` — fuzz stub

## Dependencies

Direct (declared in `cyrius.cyml`):

- stdlib — string, fmt, alloc, io, vec, str, syscalls, assert

## Consumers

Intended: the **agnos CI/test fleet** (multi-container userland-concurrency fan-out),
**cloud deployment** (agnos-as-a-Linux-container), and later the **Linux-on-agnos
swallow** layer. None wired yet (scaffold).

## Target & boundary

- mirshi itself is a **Linux-target** Cyrius binary; it supervises **agnos-target** ELFs.
- v1 scope = direction 1 (AGNOS→Linux), headless CLI, no QEMU. Net band / multi-proc /
  graphics / the Linux→AGNOS swallow direction are post-v1 (see roadmap "Out of scope").
- Complements QEMU+KVM (real kernel) + iron (hardware truth); does not replace them.

## Next

See [`roadmap.md`](roadmap.md) — M0 real work = the ptrace trap loop over an agnos static ELF.
