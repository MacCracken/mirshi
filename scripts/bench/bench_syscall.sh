#!/usr/bin/env bash
# scripts/bench/bench_syscall.sh — mirshi per-syscall overhead + realistic-workload
# benchmark. MECHANISM-AGNOSTIC by design: the `mech` column is the interception
# mechanism (ptrace today; seccomp-notify rows slot in unchanged once that path
# lands), and overhead is reported as a MULTIPLE OVER NATIVE (no supervisor), not
# a bare µs, since absolute µs drifts with hardware.
#
#   N=200000 REPS=5 MECH=ptrace scripts/bench/bench_syscall.sh
#
# The native baseline runs the SAME source compiled Linux-target and executed
# WITHOUT mirshi, so (mirshi − native)/N isolates the trap+translate tax (the
# identical loop cancels). Reports min-of-REPS (least scheduler noise).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
N="${N:-200000}"
reps="${REPS:-5}"
mech="${MECH:-ptrace}"
mflags="${MIRSHI_FLAGS:---no-seccomp}"   # measure the trap+translate path, not seccomp
bench="$(mktemp -d)"; trap 'rm -rf "$bench"' EXIT

cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"

# A syscall-storm source: N iterations of $1 (an agnos sys_* call). Built BOTH
# agnos-target (run under mirshi) and Linux-target (the native floor).
gen_storm() { # name body
    cat > "$bench/$1.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var buf[64];
    var i = 0;
    while (i < $N) { $2 i = i + 1; }
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
    cyrius build --agnos "$bench/$1.cyr" "$bench/$1.agnos" >/dev/null
    cyrius build        "$bench/$1.cyr" "$bench/$1.native" >/dev/null
}

# min wall-ms over REPS of a command (warm-up run discarded).
minms() {
    "$@" >/dev/null 2>&1 || true            # warm-up
    local best=99999999 r t0 t1 ms
    for r in $(seq 1 "$reps"); do
        t0=$(date +%s%N); "$@" >/dev/null 2>&1 || true; t1=$(date +%s%N)
        ms=$(( (t1 - t0) / 1000000 ))
        [ "$ms" -lt "$best" ] && best=$ms
    done
    echo "$best"
}

echo "# mirshi syscall benchmark"
echo "host:  $(uname -sr) | cpus: $(nproc) | $([ -f /.dockerenv ] && echo in-docker || echo bare-metal/VM) | $(date -u +%FT%TZ)"
echo "N=$N  reps=$reps  mech=$mech  mirshi-flags='$mflags'"
echo
printf '%-22s %-8s %12s %12s %14s %8s\n' workload mech mirshi_ms native_ms ns_per_call x_native

# --- per-syscall storms: the trap+translate floor ---
run_storm() { # label  agnos-call
    gen_storm "$1" "$2"
    local m n over xn
    m="$(minms "$mirshi" $mflags "$bench/$1.agnos")"
    n="$(minms "$bench/$1.native")"
    over=$(( (m - n) * 1000000 / N ))                       # ns of supervisor tax per call
    if [ "$n" -gt 0 ]; then xn="$(( m * 10 / n ))"; else xn="-"; fi
    printf '%-22s %-8s %12s %12s %14s %8s\n' "$1" "$mech" "$m" "$n" "$over" "${xn:+${xn:0:-1}.${xn: -1}x}"
}
run_storm getpid_storm    "syscall(SYS_GETPID);"
run_storm getrandom_storm "syscall(SYS_GETRANDOM, &buf, 16, 0);"

# --- realistic workload: cat a multi-MB file (read#5/write#1 storm) ---
mb="${MB:-4}"
head -c "$(( mb * 1024 * 1024 ))" /dev/zero | tr '\0' 'x' > "$bench/big.txt"
cat > "$bench/catbig.cyr" <<EOF
include "lib/syscalls.cyr"
fn main(): i64 {
    var p = "$bench/big.txt";
    var fd = sys_open(p, strlen(p), AO_RDONLY);
    if (fd < 0) { return 1; }
    var buf[65536];
    while (1 == 1) {
        var n = sys_read(fd, &buf, 65536);
        if (n <= 0) { sys_close(fd); return 0; }
        sys_write(1, &buf, n);
    }
    return 0;
}
var r = main();
syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$bench/catbig.cyr" "$bench/catbig.agnos" >/dev/null
# Native floor = the system `cat` of the same file (AO_* flags are agnos-only, so
# the same source can't compile Linux-target; the system cat is the honest
# "run this workload without mirshi" baseline).
cm="$(minms "$mirshi" $mflags "$bench/catbig.agnos")"
cn="$(minms cat "$bench/big.txt")"
cx="-"; [ "$cn" -gt 0 ] && cx="$(( cm * 10 / cn ))"
printf '%-22s %-8s %12s %12s %14s %8s\n' "cat_${mb}MB" "$mech" "$cm" "$cn" "-" "${cx:+${cx:0:-1}.${cx: -1}x}"

echo
echo "ns_per_call = (mirshi_ms − native_ms) × 1e6 / N  (the per-syscall trap+translate tax)"
echo "x_native    = mirshi_ms / native_ms  (whole-workload slowdown over no-supervisor)"
