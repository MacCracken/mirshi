# 0012 — Net band: supervisor-emulated conn_id table + recv-EOF inversion + default-deny egress

**Status**: Accepted (TCP client v1.1.0; TCP server v1.2.0; UDP + net_config v1.3.0; ICMP pending v1.4.0)
**Date**: 2026-06-30

## Context

The sovereign **net band** (`sock_connect#47`/`send#48`/`recv#49`/`close#50`, `udp_bind#51`/
`send#52`/`recv#53`/`unbind#54`, `icmp_echo#55`, `sock_listen#56`/`accept#57`, `net_config#61`)
is mirshi's **first post-v1 expansion** ([roadmap](../development/roadmap.md)). It is
structurally unlike the M1/M2 surface — a design decision is forced:

- **Opaque handles, not fds.** agnos returns small `conn_id`/`listener_id` values (0..7 — an
  8-slot kernel table), never a Linux fd. `sock_send#48` takes a `conn_id`, so there is no
  1:1 register-renumber to a Linux syscall that operates on an fd.
- **Fused, multi-syscall operations.** `sock_connect#47` does `socket()` **and** `connect()`
  in one call (and blocks ~8s); `sock_listen#56` does `bind()`+`listen()`. mirshi's trap loop
  runs exactly **one** kernel syscall per trap (the enter/exit `at_entry` toggle + every
  one-slot carry global assume it), so a single trap cannot drive `socket→connect`.
- **Inverted recv EOF.** `sock_recv#49` returns `>0` bytes / **`0`=WOULD_BLOCK** / **`-1`=EOF**
  — the *opposite* of Linux `read` (`0`=EOF, `-EAGAIN`=would-block). Reusing the generic
  return mapper would report a closed connection as "try again forever" (a silent spin bug).
- **A new trust boundary.** A sandboxed agnos child reaching the network is a fresh
  **egress/exfiltration surface** — the network analogue of the class-(c) path-escape the
  0.7.1 confinement closed for the filesystem ([ADR 0009](0009-rootfs-confinement-openat2-in-child.md)).
  mirshi holds host privilege; it is a sandbox-class deputy.

Two translation models were on the table: **execute-in-child** (sockets are child fds,
`send`/`recv` renumber to `sendto`/`recvfrom`, buffers stay in child memory) vs
**supervisor-emulate** (the supervisor owns the sockets; buffers are staged via
`process_vm`, the M2 `stat`/`getdents` pattern).

## Decision

**Translate the net band by SUPERVISOR-EMULATE (`STRAT_EMULATE`): the supervisor owns the
sockets via a per-child 8-slot `conn_id/listener_id(0..7) → host fd` table; buffers are staged
with `process_vm`; the child only ever sees opaque handles, never a real socket fd. Egress is
a shipping gate — `--net` opt-in + `--net-allow` default-deny — not a follow-up. Ship
client-first.**

- **Why emulate, not execute-in-child.** Execute-in-child would need a **multi-syscall
  injection sub-state in the core `_trace_run` loop** to split `socket()`+`connect()` — the
  rip-rewind pattern [ADR 0002](0002-execute-in-child-translation.md) empirically rejected as
  hang-prone — and would put **raw socket fds in the child's fd table** and **grow the seccomp
  allowlist**. Emulate sidesteps all three: `sock_connect` is just `socket()`+`connect()` run
  **in the supervisor** (two ordinary calls, no loop change); the fd + the egress-policy choke
  point stay supervisor-side; the child bounding allowlist ([ADR 0004](0004-docker-vehicle-bounding-seccomp.md))
  **does not change** (socket syscalls run in the supervisor, which hardcodes
  `AF_INET`/`SOCK_STREAM`|`SOCK_DGRAM`/proto 0 — nothing child-controlled to clamp). The one
  cost — a `process_vm` copy per `send`/`recv` — is **secondary to the ptrace-stop cost**
  (0.8.0 cost model) and is exactly the proven M2 staging path; the execute-in-child
  efficiency win does not justify the loop-change hazard or the weaker fd posture.
- **The conn_id table** — a supervisor-side 8-slot array (lazy-alloc-once, same discipline as
  `_how_buf`/`_emu_ts`), `host fd` per slot, `-1`=free. Allocate the lowest free slot on
  `connect`/`accept`/`bind` success; free on `close#50`/`unbind#54` and on child exit. Host
  sockets are `SOCK_CLOEXEC`. Table-full → agnos `-1`.
- **`sock_recv#49` inverted EOF** — a **dedicated** `net_ret_to_agnos` mapper (NOT
  `linux_ret_to_agnos`): `n>0 → n`, Linux `0`(EOF) `→ -1`, `-EAGAIN` `→ 0`(WOULD_BLOCK), other
  `-errno → -1`. The host socket is non-blocking so `EAGAIN` exists to map. **Pure +
  unit-pinned** — this is the subtlest correctness point in the band.
