# 0002 — Execute-in-child translation via PTRACE_SYSCALL register rewrite

**Status**: Accepted
**Date**: 2026-06-29

## Context

M0 ([0001](0001-ptrace-sysemu-intercept.md)) proved interception: mirshi traps
every agnos syscall via `PTRACE_SYSEMU` and logs it, executing nothing. M1 must
*run* the binary — translate each agnos syscall to its Linux peer, **perform**
it, and return the result so an agnos `hello` and a stdin `cat` work.

Two facts force the mechanism:

1. **mmap must allocate in the child.** agnos `alloc_init()` issues `mmap#27` for
   a 2 MB heap. Under `PTRACE_SYSEMU` that mmap is suppressed, the heap base is
   garbage, and the child segfaults (observed: `heapuser` → SIGSEGV). A
   supervisor that emulates mmap in *its own* address space cannot hand the child
   a usable base. The mapping has to be installed in the **child's** address
   space.
2. **Buffer pointers are child pointers.** `write#1`/`read#5` carry pointers into
   the child's memory. A host syscall in the supervisor can't dereference them
   without a cross-address-space copy.

Both vanish if the translated syscall runs *as the child*: the kernel
dereferences the child's pointers natively and a new mmap lands in the child.

The remaining question is how to execute a *rewritten* syscall in the child from
a ptrace stop. The naive "rewind `rip` and resume the `PTRACE_SYSEMU` stop with
`PTRACE_SYSCALL`" re-executes the `syscall` instruction and produces an extra
syscall-*entry* stop — desyncing the loop (observed: a hang). The robust,
documented path is the `PTRACE_SYSCALL` enter/exit model with `orig_rax` rewrite.

## Decision

**Run mode uses `PTRACE_SYSCALL` (enter+exit stops). At the syscall-enter stop a
hybrid dispatcher (`src/dispatch.cyr`) rewrites the trapped registers:**

- **Execute-in-child** (`write`, `read`, `getpid`, `mmap`, `munmap`, `sync`,
  `getrandom`, `time_unix`): set `orig_rax` to the Linux peer number (+ synthesize
  args — e.g. agnos's 1-arg `mmap(length)` → Linux's 6-arg `mmap`, length rounded
  up to 2 MB). The kernel runs it in the child; at the exit stop the raw Linux
  return is mapped to the agnos convention (`-errno` → `-1`, except `mmap`/`time`
  failures → `0`).
- **Supervisor-emulate** (`uptime_ms`, `sleep_ms`): the agnos no-buffer
  single-register ABI has no clean single-call Linux peer (`clock_gettime`/
  `nanosleep` take a timespec struct). Skip the kernel syscall by setting
  `orig_rax = -1`, compute the result in the supervisor (the monotonic clock is
  shared; the lone stopped child can be slept-for in-supervisor), and inject it
  into `rax` at the exit stop.
- **Terminate**: agnos `exit#0` is rewritten to a real Linux `exit_group(code)`,
  so the child terminates and its status propagates through `waitpid` — no
  `SIGKILL`.
- **ENOSYS**: an out-of-M1-surface number is skipped (`orig_rax = -1`) and
  returns the agnos error sentinel `-1`, with a diagnostic — never run as a wrong
  Linux call.

The pure translation arithmetic (number remap, return mapping, mmap synthesis)
is factored into `src/translate.cyr` and unit-tested; `dispatch.cyr` is the
ptrace/clock glue. M0's `--selftest-trace` keeps the `PTRACE_SYSEMU` log loop
unchanged.

## Consequences

- **Positive** — child pointers and a new mmap land natively; the supervisor
  never copies child memory for the M1 set. mmap is correct (heap works); exit
  codes propagate through the real `exit_group`. The technique is the Linux
  kernel's own x86 ptrace selftest pattern.
- **Negative** — two stops per syscall (enter + exit), ~2× the per-call ptrace
  overhead vs the eventual seccomp-notify path (M4 addresses this). The run loop
  must track the enter/exit phase (an `at_entry` toggle) and carry the agnos
  number + the emulated return across the enter→exit pair.
- **Negative / owned** — emulated returns ride a one-slot supervisor global
  (`_xlat_emu_ret`), safe only because there is exactly one in-flight call per
  child under strict enter/exit alternation. Multi-child/threaded translation
  (post-v1) must replace it with per-call state.
- **Neutral** — supervisor-side `sleep_ms` blocks the supervisor for the sleep
  duration. Fine for the single-child M1; the child-side `nanosleep` variant
  (needs a writable child scratch buffer) is deferred to multi-child work.

## Alternatives considered

- **`PTRACE_SYSEMU` + `rip`-rewind + `PTRACE_SYSCALL` to execute** — rewinding
  `rip` re-executes the `syscall` instruction, yielding an extra entry stop the
  loop must consume; getting that accounting wrong hangs the supervisor (it did).
  More fragile than the plain enter/exit model for no benefit.
- **Pure supervisor-emulate everything (`process_vm_readv`/`writev` + host
  syscalls)** — forces a cross-address-space copy for every buffer-bearing call
  and a hand-rolled mmap-into-child, far more code and a TOCTOU surface (roadmap
  0.7.0), for no gain on the shared-host-kernel model. Reserved for calls with no
  Linux peer (none in the M1 set beyond the two timers, which need no buffer).
- **Keep M0's single-resume `PTRACE_SYSEMU` for run mode** — SYSEMU's whole point
  is *not* executing; you can't cleanly "un-suppress" a call without the rip games
  above. Two purpose-built loops (`_trace_log` SYSEMU, `_trace_run` SYSCALL) are
  clearer than one overloaded loop straddling both cadences.
