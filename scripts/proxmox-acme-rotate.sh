#!/usr/bin/env bash
# Rotates the Cloudflare API token shared by Proxmox ACME, k8s cert-manager,
# k8s external-dns, the Vault backup record, AND the Synology NAS acme.sh
# config. One run updates all five consumers; no manual mop-up after.
#
# The token has four scopes of use:
#   1. PVE ACME plugin (/etc/pve/priv/acme/plugins.cfg — shared between
#      6 nodes; we update on pve1 and PVE syncs the rest)
#   2. cert-manager flat secret (cert-manager/cloudflare-api-token, NOT ESO)
#   3. ExternalSecret-backed external-dns secret (Vault home/homelab/k8s/
#      externaldns:cloudflare_api_token; we trigger ESO force-sync)
#   4. Vault backup record (home/homelab/proxmox/acme-cloudflare)
#   5. Synology NAS ~/.acme.sh/cf.env (used by *.example.com LE renewal)
#
# After all five writes succeed, `pvenode acme cert order --force` is run on
# every PVE node sequentially to re-issue pveproxy certs against the new
# token. Set -e aborts on the first failure; partial state is recoverable
# by simple rerun because writes are idempotent.
#
# Subcommands:
#   verify              read CF_Token from Vault, hit CF /user/tokens/verify,
#                       show per-node pveproxy cert dates + NAS cert date
#   rotate [--token V]  full 8-step rotation. If --token omitted, prompts
#                       interactively (read -rs, no echo).
#
# Reminder: revoke the OLD token in the Cloudflare UI after a successful
# rotation. The script does NOT do this — only Cloudflare can revoke.
set -euo pipefail

PVE_NODES="${PVE_NODES:-pve1 pve2 pve3 pve4 pve5 pve6}"
PVE_NETWORK="${PVE_NETWORK:-10.11.11.1}"          # +1..+6 to get 10.11.11.11..16
PVE_SYNC_NODE="${PVE_SYNC_NODE:-pve1}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-1d95f483f4ed9e02b348062c7236f999}"

VAULT_MOUNT="${VAULT_MOUNT:-home}"
VAULT_PATH_EXTERNALDNS="${VAULT_PATH_EXTERNALDNS:-homelab/k8s/externaldns}"
VAULT_PATH_BACKUP="${VAULT_PATH_BACKUP:-homelab/proxmox/acme-cloudflare}"

CERTMGR_NS="${CERTMGR_NS:-cert-manager}"
CERTMGR_SECRET="${CERTMGR_SECRET:-cloudflare-api-token}"
CERTMGR_SECRET_KEY="${CERTMGR_SECRET_KEY:-api-token}"
CERTMGR_DEPLOY="${CERTMGR_DEPLOY:-cert-manager}"

EXTERNALDNS_NS="${EXTERNALDNS_NS:-external-dns}"
EXTERNALDNS_ES="${EXTERNALDNS_ES:-cloudflare-api-token}"

SYNOLOGY_SSH="${SYNOLOGY_SSH:-ivan@10.11.12.237}"
SYNOLOGY_CFENV="${SYNOLOGY_CFENV:-/var/services/homes/ivan/.acme.sh/cf.env}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 verify
  $0 rotate [--token <new-cf-token>]

Subcommands:
  verify  check current token validity (Vault → CF /user/tokens/verify),
          list per-node PVE cert dates, show NAS cf.env CF_Token presence
  rotate  full 8-step token rotation across all 5 consumers + cert reissue.
          If --token is omitted, prompts interactively with no echo.

Env knobs (defaults shown in --help; override if cluster layout differs):
  PVE_NODES                  $PVE_NODES
  PVE_NETWORK                $PVE_NETWORK  (suffix +1..+N for each node)
  PVE_SYNC_NODE              $PVE_SYNC_NODE  (any one node — /etc/pve is shared)
  CF_ACCOUNT_ID              $CF_ACCOUNT_ID
  VAULT_MOUNT                $VAULT_MOUNT
  VAULT_PATH_EXTERNALDNS     $VAULT_PATH_EXTERNALDNS
  VAULT_PATH_BACKUP          $VAULT_PATH_BACKUP
  CERTMGR_NS/SECRET/KEY      $CERTMGR_NS / $CERTMGR_SECRET / $CERTMGR_SECRET_KEY
  CERTMGR_DEPLOY             $CERTMGR_DEPLOY
  EXTERNALDNS_NS/ES          $EXTERNALDNS_NS / $EXTERNALDNS_ES
  SYNOLOGY_SSH               $SYNOLOGY_SSH
  SYNOLOGY_CFENV             $SYNOLOGY_CFENV
