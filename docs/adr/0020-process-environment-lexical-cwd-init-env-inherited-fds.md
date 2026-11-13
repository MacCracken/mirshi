# 0020 — The process environment: a lexical cwd per process, the kernel's init env, inherited fd tables, an exec-status pipe

**Status**: Accepted (v1.13.1 — chdir#112 / getcwd#113, the init env, #3 / #37 / #43 / #62)
**Date**: 2026-11-12

## Context

agnos 1.57.18 gave every process a working directory (`chdir#112` / `getcwd#113`) and routed every path
argument through one ingress, `sc_path_take`: an absolute path is used verbatim, a relative one is joined
to the caller's cwd and cleaned **lexically** (`path_clean_join` — `..` drops the previous component and
never climbs above `/`). The from-disk loader stages a default init env, `HOME=/` and `PWD=<the creator's
cwd>`, which a `#37` / `#43` env blob (a3 = pointer, a4 = length) replaces; a valid `PWD=` in that blob
also seeds the child's cwd. Every child is born with a copy of its creator's fd table, then (#37 / #43) the
creator's armed `exec_redirect#62` pairs, a per-process set of up to four, consumed by every #37 / #43
return; `SPAWN_F_CLEANFD` scrubs fds 3..31 except the redirect sources. A failed exec is reported to the
caller: `-4` (no such file) / `-5` (not a loadable ELF) from #43, -1 from #37 and #3.

Up to 1.13.0 mirshi had none of it: `#112` / `#113` fell to ENOSYS, the child's envp was `[NULL]` (so
`getenv("HOME")` was null and hapi's `$HOME`-scoped verbs could not run), relative paths resolved from
mirshi's own working directory (or the root, under `--root`), spawned children started with fds 0–2
only, the redirect arm was one global pair, and a failed exec answered a pid whose `waitpid` was -1.

## Decision

**The cwd is a per-process string, joined lexically at mirshi's own ingress points.** Each child record
carries a cwd length (`C_CWD_LEN`, 0 = `/`) and a 4 KiB string in a table allocated once. Every place
mirshi takes a path from the child joins a relative one to the caller's cwd with a port of the kernel's
`path_clean_join` (`src/translate.cyr`): the red-zone staging of the executed path calls (`stage_path`),
the supervisor-side reads (`_m2_read_path`, readdir's window), and the program path of #37 / #43.
`symlink#63`'s target is text and is never rewritten. The child's own Linux cwd is never consulted, so
the unconfined and `--root` paths behave alike, and `..` is lexical as on the kernel. `chdir#112` stores
the cleaned path after checking it names a directory (inside the root under `--root`).

**The root child starts in mirshi's working directory**, or at `/` under `--root`. Unconfined, the guest's
paths are the host's, so a relative argument (`mirshi ./kii image.png`) keeps meaning what it meant.

**The init env is the kernel loader's:** `HOME=/` and `PWD=<cwd>` for the root child and for a #37 / #43
child without a usable blob; the blob itself (validated as `sc_env_blob_ok` validates it) otherwise. A
bad blob falls back to the default, except in #43's flagged forms, where it is -6. spawn#3 gets no env,
as the kernel's in-memory loader stages none. mirshi never passes its own (the host's) environment.

**Children inherit their creator's fd table.** Before the fork the supervisor duplicates the caller's fds
0..31 with `pidfd_getfd`; the grandchild places them at the same numbers, applies the redirect pairs in
arm order (`child[src] = child[dst]`), and for CLEANFD closes 3..31 except the sources. This holds for
spawn#3 too, as on the kernel. The grandchild's own fds (the status pipe, spawn#3's memfd) move above
ROOTFD first, and everything at 32 and above is closed before exec.

**A status pipe reports the exec.** A `pipe2(O_CLOEXEC)` per spawn: an exec that works closes the
grandchild's end (EOF), one that fails writes its `-errno` (or a setup-failure word) before exiting. The
supervisor waits at most 5 s, reaps a failed grandchild itself, and answers the kernel's code.

## Consequences

- **Positive** — `getenv("HOME")` / `getenv("PWD")`, `chdir` / `getcwd`, relative paths, `agnsh`-style
  `cd` + `run`, `2>&1`-style redirect sets, inherited pipes and the stdlib's spawn-failure codes all behave
  as on the kernel. No child-seccomp delta: the cwd is supervisor state.
- **Negative** — every spawn costs up to 32 `pidfd_getfd` calls and a pipe. mirshi's emulated signalfd /
  timerfd / epoll ids are per-process tables, not fds, so a child does not inherit them (on the kernel it
  would). Linux's own exec rules still apply underneath: a file without execute permission is -4 under
  mirshi where the kernel would load it. HOME is `/` even unconfined, where `/` is the host's root.
- **Neutral** — the record grows by 80 bytes (`CHILD_REC_SIZE` 296); a 64 KiB cwd table is allocated on
  first use.

## Alternatives considered

- **A real `chdir` in the child.** Rejected: Linux resolves `..` physically, the supervisor-side calls
  would still need the cwd, and under `--root` the confined `open#7` resolves from ROOTFD, not the cwd.
- **Pass the host environment to the root child.** Rejected: it leaks the host into a sandboxed guest and
  is not what the kernel stages; an operator who needs a variable can ask for a flag.
- **Keep fds 0–2 only for children** (the 1.12.3 rule). Rejected: it breaks pipelines and any parent that
  hands a child an open file, the reason the kernel copies the table.
- **Learn exec failures from the trace loop** (the first stop never arriving). Rejected: the caller's
  `#43` has already returned a pid by then; the pipe answers before the call returns.
