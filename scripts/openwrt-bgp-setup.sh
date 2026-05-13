#!/usr/bin/env bash
# Configures eBGP on the OpenWrt router (10.11.12.1 mgmt, 10.11.11.1 servers
# VLAN) to peer with all six Talos nodes and learn LoadBalancer routes from
# the Cilium BGP control plane.
#
# Pairs with:
#   argocd/infra/cilium/manifests/cilium-bgp.yaml             (Cilium side CRs)
#   argocd/infra/cilium/manifests/cilium-bgp-externalsecret.yaml (MD5 secret)
#   Vault: home/homelab/k8s/kube-system/cilium-bgp{password}  (shared MD5)
#
# Subcommands:
#   install   apk add bird2 + uci firewall rule for TCP/179 on the servers zone
#   configure render /etc/bird.conf from Vault password, restart BIRD
#   verify    birdc show protocols + show route, plus ip route to the LB pool
#   down      stop+disable BIRD, leave config in place (for rollback drills)
#
# Idempotent — rerun safely. All writes atomic (tmp + mv).
set -euo pipefail

# OpenWrt management endpoint (LAN VLAN) — see [[reference_openwrt_router_topology]]
OWRT_SSH="${OWRT_SSH:-root@10.11.12.1}"
# BGP peer address on the OpenWrt side (servers VLAN, gateway for k8s nodes)
OWRT_BGP_LOCAL="${OWRT_BGP_LOCAL:-10.11.11.1}"

# Cluster ASN / OpenWrt ASN — match cilium-bgp.yaml
ASN_CLUSTER="${ASN_CLUSTER:-65010}"
ASN_OWRT="${ASN_OWRT:-65000}"

# Talos node IPs — see terraform_proxmox/configs/vms.yaml
PEERS=(
  "talos-cp-01      10.11.11.101"
  "talos-cp-02      10.11.11.102"
  "talos-cp-03      10.11.11.103"
  "talos-worker-01  10.11.11.111"
  "talos-worker-02  10.11.11.112"
  "talos-worker-03  10.11.11.113"
)

# LB pool — must match cilium-lb-ippool.yaml
LB_POOL="${LB_POOL:-10.11.11.128/25}"

VAULT_MOUNT="${VAULT_MOUNT:-home}"
VAULT_PATH="${VAULT_PATH:-homelab/k8s/kube-system/cilium-bgp}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <install|configure|verify|down>

  install     apk add bird2 + uci firewall rule (TCP/179, servers zone)
  configure   read MD5 password from Vault, render /etc/bird.conf, restart BIRD
  verify      birdc show protocols/routes + ip route for LB pool
  down        service bird stop && service bird disable (rollback drill)

Env overrides: OWRT_SSH, OWRT_BGP_LOCAL, ASN_CLUSTER, ASN_OWRT, LB_POOL,
               VAULT_MOUNT, VAULT_PATH
EOF
}

ssh_owrt() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$OWRT_SSH" "$@"
}

# ---- install --------------------------------------------------------------

cmd_install() {
  echo "[+] apk update && apk add bird2 bird2c"
  ssh_owrt sh -s <<'SH'
set -e
command -v apk >/dev/null || { echo "ERR: apk not found — wrong OpenWrt version?" >&2; exit 1; }
apk update
apk add bird2 bird2c
SH

  echo "[+] uci firewall rule: TCP/179 INPUT from servers zone"
  ssh_owrt sh -s <<'SH'
set -e
RULE_NAME="allow-bgp-from-servers"
EXISTING=$(uci show firewall 2>/dev/null | awk -F. -v n="$RULE_NAME" '$0 ~ "name=\047"n"\047" {print $1"."$2}')
if [ -n "$EXISTING" ]; then
  echo "    rule '$RULE_NAME' already present at $EXISTING — skipping"
else
  uci -q delete firewall.allow_bgp 2>/dev/null || true
  uci set firewall.allow_bgp=rule
  uci set firewall.allow_bgp.name="$RULE_NAME"
  uci set firewall.allow_bgp.src='servers'
  uci set firewall.allow_bgp.proto='tcp'
  uci set firewall.allow_bgp.dest_port='179'
  uci set firewall.allow_bgp.target='ACCEPT'
  uci commit firewall
  service firewall reload
  echo "    rule added + firewall reloaded"
fi
SH
  echo "[done] install"
}

# ---- configure ------------------------------------------------------------