EOF
}

die_usage() { usage; exit 2; }
require() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }

# Map node index -> SSH host string.
pve_ssh_target() {
  # pve_ssh_target <1-based index>
  printf 'root@%s%s' "$PVE_NETWORK" "$1"
}

ssh_pve() {
  # ssh_pve <node-index> <command...>
  local idx="$1"; shift
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$(pve_ssh_target "$idx")" "$@"
}

ssh_nas() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$SYNOLOGY_SSH" "$@"
}

cf_verify_token() {
  # cf_verify_token <token>  -> exits 0 if active
  local token="$1" resp http
  resp=$(curl -sS -w '\n%{http_code}' \
    -H "Authorization: Bearer $token" \
    'https://api.cloudflare.com/client/v4/user/tokens/verify' 2>&1) || true
  http=$(printf '%s\n' "$resp" | tail -1)
  if [ "$http" != "200" ]; then
    echo "Cloudflare token verify failed (HTTP $http):" >&2
    printf '%s\n' "$resp" | sed '$d' >&2
    return 1
  fi
  printf '%s\n' "$resp" | sed '$d' | jq -er '
    if .success and (.result.status == "active") then "active" else error("inactive") end
  ' >/dev/null
}

cmd_verify() {
  require ssh
  require vault
  require jq
  require curl

  local current
  current=$(vault kv get -mount="$VAULT_MOUNT" -field=CF_Token "$VAULT_PATH_BACKUP" 2>/dev/null) || {
    echo "could not read $VAULT_MOUNT/$VAULT_PATH_BACKUP:CF_Token" >&2
    exit 1
  }

  echo "=== Cloudflare /user/tokens/verify against current Vault token ==="
  if cf_verify_token "$current"; then
    echo "  status: active"
  else
    echo "  status: NOT active — rotate ASAP" >&2
    exit 1
  fi

  echo
  echo "=== PVE pveproxy cert dates (per node) ==="
  local i=1
  for n in $PVE_NODES; do
    printf '  %s: ' "$n"
    ssh_pve "$i" "openssl x509 -in /etc/pve/nodes/$n/pveproxy-ssl.pem -noout -subject -enddate 2>/dev/null" \
      | tr '\n' ' '
    echo
    i=$((i+1))
  done

  echo
  echo "=== NAS cf.env state ==="
  ssh_nas "test -f $SYNOLOGY_CFENV && echo 'cf.env present' && grep -c '^export CF_Token=' $SYNOLOGY_CFENV \
           | awk '{print \"CF_Token lines: \"\$0}'" \
    || echo "  cf.env missing or unreadable"
  echo
  echo "=== consistency: does NAS token == Vault token? ==="
  local nas_token
  nas_token=$(ssh_nas "grep '^export CF_Token=' $SYNOLOGY_CFENV | sed 's/^export CF_Token=//; s/^\"//; s/\"$//'" 2>/dev/null || true)
  if [ -n "$nas_token" ] && [ "$nas_token" = "$current" ]; then
    echo "  MATCH"
  else
    echo "  MISMATCH — NAS uses a different CF token than Vault. Run 'rotate' or sync manually." >&2
  fi
  unset current nas_token
}

# Read NEW_TOKEN from --token <v> arg, or prompt with no-echo.
read_new_token() {
  local arg="${1:-}"
  if [ -n "$arg" ]; then
    NEW_TOKEN="$arg"
  else
    # /dev/tty so it works inside pipelines / under set -e
    if [ -t 0 ]; then
      read -rsp 'New CF Token (no echo): ' NEW_TOKEN
      echo
    else
      echo "stdin not a tty and no --token provided" >&2
      exit 2
    fi
  fi
  [ -n "$NEW_TOKEN" ] || { echo "empty token" >&2; exit 1; }
}

