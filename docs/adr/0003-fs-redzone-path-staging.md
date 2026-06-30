# 0003 — Filesystem translation: red-zone path staging + exit-stop repack

**Status**: Accepted
**Date**: 2026-06-29

## Context

M2 translates the agnos filesystem syscalls so an agnos `cat`/`cp`/`ls`-class
tool reads+writes a real fs. Two ABI mismatches make this more than a renumber:

1. **Paths are explicit-length, not NUL-terminated.** agnos `open(name, namelen,
   flags)` passes a pointer + length into the child's memory; Linux `open(path,
   …)` wants a NUL-terminated C string. With M1's execute-in-child model (the
   kernel runs the call *as the child*, dereferencing the child's pointers),
   the NUL-terminated path has to live somewhere the **child** can see.
2. **Some output structs differ in layout.** `stat` is 48 B (agnos) vs 144 B
   (Linux); `getdents` records differ field-for-field. The child hands us a
   pointer to its agnos-layout output buffer, but the kernel writes the Linux
   layout.

`open` flags also differ (`AO_CREAT 0x100` vs `O_CREAT 0x40`, `AO_DIRECTORY
0x800` vs `O_DIRECTORY 0x10000`), and Linux `open` with `O_CREAT` needs a mode
agnos never supplies.

The crux is: where does the supervisor put a child-visible NUL-terminated path
(and a Linux-layout scratch struct), given M1 deliberately never needed any
child-writable scratch?

## Decision

**Stage transient data in the child's stack red zone, via `process_vm_writev`;
keep every fs call an execute-in-child renumber; repack output structs at the
exit stop.**

- **Red-zone staging** (`src/scratch.cyr`): at the syscall-enter stop the child
  is stopped *in-kernel*, so its user stack is idle. The supervisor writes the
  NUL-terminated path into `[rsp − 128 − N, rsp − 128)` (below the 128-byte
  x86_64 red zone) with `process_vm_writev`, and points the Linux path
  register(s) there. Two-path calls (`rename`/`link`) get two non-overlapping
  slots; `stat`/`getdents` get an additional below-path slot for the Linux output
  struct. Every transfer's return is checked == requested; a short transfer
  (page boundary / bad pointer / hostile length) fails the call with the agnos
  `−1` sentinel rather than proceeding truncated. `namelen` is bounded by
  `PATH_MAX` before the read.
- **Flag/mode translation** (`src/translate.cyr`, pure): `ao_to_o` maps `AO_*`→
  `O_*` bit-by-bit; `open` synthesizes mode `0644`, `mkdir` `0777`.
- **Exit-stop repack** (`fs_exit_return`): for `stat`/`getdents` the kernel wrote
  the Linux struct into the red-zone scratch; the supervisor reads it back
  (`process_vm_readv`), repacks to the agnos layout (pure `stat_repack_144_to_48`
  / `getdents_repack`), and writes it into the child's saved original pointer.
  `getdents` returns the *repacked* byte count.
- **Path policy**: transparent pass-through — agnos `/foo` → host `/foo`, no
  prefix/chroot. The rootfs boundary is the **M3** Docker mount namespace;
  `..`/symlink-escape hardening is **0.7.0**. A naive string prefix now would be
  false confinement, so it is intentionally *not* shipped as "secure".
- **Symlinks**: agnos has no symlink/readlink syscall; `link#32` is a **hardlink**
  → Linux `link(86)`, never `symlink(88)`. `stat`/`getdents` still *report*
  symlink type/mode faithfully.

## Consequences

- **Positive** — no new per-child state, no injected mmap, no child-page
  allocator: red-zone scratch is implicitly reclaimed when the syscall returns
  and composes with M1's enter-rewrite/exit-map loop unchanged. The pure
  translation arithmetic stays unit-testable; the impure surface is just two raw
  `process_vm_*` wrappers + `stage_at`.
- **Negative / owned** — red-zone scratch is valid *only* while the child is
  stopped and only with stack headroom (a write near the stack guard page short-
  fails rather than auto-growing — hence the strict transfer-length check). The
  stat/getdents output pointers ride one-slot supervisor globals, safe only
  because there is one in-flight call per child under strict enter/exit
  alternation (multi-child must replace them).
- **Negative / documented gaps** — `getdents` ships the one-Linux-read-per-call
  mapping and **drops** records that don't fit the agnos buffer after the kernel
  advanced its cursor (a tiny buffer / huge dir truncates the listing); the
  carry-buffer fix is deferred. `getdents` ino is truncated u64→u32 (agnos
  `DIRENT_INO` is u32) — lossy on >4 G-inode filesystems.
- **Neutral** — full host-fs reach until the M3 container provides the rootfs.

## Alternatives considered

- **Injected mmap-at-attach scratch page** — commandeer the child once to `mmap`
  a persistent scratch region. More robust for buffers larger than safe stack
  headroom, but adds a register save/restore dance and per-child state M2 doesn't
  need (paths ≤ PATH_MAX fit the red zone). Kept in reserve for post-v1 if a call
  ever needs scratch beyond stack headroom.
- **Write a NUL at `path + namelen` and reuse the child's own pointer** — mutates
  the child's live buffer (the next byte may belong to an adjacent object),
  page-faults when the path ends a mapped page, and provides no place to stage a
  repacked struct or a second path. Rejected as the general mechanism.
- **Supervisor-side fs (open in the supervisor, `process_vm` the data)** — a host
  `open` lands the fd in the *supervisor's* fd table, useless to the child, and
  forces a cross-address-space copy for every read/write. Execute-in-child keeps
  fds and pointers in the child where they belong.
