# Dockerfile — the agnos-mirshi image (the M3 v1 vehicle).
#
# FROM scratch: the image contains ONLY mirshi + agnos-target ELFs + a tiny
# rootfs. mirshi (Linux-target) and the agnos tools (agnos-target) are all
# statically linked with no libc, so there is no base OS, no shell, and — the
# load-bearing property — NO QEMU. agnos userland runs as native Linux processes
# under mirshi's syscall translation, sharing the host kernel (direction 1).
#
# Built from a staging context assembled by docker/build.sh (which compiles
# mirshi Linux-target + the tools agnos-target). Run an agnos tool with:
#   docker run --rm agnos-mirshi /bin/hello
# On a stock Docker whose default seccomp profile blocks ptrace, add:
#   docker run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
#     agnos-mirshi /bin/hello
FROM scratch

# The Linux-target supervisor (entrypoint).
COPY mirshi /mirshi
# The agnos-target userland — agnos-ABI static ELFs that mirshi supervises.
COPY bin/ /bin/
# A tiny rootfs so the filesystem tools have something to read / list.
COPY data/ /data/

# mirshi is the entrypoint; the agnos tool path is the argument.
ENTRYPOINT ["/mirshi"]
CMD ["/bin/hello"]
