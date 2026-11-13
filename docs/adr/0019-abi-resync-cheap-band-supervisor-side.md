# 0019 — The 1.13.0 re-sync band: supervisor-side listings, an opaque readdir cursor, synthesized tables

**Status**: Accepted (v1.13.0 — #36 #44 #81 #99–#104 #106–#108 #115)
**Date**: 2026-11-12

## Context

The agnos kernel at 1.57.19 (`aef48206`) answers numbers up to #115, and the cyrius 6.7.18 agnos stdlib
issues most of them (`lib/syscalls_x86_64_agnos.cyr`). Up to 1.12.3 mirshi had no arm for thirteen of the
cheap ones, so each fell to the ENOSYS path: -1 and a `mirshi: ENOSYS agnos#N` line. A stdlib directory
walk (`sys_readdir_at`), a process monitor (`sys_proclist`), `lstat`-based `rm`, a volumes sidebar
(`statfs` / `mountlist`) and `yo -W` (`icmp_echo_ex`) all degraded under mirshi.

Every one of the thirteen numbers is a different Linux call (36 `getitimer`, 44 `sendto`, 81 `fchdir`,
99 `sysinfo`, 100 `times`, 101 `ptrace`, 102 `getuid`, 103 `syslog`, 104 `getgid`, 106 `setgid`,
107 `geteuid`, 108 `getegid`, 115 `getgroups`), so none can pass through.

Three of them have no Linux shape at all: `readdir#81` / `readdir_at#101` fill fixed 64-byte
`{name, flags}` records from a path (Linux lists from an fd, in variable records), and the kernel's
`readdir_at` cursor is ext2's byte offset into the directory file. `proclist#99`, `mountlist#104` and
`klug#36` describe the agnos kernel's own tables, which do not exist under mirshi.

## Decision

**The listings run in the supervisor.** `readdir#81` / `readdir_at#101` read the 256-byte path window
from the child, open the directory in the supervisor (`openat2(O_DIRECTORY, RESOLVE_IN_ROOT |
RESOLVE_NO_MAGICLINKS)` on the supervisor's root anchor under `--root`, the resolution `open#7` uses;
`openat(AT_FDCWD)` otherwise), walk it with `getdents64`, and write the kernel's records into the
caller's buffer. `statfs#103` is supervisor-side too (Linux `statfs`, or `fstatfs` on the path opened
inside the root). None of them adds a child syscall.

**`readdir_at#101`'s cursor is the host's `d_off` cookie.** The kernel's contract is the protocol, not
the number: 0 starts, -1 is exhausted, anything else is what the last call stored. A budget spent before
a record parks the cursor on that record (the previous record's `d_off`), and a cookie > 0 is `lseek`ed
to. The kernel's ext2-specific answers — -5 for a misaligned offset, snapping to a record boundary — do
not apply to an opaque cookie, so mirshi never answers -5, and a cookie the directory refuses to seek to
reads as one past the end (0, cursor -1).

**The agnos tables are synthesized from mirshi's own state, never from the host's.** `proclist#99` lists
the supervisor's record table: one record per process mirshi traces, with the state mapped
(2 the caller, 1 another live one, 6 parked in `waitpid#4` / `execwait#37`, 7 exited and unreaped), the
parent's agnos pid, and a 32-byte name the record now carries (`C_NAME`: the basename of the target, or
of `#37` / `#43`'s path; `spawn#3` has none). `+56` is 0, the kernel's "neither field present".
`mountlist#104` reports one ext2 root, `"/"`. `klug#36` answers 0 bytes. The host's process table, mount
table and kernel log are never read.

**The rest are direct:** `sched_yield#44` answers 0 and `sched_yield_to#108` the kernel's `yt_auth_ok`
(self, a live direct child, the live direct parent); `spawn_limits#107` answers -1, the kernel's "not
supported", until the caps are enforced; `lstat#102` is `stat#33` with Linux `lstat` (6), or with
`O_NOFOLLOW` under `--root`; `fsync#115` refuses fd outside [0, 32) and otherwise runs Linux `fsync` (74)
in the child; `icmp_echo_ex#100` is `icmp_echo#55` with the caller's clamped timeout; `sock_peer#106` is
`getpeername` on one of the caller's own `SLOT_CONN`s.

## Consequences

- **Positive** — the stdlib paths behind these numbers run under mirshi as on the kernel, with no ENOSYS
  line. The child-seccomp delta is two numbers (`lstat` 6, `fsync` 74). Confined listings and `statfs`
  resolve exactly as a confined `open#7` does, so `..`, absolute symlinks and escape links stay inside the
  root. The listings are bounded: one 4 KiB `getdents64` batch buffer, allocated once.
- **Negative** — the kernel validates the caller's whole `max × 64`-byte buffer before it writes; mirshi
  writes the records it produces and answers -1 at the first it cannot write, after any earlier ones
  landed. A caller that stores a `readdir_at` cursor as an ext2 offset (rather than handing it back) sees
  a different number. `proclist` shows no kernel threads and no cpu/rss figures. `spawn_limits` refuses
  until 1.13.2. Relative readdir / statfs paths resolve from mirshi's working directory until `chdir#112`
  lands (1.13.1).
- **Neutral** — the per-record name is a new 32-byte field in every child record (`CHILD_REC_SIZE` 216).

## Alternatives considered

- **EXECUTE `getdents64` in the child and repack at the exit stop** (as `getdents#29` does). Rejected: the
  call takes a path, so it would need an open, a walk that may span several `getdents64` calls, and a
  close in the child — three syscall rewrites per listing, a red-zone buffer, and an fd the child would
  briefly hold. The supervisor already opens confined paths for the 1.12.3 `_cf_*` ops.
- **Emulate ext2 byte offsets for the cursor** (count bytes of synthetic ext2 records). Rejected: it means
  re-walking from the top to find a position, the O(n²) the kernel's cursor exists to avoid, and an
  offset that drifts whenever the directory changes between calls. The cookie is what the host offers.
- **Read the host's `/proc`, `/proc/self/mountinfo` or `dmesg`.** Rejected: that discloses the host to a
  sandboxed guest, and none of it is the agnos guest's world.
- **Accept `spawn_limits#107` (0) without enforcing it.** Rejected: a caller that arms a cap believes its
  child is bounded. -1 is the kernel's own answer for "this kernel cannot".