cmd_rotate() {
  local token_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --token) token_arg="${2:?--token requires a value}"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; die_usage ;;
    esac
  done

  require ssh
  require vault
  require jq
  require curl
  require kubectl
  require base64

  read_new_token "$token_arg"

  echo "=== 1/8 verify new token against Cloudflare /user/tokens/verify ==="
  if ! cf_verify_token "$NEW_TOKEN"; then
    echo "new token rejected by CF — aborting before changing anything" >&2
    unset NEW_TOKEN
    exit 1
  fi
  echo "  active — proceeding"

  echo
  echo "=== 2/8 update PVE plugin config on $PVE_SYNC_NODE (shared /etc/pve) ==="
  # PVE expects --data to be a PATH to a file with KEY=VALUE lines, not the
  # value itself. The file is written and shredded inside one ssh command.
  local sync_idx=1
  if ! printf 'CF_Account_ID=%s\nCF_Token=%s\n' "$CF_ACCOUNT_ID" "$NEW_TOKEN" \
    | ssh -o BatchMode=yes "root@${PVE_NETWORK}${sync_idx}" \
        'umask 077 && cat > /root/.cf.tmp \
         && pvenode acme plugin set cloudflare --data /root/.cf.tmp \
         && shred -u /root/.cf.tmp'; then
    echo "pvenode acme plugin set failed" >&2
    unset NEW_TOKEN
    exit 1
  fi

  echo
  echo "=== 3/8 patch cert-manager flat secret + rollout restart ==="
  local b64
  b64=$(printf '%s' "$NEW_TOKEN" | base64 -w0)
  kubectl -n "$CERTMGR_NS" patch secret "$CERTMGR_SECRET" \
    --type=merge -p "{\"data\":{\"$CERTMGR_SECRET_KEY\":\"$b64\"}}" >/dev/null
  kubectl -n "$CERTMGR_NS" rollout restart "deploy/$CERTMGR_DEPLOY" >/dev/null
  unset b64
  echo "  patched + restart triggered"

  echo
  echo "=== 4/8 Vault put externaldns + acme-cloudflare backup ==="
  vault kv put -mount="$VAULT_MOUNT" "$VAULT_PATH_EXTERNALDNS" \
    cloudflare_api_token="$NEW_TOKEN" >/dev/null
  vault kv put -mount="$VAULT_MOUNT" "$VAULT_PATH_BACKUP" \
    CF_Account_ID="$CF_ACCOUNT_ID" \
    CF_Token="$NEW_TOKEN" >/dev/null
  echo "  wrote $VAULT_MOUNT/$VAULT_PATH_EXTERNALDNS + $VAULT_MOUNT/$VAULT_PATH_BACKUP"

  echo
  echo "=== 5/8 ESO force-sync external-dns ExternalSecret ==="
  kubectl -n "$EXTERNALDNS_NS" annotate externalsecret "$EXTERNALDNS_ES" \
    "force-sync=$(date +%s)" --overwrite >/dev/null
  echo "  annotated; ESO will pick up within seconds"

  echo
  echo "=== 6/8 update Synology NAS cf.env (s3.example.com cert renewal) ==="
  # sed -i only the CF_Token line, preserving CF_Account_ID and any other vars.
  ssh_nas "sed -i \"s|^export CF_Token=.*|export CF_Token=$NEW_TOKEN|\" $SYNOLOGY_CFENV"
  echo "  cf.env updated on $SYNOLOGY_SSH"

  echo
  echo "=== 7/8 pvenode acme cert order --force on all PVE nodes (sequential) ==="
  local i=1
  for n in $PVE_NODES; do
    echo "  --- $n ---"
    ssh_pve "$i" 'pvenode acme cert order --force 2>&1 | tail -5'
    i=$((i+1))
  done

  echo
  echo "=== 8/8 verify new pveproxy cert dates ==="
  i=1
  for n in $PVE_NODES; do
    printf '  %s: ' "$n"
    ssh_pve "$i" "openssl x509 -in /etc/pve/nodes/$n/pveproxy-ssl.pem -noout -enddate" \
      | tr '\n' ' '
    echo
    i=$((i+1))
  done

  unset NEW_TOKEN
  echo
  echo "=== DONE — REMINDER: revoke the OLD token in Cloudflare UI ==="
  echo "    (My Profile → API Tokens → ... → Revoke. The script cannot do this.)"
}

case "${1:-}" in
  verify) shift; cmd_verify "$@" ;;
  rotate) shift; cmd_rotate "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *) die_usage ;;
esac