render_bird_conf() {
  local pw="$1"
  cat <<EOF
# /etc/bird.conf — managed by scripts/openwrt-bgp-setup.sh
# eBGP peering with Cilium-managed Talos cluster (ASN ${ASN_CLUSTER}).
# Local-side identity: ${OWRT_BGP_LOCAL} (servers VLAN gateway).
# Edits here are overwritten on the next 'configure' run.

router id ${OWRT_BGP_LOCAL};

protocol device {
    scan time 10;
}

protocol direct {
    ipv4;
    interface "br-servers", "br-lan";
}

# Install learned BGP routes into the kernel FIB with ECMP across all peers.
protocol kernel {
    ipv4 {
        export all;
    };
    merge paths on;
}

# Accept only LoadBalancer /32s inside the announced pool; reject anything
# the cluster might leak (pod CIDR, service CIDR, defaults).
filter lb_pool_only {
    if net ~ [ ${LB_POOL}{25,32} ] then accept;
    reject;
}

template bgp talos_peer {
    local ${OWRT_BGP_LOCAL} as ${ASN_OWRT};
    password "${pw}";
    hold time 9;
    keepalive time 3;
    graceful restart on;
    ipv4 {
        import filter lb_pool_only;
        export none;
    };
}

EOF
  for entry in "${PEERS[@]}"; do
    local name="${entry%% *}"
    local ip="${entry##* }"
    cat <<EOF
protocol bgp ${name//-/_} from talos_peer {
    neighbor ${ip} as ${ASN_CLUSTER};
}

EOF
  done
}

cmd_configure() {
  echo "[+] reading MD5 password from Vault: ${VAULT_MOUNT}/${VAULT_PATH}"
  local pw
  pw=$(VAULT_FORMAT=json vault kv get -mount="${VAULT_MOUNT}" -field=password "${VAULT_PATH}" 2>/dev/null || true)
  if [ -z "$pw" ]; then
    echo "ERR: empty password from Vault path ${VAULT_MOUNT}/${VAULT_PATH}" >&2
    echo "     Hint: vault kv put ${VAULT_MOUNT}/${VAULT_PATH} password=\$(openssl rand -hex 16)" >&2
    exit 1
  fi
  if [ "${#pw}" -lt 8 ]; then
    echo "ERR: password too short (${#pw} chars) — refusing to push" >&2
    exit 1
  fi

  local tmpconf
  tmpconf=$(mktemp)
  trap 'rm -f "$tmpconf"' EXIT
  render_bird_conf "$pw" >"$tmpconf"

  echo "[+] uploading /etc/bird.conf (atomic write)"
  # Push to /tmp then mv — /tmp is tmpfs on OpenWrt 25.12, safe scratch.
  # cat|ssh keeps password out of process listings.
  cat "$tmpconf" | ssh_owrt 'cat > /tmp/bird.conf.new && \
    mv /tmp/bird.conf.new /etc/bird.conf && \
    chmod 600 /etc/bird.conf'

  echo "[+] enabling+restarting BIRD"
  ssh_owrt sh -s <<'SH'
set -e
service bird enable
service bird restart
sleep 2
service bird running >/dev/null 2>&1 || { service bird status; exit 1; }
SH
  echo "[done] configure — run '$(basename "$0") verify' to inspect sessions"
}

# ---- verify ---------------------------------------------------------------

cmd_verify() {
  echo "== birdc show protocols (BGP sessions) =="
  ssh_owrt 'birdc show protocols | grep -E "BIRD|Name|^[a-zA-Z]" '

  echo
  echo "== birdc show route table master4 (learned LB routes) =="
  ssh_owrt 'birdc show route table master4'

  echo
  echo "== kernel FIB for LB pool =="
  ssh_owrt "ip route show ${LB_POOL}"

  echo
  echo "== bird port listener (should be :179) =="
  ssh_owrt 'netstat -ln 2>/dev/null | grep :179 || ss -ln 2>/dev/null | grep :179'
}

# ---- down -----------------------------------------------------------------

cmd_down() {
  echo "[!] stopping+disabling BIRD on $OWRT_SSH"
  ssh_owrt sh -s <<'SH'
set -e
service bird stop || true
service bird disable || true
SH
  echo "[done] down — /etc/bird.conf left in place; firewall rule preserved"
}

# ---- main -----------------------------------------------------------------

case "${1:-}" in
  install)    cmd_install ;;
  configure)  cmd_configure ;;
  verify)     cmd_verify ;;
  down)       cmd_down ;;
  -h|--help|"") usage; [ "${1:-}" = "" ] && exit 1 || exit 0 ;;
  *) echo "unknown subcommand: $1" >&2; usage; exit 1 ;;
esac
