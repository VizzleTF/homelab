#!/usr/bin/env bash
# Checks a LAN DNS name on the OpenWrt router at every hop, so a stale cache
# is not mistaken for a broken external-dns-openwrt pipeline.
#
# The router hijacks ALL port-53 traffic (LAN and its own) to mihomo (Nikki,
# :1053), which forwards `+.example.com` to dnsmasq and CACHES negative answers.
# `nslookup <name> 10.11.12.1` therefore shows mihomo's cache, not dnsmasq:
# a name queried before its HTTPRoute existed keeps returning NXDOMAIN (and a
# removed one keeps resolving) long after dnsmasq has the right answer.
# See [[reference_openwrt_dnsmasq_reload_ujail]].
#
# Shows:
#   1. UCI dhcp sections for the name (`external_dns=homelab` = written by
#      external-dns-openwrt; other sections are hand-made)
#   2. dnsmasq's answer, bypassing the hijack (dig runs inside the
#      services/dnsmasq cgroup, which the Nikki nft rules exempt)
#   3. the answer clients get via router :53 (through mihomo)
#   then a verdict.
#
# Exit codes:
#   0    mihomo agrees with dnsmasq, and dnsmasq serves every UCI record
#   1    mihomo differs from dnsmasq, a dig failed, or UCI has the name but
#        dnsmasq does not serve it
#   2    usage error, invalid host, unusable mihomo controller or flush failed
#   255  ssh to the router failed
#
# --flush first POSTs /cache/dns/flush to the mihomo controller (the only
# mutation; clears mihomo's DNS cache, harmless). The controller address and
# secret are read from /etc/nikki/run/config.yaml on the router at runtime.
set -euo pipefail

OWRT_SSH="${OWRT_SSH:-root@10.11.12.1}"
DOMAIN="${DOMAIN:-example.com}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <host> [--flush]

  <host>    FQDN, or a bare name (".${DOMAIN}" is appended)
  --flush   flush mihomo's DNS cache before checking

Env overrides: OWRT_SSH, DOMAIN
EOF
}

host="" flush=0
for arg in "$@"; do
  case "$arg" in
    --flush) flush=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [[ -z "$host" ]] || { usage >&2; exit 2; }; host="$arg" ;;
  esac
done
[[ -n "$host" ]] || { usage >&2; exit 2; }
host="${host,,}"; host="${host%.}"
[[ "$host" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)*$ ]] || { echo "bad host: $host" >&2; exit 2; }
[[ "$host" == *.* ]] || host="${host}.${DOMAIN}"

# ssh joins its arguments into a remote command line: pass only the validated
# host, quoted once more.
ssh -o BatchMode=yes -o ConnectTimeout=5 "$OWRT_SSH" sh -s -- "$(printf %q "$host")" "$flush" <<'SH'
set -euf
host=$1 flush=$2
cfg=/etc/nikki/run/config.yaml

if [ "$flush" = 1 ]; then
  ctl=$(awk '/^external-controller:/{print $2}' "$cfg" | tr -d "\"'")
  case "$ctl" in
    ''|/*|unix:*) echo "mihomo external-controller is '${ctl}' in $cfg: no TCP API to flush" >&2; exit 2 ;;
  esac
  secret=$(awk '/^secret:/{print $2}' "$cfg" | tr -d "\"'")
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $secret" "http://127.0.0.1:${ctl##*:}/cache/dns/flush") || true
  echo "== mihomo cache flush: HTTP $code (204 = ok)"
  [ "$code" = 204 ] || exit 2
fi

echo "== UCI dhcp records for $host"
secs=$(uci show dhcp | awk -F= -v h="'$host'" '$2==h {split($1, a, "."); print a[2]}' | sort -u)
owned=0
if [ -z "$secs" ]; then
  echo "   (none)"
else
  for s in $secs; do
    uci show "dhcp.$s" | sed 's/^/   /'
    [ "$(uci -q get "dhcp.$s.external_dns")" = homelab ] && owned=1
  done
fi

# Answer as one sorted line; a failed dig (timeout, SERVFAIL transport) -> ERR.
ask() {
  out=$("$@") || { echo ERR; return; }
  printf '%s\n' "$out" | grep -v '^;' | sort | tr '\n' ' ' | sed 's/ *$//'
}
# Run dig from the dnsmasq cgroup: the Nikki hijack chain returns for it,
# so the query reaches dnsmasq on 127.0.0.1:53 instead of mihomo.
direct=$(ask sh -c 'echo $$ > /sys/fs/cgroup/services/dnsmasq/cgroup.procs && exec dig +short +time=2 +tries=1 @127.0.0.1 "$1"' _ "$host")
via=$(ask dig +short +time=2 +tries=1 @127.0.0.1 "$host")
echo "== dnsmasq (direct):         ${direct:-NXDOMAIN/empty}"
echo "== router :53 (via mihomo):  ${via:-NXDOMAIN/empty}"

echo "== verdict"
[ -n "$secs" ] && u=yes || u=no
[ "$owned" = 1 ] && u="$u (external-dns)"
case "$direct" in ERR) d="dnsmasq error" ;; '') d=no ;; *) d=yes ;; esac
case "$via" in ERR) m="mihomo error" ;; "$direct") m=yes ;; *) m=no ;; esac
echo "   UCI record: $u | dnsmasq answers: $d | mihomo matches dnsmasq: $m"
if [ "$direct" = ERR ] || [ "$via" = ERR ]; then
  echo "   -> a resolver did not answer (dig timed out / failed); check 'logread | grep -E \"dnsmasq|nikki\"'"
  exit 1
fi
if [ -n "$secs" ] && [ -z "$direct" ]; then
  echo "   -> UCI has it but dnsmasq does not: check 'logread | grep dnsmasq' (hostfile / restart)"
  exit 1
fi
if [ "$m" = no ]; then
  echo "   -> mihomo serves a stale cached answer; rerun with --flush"
  exit 1
fi
if [ -z "$secs" ] && [ -n "$direct" ]; then
  echo "   -> no UCI record; dnsmasq answered from another source (hostfile entry or upstream 1.1.1.1, e.g. a Cloudflare record)"
fi
SH
