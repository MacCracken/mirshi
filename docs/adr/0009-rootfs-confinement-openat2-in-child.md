# 0009 — Rootfs confinement via openat2 RESOLVE_IN_ROOT in the child

**Status**: Accepted
**Date**: 2026-06-30

## Context

The [2026-06-30 audit](../audit/2026-06-30-audit.md) found the entire blocker tier is
**class-(c) path-escape**: mirshi's M2 transparent path pass-through stages the agnos
path verbatim and hands it to the host `open(2)`/`stat(2)`/etc. resolved in the
supervisor's own filesystem view — no chroot, no canonicalization, no rootfs prefix.
A bare-CLI child reaches any host path the uid can (confirmed: it exfiltrated a host
secret). The container mount namespace bounds the Docker vehicle, but mirshi itself
enforces nothing. The user chose **harden now, confine next** — this is the "confine"
half (0.7.1).

Constraints that shaped the mechanism:

- **Unprivileged** — the bare CLI runs at the operator's uid; `chroot`/`pivot_root`
  need `CAP_SYS_CHROOT`, so they are out.
- **TOCTOU-safe** — a userspace lexical canonicalization then `open` lets a symlink (or
  a racing host process) redirect resolution after the check; the kernel must resolve
  atomically.
- **Execute-in-child** ([ADR 0002](0002-execute-in-child-translation.md)) — mirshi
  rewrites ONE trapped agnos syscall to ONE Linux syscall that the kernel runs in the
  **child's** context (its fd table, its memory). So a confining anchor fd must live in
  the **child**, and a two-step "resolve-parent-then-act" is not expressible within one
  trapped syscall.

Empirically verified (compiled + ran C, and then mirshi itself): `openat2` with
`RESOLVE_IN_ROOT` anchored at a dirfd **clamps** absolute paths, `..` traversal, AND
symlink targets to the anchor — every escape form returns `ENOENT`, the host file is
unreadable, while in-root paths resolve. Unknown `resolve` bits → `EINVAL` (fail-closed).

## Decision

**Confine the child's filesystem to a configured `--root` by anchoring path resolution
at a per-child rootfd and rewriting `open#7` to `openat2(rootfd, …, RESOLVE_IN_ROOT)`
— done IN THE CHILD, kernel-enforced. Ship it in bites; under `--root`, any path op not
yet confined is DENIED fail-closed so `--root` is never a false-confidence footgun.**

- **`--root <dir>`** (opt-in; a loud stderr warning when absent in run mode). Without
  it, the transparent pass-through is unchanged — the container mount NS remains the
  boundary and the bare CLI is unconfined **by design** (documented).
- **rootfd in the child** (`src/intercept.cyr` `_child_exec`): open `--root` with
  `O_PATH|O_DIRECTORY` (no `O_CLOEXEC` — it must survive `execve`), `dup3` it to the
  fixed `ROOTFD` = 100, before the seccomp filter (so `dup3` needs no allowlist entry).
  `O_PATH` makes the fd inert as a data handle (`read`/`getdents` → `EBADF`) yet valid
  as an `openat2` anchor. **Fail-closed**: if the root won't open, abort the child.
- **`open#7` confined** (`src/dispatch.cyr`): stage the path + a 24-byte
  `struct open_how {flags = ao_to_o(aflags), mode = (O_CREAT ? 0600 : 0), resolve =
  RESOLVE_IN_ROOT}` in the red zone, synth `openat2(437)` with `rdi=ROOTFD`, `r10=24`.
  (`how.mode` must be 0 without `O_CREAT` — `openat2` is stricter than `open(2)`.)
- **Bite split.** **Bite 1**: `open#7` → `openat2 RESOLVE_IN_ROOT`. Every fd-based op
  (`read`/`write`/`lseek`/`dup`/`close`/`getdents#29`) rides a fd from a confined open,
  so it is transitively confined. **Bite 2**: the path-mutation+metadata ops
  (`mkdir#9`/`rmdir#10`/`unlink#30`/`rename#31`/`link#32`/`stat#33`) → the `*at` family
  (`mkdirat`/`unlinkat`(+`AT_REMOVEDIR` for rmdir)/`renameat2`/`linkat`/`newfstatat`)
  anchored at `ROOTFD`. The `*at` family has **no** `RESOLVE_*` (only `openat2` does) —
  verified empirically that `*at` with an absolute path ignores the dirfd and `..` walks
  out — so the supervisor **lexically sanitizes** the path first (`sanitize_rootrel`:
  strip leading `/`, **reject** any `..` component; `""`/`"/"` → `"."`), then stages the
  relative path. The sanitizer is pure and unit-tested.
