#!/usr/bin/env bash
# docker/fanout.sh — the M3 multi-container fan-out demo (the near-term win):
# boot N agnos-mirshi containers concurrently, each running an agnos tool under
# mirshi, and collect results. This is the test-fleet model — throw concurrent
# agnos-userland workloads across heterogeneous Linux hosts, no QEMU, so each
# container is a plain native process tree sharing the host kernel.
#
# Usage: docker/fanout.sh [N] [tool]      (defaults: 12 /bin/hello)
#        IMG=agnos-mirshi N parallelism via plain `docker run` + wait.
set -euo pipefail

img="${IMG:-agnos-mirshi}"
n="${1:-12}"
tool="${2:-/bin/hello}"
# Stock-Docker-safe ptrace recipe (the default seccomp profile blocks ptrace).
caps=(--cap-add=SYS_PTRACE --security-opt seccomp=unconfined)

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "==> fanning out $n concurrent containers of '$img $tool'"

start=$(date +%s%N)
for i in $(seq 1 "$n"); do
    # set +e inside the subshell: a failing `docker run` must NOT abort before we
    # record its real exit code (the inherited set -e would skip the echo).
    ( set +e
      docker run --rm "${caps[@]}" "$img" "$tool" >"$tmp/out.$i" 2>"$tmp/err.$i"
      echo $? >"$tmp/rc.$i" ) &
done
wait
end=$(date +%s%N)

ok=0; fail=0
for i in $(seq 1 "$n"); do
    rc="$(cat "$tmp/rc.$i" 2>/dev/null || echo 1)"
    if [ "$rc" = "0" ]; then
        ok=$((ok + 1))
    else
        fail=$((fail + 1))
        echo "  container $i FAILED (rc=$rc): $(head -1 "$tmp/err.$i" 2>/dev/null)" >&2
    fi
done

msg=""
if [ "$fail" -ne 0 ]; then msg=", $fail failed"; fi
echo "==> $ok/$n containers OK$msg — wall $(( (end - start) / 1000000 )) ms"
echo "    sample output: $(head -1 "$tmp/out.1" 2>/dev/null)"
[ "$fail" -eq 0 ]
