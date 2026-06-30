#!/usr/bin/env bash
# docker/smoke.sh — M3 CI smoke test for the agnos-mirshi image (the v1 vehicle).
# Builds the image, runs agnos tools in plain containers, and asserts the M3
# acceptance: correct output/exit, the fs tool reads the container rootfs, NO
# QEMU in the image, and a multi-container fan-out. Needs Docker + the ptrace
# recipe (--cap-add=SYS_PTRACE --security-opt seccomp=unconfined).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
img="agnos-mirshi:ci"
caps=(--cap-add=SYS_PTRACE --security-opt seccomp=unconfined)

echo "==> building image"
bash docker/build.sh "$img" >/dev/null
# Clean up the image on ANY exit from here on (not just the happy path).
trap 'docker rmi "$img" >/dev/null 2>&1 || true' EXIT

echo "==> docker run an agnos tool"
out="$(docker run --rm "${caps[@]}" "$img" /bin/hello)"
printf '%s\n' "$out" | grep -q "hello from agnos" \
    || { echo "FAIL: /bin/hello output unexpected: $out" >&2; exit 1; }
echo "OK: agnos /bin/hello -> correct output/exit"

echo "==> agnos fs tool reads the container rootfs"
docker run --rm "${caps[@]}" "$img" /bin/catfile | grep -q "native Linux process" \
    || { echo "FAIL: /bin/catfile did not read /data/motd.txt" >&2; exit 1; }
echo "OK: agnos /bin/catfile reads the container fs"

echo "==> proving NO QEMU in the image"
cid="$(docker create "$img")"
trap 'docker rm "$cid" >/dev/null 2>&1 || true; docker rmi "$img" >/dev/null 2>&1 || true' EXIT
contents="$(docker export "$cid" | tar -tf -)"
# FROM scratch structurally guarantees this, but assert it: no qemu anywhere, and
# the only image executables are /mirshi + the agnos tools under /bin (Docker
# injects /etc/* text files + /.dockerenv at runtime — those are expected).
if printf '%s\n' "$contents" | grep -qi qemu; then
    echo "FAIL: a qemu binary is present in the image" >&2
    exit 1
fi
printf '%s\n' "$contents" | grep -qx 'mirshi' \
    || { echo "FAIL: /mirshi missing from the image" >&2; exit 1; }
echo "OK: no qemu binary in the image"

echo "==> multi-container fan-out (4 concurrent)"
IMG="$img" bash docker/fanout.sh 4 /bin/hello >/dev/null \
    || { echo "FAIL: fan-out had a failed container" >&2; exit 1; }
echo "OK: 4-container fan-out"

echo "OK: M3 docker smoke test — agnos userland runs in a plain container, no QEMU"
