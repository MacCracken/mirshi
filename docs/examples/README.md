# mirshi — runnable examples

Small **agnos-target** programs you can build and run under mirshi, each exercising one slice of the
translation surface. They are compiled with `cyrius build --agnos` and run by the Linux-target
`mirshi` supervisor — **no QEMU**. (Your editor may flag the `sys_sock_*` / `sys_icmp_echo` calls as
"undefined" — those wrappers exist only under the agnos target and resolve when built with `--agnos`.)

> Build mirshi first, from the repo root:
> `cyrius build src/main.cyr build/mirshi` (see [getting started](../guides/getting-started.md)).
> The full flag set is the [CLI reference](../reference/cli.md); the per-number contract is the
> [syscall-coverage matrix](../reference/syscall-coverage.md).

## 1. hello — process + console

The smallest agnos program: `write#1` + `exit#0`. Source: [`../../docker/tools/hello.cyr`](../../docker/tools/hello.cyr).

```sh
cyrius build --agnos docker/tools/hello.cyr /tmp/hello
build/mirshi /tmp/hello
```
```
hello from agnos userland, under mirshi, in a plain container (no QEMU)
```

## 2. catfile — filesystem, with confinement

Reads a file via `open#7`/`read#5`/`close#6`. Source: [`../../docker/tools/catfile.cyr`](../../docker/tools/catfile.cyr)
(it reads `/data/motd.txt`). Run it inside a kernel-confined rootfs:

```sh
cyrius build --agnos docker/tools/catfile.cyr /tmp/catfile
mkdir -p /tmp/root/data && printf 'hi from a confined rootfs\n' > /tmp/root/data/motd.txt
build/mirshi --root /tmp/root /tmp/catfile        # fs kernel-confined to /tmp/root (ADR 0009)
```
```
hi from a confined rootfs
```

Under `--root`, `/data/motd.txt` resolves to `/tmp/root/data/motd.txt` (`openat2 RESOLVE_IN_ROOT`);
absolute paths, `..`, and symlinks cannot escape. Without `--root` the child reads the host path
directly (a loud stderr warning is printed).

## 3. httpget — the net band, TCP client

An agnos HTTP/1.0 client: `sock_connect#47`/`send#48`/`recv#49` (the **inverted** recv-EOF:
`0`=WOULD_BLOCK, `-1`=EOF) / `close#50`. Source: [`httpget.cyr`](httpget.cyr).

```sh
cyrius build --agnos docs/examples/httpget.cyr /tmp/httpget
python3 -m http.server 8080 >/dev/null 2>&1 &     # a throwaway server on :8080
build/mirshi --net-allow 127.0.0.1/32 /tmp/httpget
kill %1                                            # stop the server
```
```
HTTP/1.0 200 OK
Server: SimpleHTTP/0.6 Python/3.x
...
```

Egress is **default-deny**: point `--net-allow` elsewhere (e.g. `10.0.0.0/8`) and `sock_connect`
returns agnos `-1` (exit `1`) — the SSRF gate ([ADR 0012](../adr/0012-net-band-supervisor-emulated-conn-table.md)).
`--net` with no `--net-allow` enables the band but denies all egress.

## 4. ping — the net band, ICMP

An agnos ping: `icmp_echo#55` over an **unprivileged** ping socket (`SOCK_DGRAM`+`IPPROTO_ICMP`,
never raw), printing the RTT in ms. Source: [`ping.cyr`](ping.cyr).

```sh
cyrius build --agnos docs/examples/ping.cyr /tmp/ping
build/mirshi --net-allow 127.0.0.1/32 /tmp/ping
```
```
rtt_ms=0
```

Loopback is sub-ms, so the RTT reads `0` (≥0 = reachable); a real host prints its round-trip, e.g.
`rtt_ms=6`. Unprivileged ICMP is environment-gated (`net.ipv4.ping_group_range`); where the kernel
forbids it, mirshi fails closed to `-1` and the program prints `unreachable` (exit `1`).

## 5. trap-log — see the raw agnos syscall stream

`--selftest-trace` logs every agnos syscall **without translating** — the M0 interception proof.

```sh
build/mirshi --selftest-trace /tmp/hello
```
```
write#1(1, <ptr>, 72)
exit#0(0)
```

## 6. Docker + fan-out

The same tools run in a `FROM scratch` `agnos-mirshi` container and fan out across N containers —
see the [Docker fan-out guide](../guides/docker-fanout.md).