- **`dst_ip` staging** — the packed u32 → `struct sockaddr_in` (16 B) with correct **network
  byte order** (`htons`/`htonl`), a pure helper unit-pinned against a loopback fixture
  (`0x0100007F` vs `0x7F000001`).
- **Blocking** — `connect#47` (~8s) is a **bounded** non-blocking-connect + `ppoll` in the
  supervisor (an unbounded blocking `connect` the *supervisor* issues could wedge it — this is
  distinct from [ADR 0008](0008-child-hang-supervisor-robustness.md)'s *child*-hang stance);
  `recv#49`/`accept#57` are non-blocking; `icmp_echo#55` (~3s) is bounded likewise.
- **Egress — default-deny, a shipping gate.** `--net` opts the band on at all; `--net-allow
  <CIDR>[:ports]` is **required** to reach any destination (stricter than `--root`, which only
  warns — egress on a sandbox boundary warrants deliberate per-destination opt-in). Enforced
  in the supervisor on the already-decoded `dst_ip` **before** the socket, **fail-closed** to
  agnos `-1`. Metadata (`169.254.169.254`)/RFC1918/loopback are blocked unless explicitly
  allowed (SSRF + lateral-movement). This is mirshi's **inner** bound; it composes with, never
  leans on, the container netns (which protects only the container, not the bare CLI).
- **ICMP** — unprivileged `SOCK_DGRAM`+`IPPROTO_ICMP` only (never `SOCK_RAW`/`CAP_NET_RAW` — a
  privilege mirshi must not hold or grant); fail-closed to `-1` if `net.ipv4.ping_group_range`
  doesn't permit. Shipped **last** (environment-sensitive).
- **`net_config#61`** — an EMULATE getter that reads the **real (container-netns) interface**
  config (host IP / netmask / gateway / DNS) supervisor-side, returns packed IPv4 / `0` unset.
- **Scope order** — client first: v1.1.0 = TCP client + the egress gate; v1.2.0 = TCP server
  (`listen`/`accept` — a distinct ingress threat model + a 2nd slot namespace); v1.3.0 = UDP +
  `net_config` (its DNS consumer); v1.4.0 = ICMP.

## Consequences

- **Positive** — no change to the delicate enter/exit loop (avoids the rip-rewind hazard); the
  socket fd + egress choke point stay supervisor-side; the child never holds a socket fd; the
  seccomp allowlist is unchanged; reuses the proven M2 `process_vm` staging. Egress is confined
  **by default**, closing the network analogue of the 0.7.1 class-(c) escape for the bare CLI.
- **Negative / owned** — a `process_vm` copy per `send`/`recv` (accepted: secondary to the
  ptrace-stop cost, M2-proven). The supervisor now holds **persistent cross-trap per-child
  state** (the 8-slot tables), unlike M1/M2's one-in-flight-call globals — single-child-v1 only;
  multi-child must make them per-child. `net_config` reading the real interface is a **minor
  infoleak** (the child sees the container/host gateway + DNS) + adds interface enumeration to
  the surface — accepted (under the Docker vehicle it is the container's own netns view).
- **Neutral** — the inverted-recv-EOF mapper + the `dst_ip`→`sockaddr_in` byte-order helper are
  pure + unit-pinned. A future execute-in-child variant (for efficiency) stays possible but is
  explicitly deferred (unjustified by the cost model; would need the loop change + weaken the
  fd posture). The **discipline** ([ADR 0011](0011-mirshi-qemu-iron-boundary-discipline.md))
  holds and must stay loud: mirshi validates net-**app** compat (http/ws/dns tools) on the
  **host** kernel's net stack — it does **not** validate the agnos **sovereign** net stack
  (congestion/retransmit/its own SYN handling), which never runs here and stays QEMU's job.

## Alternatives considered

- **Execute-in-child (renumber `send`/`recv` on a child socket fd)** — the efficiency-optimal
  path (buffers never copy). Rejected for net-v1: it needs the multi-syscall injection loop
  change (ADR 0002's rejected rip-rewind), puts raw socket fds in the child, and grows the
  seccomp allowlist; the copy it saves is secondary to the ptrace-stop cost (0.8.0). Left open
  as a future optimization if a real net workload proves buffer-copy-bound.
- **Rely on the container netns for egress (no `--net-allow`)** — rejected: leaves the bare CLI
  with unbounded egress (the 0.7.1 fs gap, over the network) and no SSRF/metadata protection.
- **Warn-only egress (mirror `--root`)** — considered; rejected for **default-deny** since
  egress warrants a stricter, per-destination opt-in than filesystem read.
- **Raw-socket ICMP (`CAP_NET_RAW`)** — rejected: a privilege a sandbox-class deputy must not
  hold or grant; the unprivileged datagram-ICMP path suffices.
- **`net_config` from CLI flags / `0`-unset** — considered (no infoleak, no enumeration);
  the real-interface read was chosen (accepting the minor infoleak) for fidelity.
