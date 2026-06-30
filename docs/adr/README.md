# Architecture Decision Records

Decisions about mirshi — what we chose, the context, and the consequences we accept. Use these when a future reader would reasonably ask *"why did we do it this way?"*

## Conventions

- **Filename**: `NNNN-kebab-case-title.md`, zero-padded to four digits. Never renumber.
- **One decision per ADR.** If a decision supersedes a prior one, add a new ADR and set the old one's status to `Superseded by NNNN`.
- **Status lifecycle**: `Proposed` → `Accepted` → (optionally) `Superseded` or `Deprecated`.
- Use [`template.md`](template.md) as the starting point.

## ADR vs. architecture note vs. guide

| Kind | Lives in | Answers |
|---|---|---|
| ADR | `docs/adr/` | *Why did we choose X over Y?* |
| Architecture note | `docs/architecture/` | *What non-obvious constraint is true about the code?* |
| Guide | `docs/guides/` | *How do I do X?* |

## Index

- [0001 — ptrace(PTRACE_SYSEMU) as the M0 syscall-intercept mechanism](0001-ptrace-sysemu-intercept.md) — *Accepted*
- [0002 — Execute-in-child translation via PTRACE_SYSCALL register rewrite](0002-execute-in-child-translation.md) — *Accepted*
- [0003 — Filesystem translation: red-zone path staging + exit-stop repack](0003-fs-redzone-path-staging.md) — *Accepted*
- [0004 — The Docker vehicle (FROM scratch) + child bounding seccomp](0004-docker-vehicle-bounding-seccomp.md) — *Accepted*
