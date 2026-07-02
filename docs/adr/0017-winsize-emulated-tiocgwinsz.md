# 0017 — winsize supervisor-emulated from TIOCGWINSZ (the whole direction-1 graphics surface)

**Status**: Accepted (v1.9.0 — winsize#60)
**Date**: 2026-07-01

## Context

`winsize#60` is the **last direction-1 minor** — and, notably, the **entire direction-1 graphics
surface**. The agnos ABI has **no `fbinfo` / `blit` / any other display syscall**: a ring-3 tool's only
window onto the console is this one getter. `winsize#60()` → `(cols<<16)|rows` / −1, **no args, no
buffer** — a pure return like `uptime_ms#40`. On iron the agnos kernel returns `fb_winsize()`, the live
framebuffer character grid (`agnos/kernel/core/syscall.cyr` syscall 60, packed `(cols<<16 | rows)`, −1
only if the FB isn't up). Its real consumer is **darshana**'s `tty_winsize` (→ kii/cyim/chakshu), which
unpacks `rows = packed & 0xFFFF; cols = (packed >> 16) & 0xFFFF` and treats a successful `winsize` as
"is a tty" — so a TUI sizes to the real console instead of a hardcoded 80×24.

A headless mirshi (a `FROM scratch` container, redirected stdio) has **no framebuffer**. But it usually
does have — or is one dup away from — the **controlling terminal** the operator ran it under.

## Decision

**EMULATE `winsize#60` from the controlling terminal's `TIOCGWINSZ`, with an 80×24 virtual default.**
A pure supervisor return (no child buffer), like `uptime_ms#40`: mirshi issues `ioctl(fd, TIOCGWINSZ,
&ws)` on its own stdio (fd 0/1/2 — the child inherits these across the fork, so the supervisor's terminal
*is* the child's), takes the first fd that yields a live `ws_col>0 && ws_row>0`, and packs
`((cols & 0xFFFF) << 16) | (rows & 0xFFFF)` — cols high, rows low, exactly matching the kernel's packing
and darshana's unpack. No fd is a tty (redirected stdio / a plain container) → the **80×24 virtual
default** (the standard VT size, and darshana's own historical fallback).

mirshi **always returns a usable size — never −1**. This is a deliberate, *faithful* choice, not a
short-cut: on iron the agnos framebuffer is always up, so real `winsize` never returns −1 and darshana
always sees a tty. mirshi matching that (a real terminal size, or a sane default) keeps agnos TUIs
behaving under the shim exactly as they do on hardware. `agnos_to_linux_nr(60)` stays −1 (EMULATE,
dispatcher-intercepted); the `ioctl` runs **supervisor-side**, so there is **no child-seccomp delta** and
`--root` is orthogonal (no path, no child fd).

**Direction 1 is now feature-complete.** With `winsize#60` emulated, every *defined, non-kernel-only*
agnos syscall is handled — the only remaining ENOSYS rows are the agnos-**kernel**-only ops
(`mount#11`/`umount#24`/`reboot#13`/`write_boot_checkpoint#26`, permanent by design) and the undefined
ABI gaps (#36–39, #42–44). What remains on the roadmap is the **v2.0.0 direction-2 "swallow"** (Linux
binaries on the agnos kernel), a separate validation surface.

## Consequences

- **Positive** — agnos TUIs (agnsh / darshana-class) size to the real console under mirshi, in a plain
  terminal *and* over the test-fan-out/Docker vehicle (they get 80×24 there, not a crash or a −1). The
  packing is consumer-verified against darshana. This getter closes the direction-1 surface: the
  translation contract is now exhaustive over the agnos userland ABI.
- **Negative / owned** — mirshi **never returns −1** (vs the kernel's −1-if-no-FB): a hypothetical
  consumer using `winsize()==-1` to detect "no display" would instead see 80×24. This is a non-issue for
  the headless-CLI target and matches real-agnos behavior (the FB is always up); revisit only if a
  consumer needs the no-display signal. A `0×0` terminal is treated as "no size" and falls through to the
  default (the `col>0 && row>0` guard).
- **Neutral** — `winsize` carries no arguments (`a1..a4` unused, per the kernel) and no child buffer, so
  there is no pointer-validation / TOCTOU surface; the `ioctl` reads into supervisor memory only. The
  matrix moves row #60 ENOSYS → EMULATE ⁷; the freeze test's `agnos_to_linux_nr(60)` stays −1.

## Alternatives considered

- **Execute-in-child `ioctl(TIOCGWINSZ)`** — rejected: `winsize` is a pure return with no child buffer,
  so there's nothing to stage; running it in the child would just query the child's stdio (the same
  inherited terminal) at the cost of a renumber + arg synth + a new child-seccomp `ioctl` entry — strictly
  worse than the supervisor-side read.
- **Return −1 when there's no tty** (mirror the kernel's −1-if-no-FB literally) — rejected: real agnos
  always has an FB, so −1 is the *rare* kernel path, not the norm; darshana treats a size as "is a tty"
  and needs one. The 80×24 default is the faithful, useful stand-in for a headless console.
- **Read a real framebuffer** — N/A: there is no FB in a headless Linux container, and no `fbinfo`/`blit`
  in the agnos ABI to emulate one. The terminal size is the only meaningful "console geometry" mirshi has.
