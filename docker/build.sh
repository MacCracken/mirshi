#!/usr/bin/env bash
# docker/build.sh — build the agnos-mirshi image (the M3 v1 vehicle).
#
# Compiles mirshi (Linux-target supervisor) + the demo tools (agnos-target ELFs),
# assembles a FROM-scratch staging context, and `docker build`s the image. The
# result carries NO QEMU — agnos userland runs natively under mirshi's syscall
# translation, sharing the host kernel.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
img="${1:-agnos-mirshi}"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/bin" "$stage/data"

echo "==> building mirshi (Linux-target supervisor)"
cyrius build src/main.cyr "$stage/mirshi" >/dev/null

echo "==> building agnos userland tools (agnos-target ELFs)"
for t in hello catfile ls echo cp; do
    cyrius build --agnos "docker/tools/$t.cyr" "$stage/bin/$t" >/dev/null
done

cp docker/rootfs/data/motd.txt "$stage/data/"
cp docker/Dockerfile "$stage/Dockerfile"

echo "==> docker build -t $img (FROM scratch)"
docker build -t "$img" "$stage" >/dev/null
echo "==> built image: $img"
docker image inspect "$img" --format '    size: {{.Size}} bytes, layers: {{len .RootFS.Layers}}' 2>/dev/null || true
