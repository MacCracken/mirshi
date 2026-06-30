# Getting started with mirshi

## Build

```sh
cyrius deps                              # resolve dependencies
cyrius build src/main.cyr build/mirshi    # compile
cyrius test                              # run [build].test + tests/*.tcyr
```

## Run an agnos binary

```sh
build/mirshi ./hello                     # translate + execute an agnos ELF (seccomp on, fs unconfined)
build/mirshi --root ./rootfs ./ls /      # confine the child's filesystem to ./rootfs
build/mirshi --selftest-trace ./hello    # M0 trap-log: print the agnos syscall stream, no translation
```

The full flag set, modes, and exit codes are the **frozen CLI contract**
([`../reference/cli.md`](../reference/cli.md)); which agnos syscalls are mapped / emulated /
ENOSYS is the **syscall-coverage matrix** ([`../reference/syscall-coverage.md`](../reference/syscall-coverage.md)).
To run in a container with fan-out, see [`docker-fanout.md`](docker-fanout.md).

## Layout

- `src/main.cyr` — entry point. Top-level `var r = main(); syscall(SYS_EXIT, r);`.
- `src/test.cyr` — top-level test entry referenced by `cyrius.cyml [build].test`. Add unit cases here or in `tests/mirshi.tcyr`.
- `tests/mirshi.tcyr` — primary test suite (`cyrius test` auto-discovers).
- `tests/mirshi.bcyr` — benchmarks (`cyrius bench`).
- `tests/mirshi.fcyr` — fuzz harness (`cyrius fuzz`).

## Adding a feature

1. Edit `src/main.cyr` (or add a new module and `include` it).
2. Add a test case to `tests/mirshi.tcyr`.
3. Run `cyrius test`.
4. Bump `VERSION` and add a CHANGELOG entry before tagging.

See [`../adr/template.md`](../adr/template.md) when a non-trivial design choice deserves an ADR.
