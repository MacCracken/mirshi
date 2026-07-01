#!/usr/bin/env bash
# scripts/it/net_config.sh — v1.3.0 net_config#61 gate (docs/adr/0012). mirshi's net_config reads
# the REAL container-netns config: field 2 (gateway) from /proc/net/route, field 3 (DNS) from
# /etc/resolv.conf, field 0 (host IP) via a getsockname trick; field 1 (netmask) is 0-unset; a bad
# field is -1. The gate computes the expected gateway + DNS from the environment's own files and
# asserts mirshi returns the SAME kernel-ip4 values (robust across CI hosts). Needs python3 + ptrace.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
command -v python3 >/dev/null || { echo "SKIP: net_config — python3 not available"; exit 0; }
cyrius build src/main.cyr build/mirshi >/dev/null
mirshi="$root/build/mirshi"
sbox="$(mktemp -d)"; trap 'rm -rf "$sbox"' EXIT
fail=0

# expected gateway + DNS from THIS environment's files, in the agnos kernel-ip4 form (decimal).
read -r exp_gw exp_dns < <(python3 - <<'PY'
def k4(s):
    o=[int(x) for x in s.strip().split('.')]; return (o[0]<<24)|(o[1]<<16)|(o[2]<<8)|o[3]
gw=0
try:
    for ln in open('/proc/net/route').read().splitlines()[1:]:
        f=ln.split()
        if len(f)>=3 and f[1]=='00000000':
            h=int(f[2],16); gw=((h&0xff)<<24)|((h&0xff00)<<8)|((h>>8)&0xff00)|((h>>24)&0xff); break
except Exception: pass
dns=0
try:
    for ln in open('/etc/resolv.conf'):
        if ln.startswith('nameserver'): dns=k4(ln.split()[1]); break
except Exception: pass
print(gw, dns)
PY
)

cat > "$sbox/ncfg.cyr" <<'EOF'
include "lib/syscalls.cyr"
fn emit(label, v): i64 {
    file_write(1, label, strlen(label));
    var b[24]; var n = fmt_int_buf(v, &b); file_write(1, &b, n); file_write(1, "\n", 1); return 0;
}
fn main(): i64 {
    emit("mask=", sys_net_config(1));
    emit("gw=", sys_net_config(2));
    emit("dns=", sys_net_config(3));
    emit("bad=", sys_net_config(9));
    return 0;
}
var r = main(); syscall(SYS_EXIT, r);
EOF
cyrius build --agnos "$sbox/ncfg.cyr" "$sbox/ncfg" >/dev/null 2>&1

# under --net: net_config reads real values.
out="$("$mirshi" --net "$sbox/ncfg" 2>/dev/null)"
g="$(printf '%s\n' "$out" | sed -n 's/^gw=//p')"
d="$(printf '%s\n' "$out" | sed -n 's/^dns=//p')"
m="$(printf '%s\n' "$out" | sed -n 's/^mask=//p')"
bad="$(printf '%s\n' "$out" | sed -n 's/^bad=//p')"
[ "$g" = "$exp_gw" ]   && echo "OK: net_config(2) gateway matches /proc/net/route ($g)" || { echo "FAIL: gw=$g want $exp_gw" >&2; fail=1; }
[ "$d" = "$exp_dns" ]  && echo "OK: net_config(3) DNS matches /etc/resolv.conf ($d)"    || { echo "FAIL: dns=$d want $exp_dns" >&2; fail=1; }
[ "$m" = "0" ]         && echo "OK: net_config(1) netmask = 0 (unset)"                  || { echo "FAIL: mask=$m want 0" >&2; fail=1; }
[ "$bad" = "-1" ]      && echo "OK: net_config(9) bad field -> -1"                      || { echo "FAIL: bad=$bad want -1" >&2; fail=1; }

# without --net: the net band (incl. net_config) is ENOSYS -> -1.
out2="$("$mirshi" "$sbox/ncfg" 2>/dev/null)"
g2="$(printf '%s\n' "$out2" | sed -n 's/^gw=//p')"
[ "$g2" = "-1" ] && echo "OK: no --net -> net_config ENOSYS (-1)" || { echo "FAIL: no-net gw=$g2 want -1" >&2; fail=1; }

if [ "$fail" -ne 0 ]; then echo "net_config: FAILED" >&2; exit 1; fi
echo "OK: net_config — real netns gateway/DNS read + netmask-unset + bad-field + --net gating"
