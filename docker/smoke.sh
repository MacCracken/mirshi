#!/usr/bin/env bash
# docker/smoke.sh — CI smoke test for the agnos-mirshi image (the v1 vehicle).
# Builds the image and runs the representative agnos CLI userland in plain
# containers, asserting the v1 acceptance end-to-end: console out (hello),
# stdin echo, fs read (catfile), dir listing (ls), the fs WRITE path (cp:
# create+write+read-back), NO QEMU in the image, and a multi-container fan-out.
# Needs Docker + the ptrace recipe (--cap-add=SYS_PTRACE
# --security-opt seccomp=unconfined).
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

echo "==> agnos stdin echo (read#5 stdin + write#1)"
printf 'echo-roundtrip\n' | docker run -i --rm "${caps[@]}" "$img" /bin/echo | grep -q "echo-roundtrip" \
    || { echo "FAIL: /bin/echo did not round-trip stdin" >&2; exit 1; }
echo "OK: agnos /bin/echo round-trips stdin"

echo "==> agnos dir listing (getdents#29 + dirent repack)"
lsout="$(docker run --rm "${caps[@]}" "$img" /bin/ls)"
printf '%s\n' "$lsout" | grep -qx "bin" && printf '%s\n' "$lsout" | grep -qx "data" \
    || { echo "FAIL: /bin/ls did not list bin + data: $lsout" >&2; exit 1; }
echo "OK: agnos /bin/ls lists the container root"

echo "==> agnos fs WRITE path (open AO_CREAT|AO_WRONLY + write, then read back)"
docker run --rm "${caps[@]}" "$img" /bin/cp | grep -q "native Linux process" \
    || { echo "FAIL: /bin/cp write+readback did not return the copied content" >&2; exit 1; }
echo "OK: agnos /bin/cp writes a file and reads it back (fs write path)"

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

echo "OK: docker smoke test — the representative agnos CLI userland runs in a plain container, no QEMU"
