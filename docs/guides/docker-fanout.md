# Running agnos userland in Docker + multi-container fan-out

The **agnos-mirshi** image runs agnos-compiled binaries as native Linux
processes under mirshi's syscall translation — in a plain container, **no QEMU**,
sharing the host kernel (direction 1). This is the v1 vehicle: cheap,
cloud-deployable containers and a test-fleet you can fan out across heterogeneous
Linux hosts.

> Discipline ([[feedback_qemu_test_agnos_userland]]): this validates **userland
> concurrency + Linux-app compat at scale**, NOT the agnos kernel's SMP/net
> stack. It complements QEMU+KVM (real kernel) + iron (hardware truth); it does
> not replace them.

## Build the image

```sh
docker/build.sh                 # builds mirshi + the agnos tools, FROM scratch -> agnos-mirshi
```

The image is `FROM scratch`: only `/mirshi` (the supervisor), the agnos-target
ELFs under `/bin`, and a tiny `/data` rootfs. All static, no libc, no shell — and
structurally no QEMU.

## Run an agnos tool

```sh
docker run --rm agnos-mirshi /bin/hello          # write + exit
docker run --rm agnos-mirshi /bin/catfile        # reads /data/motd.txt (translated open/read)
docker run --rm agnos-mirshi /bin/ls             # getdents of /
echo hi | docker run -i --rm agnos-mirshi /bin/echo   # stdin -> stdout
```

`ENTRYPOINT` is `/mirshi`, so the argument is the agnos tool to supervise.

### ptrace in a container

mirshi traps the child's syscalls with `ptrace`. Stock Docker's default seccomp
profile blocks `ptrace`, so on most hosts you need:

```sh
docker run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  agnos-mirshi /bin/hello
```

Loosening the container's seccomp is why mirshi applies its **own** bounding
seccomp filter to the child (the agnos-syscall-output allowlist — default-on; see
[ADR 0004](../adr/0004-docker-vehicle-bounding-seccomp.md)). Disable it with
`mirshi --no-seccomp <elf>` if needed.

## Multi-container fan-out

The near-term win: boot N containers concurrently, each running an agnos workload
under mirshi, and collect the results. Because there's no QEMU, each container is
a plain native process tree — cheap to start and dense to pack.

```sh
docker/fanout.sh 12 /bin/hello        # 12 concurrent containers
docker/fanout.sh 6 /bin/catfile       # fan out a different workload
```

`fanout.sh` runs N `docker run`s in parallel, waits, and reports `OK/total` +
wall time. Across multiple Linux hosts (a CI matrix, a cluster), the same image
gives you a heterogeneous agnos-userland test fleet with no emulation overhead.

## CI

`docker/smoke.sh` is the CI gate: it builds the image, runs the representative agnos
userland (`hello`/`echo`/`catfile`/`ls`/`cp` — console, stdin, fs read/list/write),
asserts correct output, **proves there is no qemu binary in the image**, and runs a
small fan-out. It needs Docker + the ptrace recipe above.

## Publishing the image (post-v1 ops)

The image is **reproducibly buildable** from this repo (`docker/build.sh` → a
`FROM scratch` `agnos-mirshi`), which is what the v1 definition requires. Pushing it to
a registry is an **operator step**, decoupled from the v1 cut (it needs registry
credentials + a chosen name/tag — outward, environment-specific):

```sh
docker/build.sh ghcr.io/<you>/agnos-mirshi:1.0.0   # build + tag
docker push        ghcr.io/<you>/agnos-mirshi:1.0.0   # operator runs this
```

Consumers then `docker run --cap-add=SYS_PTRACE --security-opt seccomp=unconfined
ghcr.io/<you>/agnos-mirshi:1.0.0 /bin/hello` (the ptrace recipe above), or fan it out
across a CI matrix / cluster for a heterogeneous agnos-userland test fleet.