- **The fd-clobber invariant** (load-bearing): clamping is safe ONLY because the child
  can never obtain an **unconfined** dirfd to `dup3` over `ROOTFD`. Every fd it holds
  came from a confined `open#7`; `dup`-ing a confined fd over `ROOTFD` only narrows the
  anchor to a sub-dir (verified). `close(ROOTFD)` → later `openat2` `EBADF` → fail-closed
  self-DoS, not escape. **The dispatcher must therefore never let a raw dirfd or
  `AT_FDCWD` reach the kernel** — every fd-producing path op stays confined.

## Consequences

- **Positive** — under `--root`, the class-(c) open/read/create/symlink/proc/dev/getdents
  escapes are **kernel-clamped** inside the root, unprivileged and TOCTOU-safe; the
  bare CLI gets real confinement and the Docker vehicle gets defense-in-depth over the
  mount NS. `--root` is never a false-confidence footgun — unconfined ops are denied,
  not silently escaping.
- **Negative / owned** — `--root` is **opt-in** (absent by default, with a warning),
  so an operator who forgets it is unconfined; the Docker image should add `--root /`.
  The bite-2 `*at` confinement is **lexical** (`sanitize_rootrel`), so it is
  `..`/absolute-safe but NOT symlink-safe for a **pre-existing** symlink component in the
  rootfs (a hostile symlink already in the root could redirect a mutation op) — a
  narrower **rootfs-trust** residual than the blocker tier, and unreachable for an agnos
  child since agnos has **no symlink syscall** (it cannot plant one). `open#7` has no such
  residual (`openat2 RESOLVE_IN_ROOT` is symlink-safe). The `..` semantics differ between
  classes: `open` **clamps** `..` (kernel), the mutation ops **reject** it (lexical) —
  both safe. One fixed `ROOTFD`=100 is consumed in the child's fd table. Linux 5.6+ only.
- **Neutral** — bites 1+2 confine the full path surface under `--root`. The remaining
  0.7.1 work is activating `--root /` in the Docker vehicle's `ENTRYPOINT` + an
  in-container escape-attempt assertion in the smoke gate (bite 3).

## Alternatives considered

- **`chroot`/`pivot_root` the child** — kernel-clean, but needs `CAP_SYS_CHROOT`; the
  unprivileged bare CLI can't, and in Docker the mount NS already does this. Rejected as
  the primary mechanism (unavailable unprivileged).
- **Supervisor-side lexical canonicalization + plain `open`** — collapse `..`, prepend
  the root, then `open` the absolute path in-child. Symlink-unsafe (the kernel follows a
  symlink component out of root after the lexical check) and TOCTOU-prone. Rejected for
  `open`; a constrained lexical form is the bite-2 tool for the `*at` ops, where no
  `RESOLVE_*` exists and agnos cannot create symlinks.
- **Emulate the open in the supervisor + inject the fd** — `openat2` in the supervisor
  (confined), then hand the fd to the child. No clean ptrace-only fd-injection primitive
  (`SECCOMP_IOCTL_NOTIF_ADDFD` needs seccomp-notify, which mirshi doesn't use; `SCM_RIGHTS`
  needs a socket dance). Rejected — the in-child `openat2` is simpler and direct.
- **`RESOLVE_BENEATH` instead of `RESOLVE_IN_ROOT`** — `BENEATH` *rejects* `..`/absolute
  (EXDEV) rather than *clamping* them. Clamping (`IN_ROOT`) is friendlier to agnos tools
  that pass absolute paths (rebased to the root) and is the chroot-like semantic the
  pass-through model expects. `RESOLVE_NO_SYMLINKS` is available as a stricter knob if a
  consumer needs symlinks rejected outright.
