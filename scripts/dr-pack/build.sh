#!/usr/bin/env bash
# Refresh the minimal DR pack at $DR_PACK_DIR.
# Overwrites the 4 pack files, keeps user-added extras. Fails if it cannot read
# the openbao-keys Secret or take a fresh Raft snapshot: the two non-negotiables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../dr/lib/common.sh
source "$SCRIPT_DIR/../dr/lib/common.sh"

mkdir -p "$DR_PACK_DIR"
chmod 700 "$DR_PACK_DIR"

# --- 00 Shamir bundle from live openbao-keys + openbao-root-token Secrets ---
log_info "dumping openbao-keys + openbao-root-token from cluster"
TMP_JSON=$(mktemp)
trap 'shred -u "$TMP_JSON" 2>/dev/null || rm -f "$TMP_JSON"' EXIT

K0=$(kubectl -n openbao get secret openbao-keys -o jsonpath='{.data.key-0}' | base64 -d)
K1=$(kubectl -n openbao get secret openbao-keys -o jsonpath='{.data.key-1}' | base64 -d)
K2=$(kubectl -n openbao get secret openbao-keys -o jsonpath='{.data.key-2}' | base64 -d)
ROOT=$(kubectl -n openbao get secret openbao-root-token -o jsonpath='{.data.token}' | base64 -d \
  || kubectl -n openbao get secret openbao-root-token -o jsonpath='{.data.root_token}' | base64 -d)

[[ -n "$K0" ]] && [[ -n "$K1" ]] && [[ -n "$K2" ]] && [[ -n "$ROOT" ]] \
  || die "openbao Secrets incomplete — cannot rebuild Shamir bundle"

jq -n \
  --arg k0 "$K0" --arg k1 "$K1" --arg k2 "$K2" --arg rt "$ROOT" \
  '{unseal_keys_b64: [$k0,$k1,$k2], unseal_shares: 3, unseal_threshold: 3, root_token: $rt}' \
  > "$TMP_JSON"

if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
  gpg --batch --yes --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
      --symmetric --cipher-algo AES256 \
      --output "$DR_PACK_DIR/00-shamir.json.gpg" \
      "$TMP_JSON"
else
  gpg --yes --symmetric --cipher-algo AES256 \
      --output "$DR_PACK_DIR/00-shamir.json.gpg" \
      "$TMP_JSON"
fi
chmod 600 "$DR_PACK_DIR/00-shamir.json.gpg"
log_ok "wrote 00-shamir.json.gpg"

# --- 01 bootstrap env ------------------------------------------------------
log_info "writing 01-bootstrap.env (CF + Garage + OVH + OVH crypt + OpenWrt)"
{
  echo "# Refreshed: $(date -Iseconds)"
  # Phases 03/04 need the Cloudflare token. Read from the cluster: the
  # operator's env var name varies and the pack once shipped MISSING.
  # An explicit CF_API_TOKEN still wins.
  CF_TOKEN="${CF_API_TOKEN:-}"
  [[ -n "$CF_TOKEN" ]] || CF_TOKEN=$(kubectl -n cert-manager get secret cloudflare-api-token     -o jsonpath='{.data.api-token}' 2>/dev/null | base64 -d)
  [[ -n "$CF_TOKEN" ]] || CF_TOKEN=$(kubectl -n external-dns get secret external-dns-cloudflare     -o jsonpath='{.data.cloudflare_api_token}' 2>/dev/null | base64 -d)
  echo "CF_API_TOKEN=${CF_TOKEN:-MISSING-cloudflare-token}"

  # S3 keys and restic passwords, from the live ESO-managed Secrets:
  #   openbao/snapshots-rclone      — `snapshots` bucket keys (Garage) and OVH
  #   <ns>/<app>-restic-garage|ovh  — `restic-apps` key + restic passwords
  # Donor app is configurable (default rsstt); key and password are shared by all repos.
  RESTIC_DONOR_NS="${RESTIC_DONOR_NS:-rsstt}"
  RESTIC_DONOR_APP="${RESTIC_DONOR_APP:-rss-to-telegram-bot}"

  # An empty value is marked like the CF token, so the pack never ships blank keys silently.
  sn() { local v; v=$(kubectl -n openbao get secret snapshots-rclone -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d || true); echo "${v:-MISSING-snapshots-rclone}"; }
  rs() { local target="$1" key="$2"; kubectl -n "$RESTIC_DONOR_NS" get secret "${RESTIC_DONOR_APP}-restic-${target}" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d; }

  echo "GARAGE_SNAPSHOTS_ACCESS_KEY=$(sn RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID)"
  echo "GARAGE_SNAPSHOTS_SECRET=$(sn RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY)"
  echo "OVH_S3_ACCESS_KEY=$(sn RCLONE_CONFIG_OVH_ACCESS_KEY_ID)"
  echo "OVH_S3_SECRET_KEY=$(sn RCLONE_CONFIG_OVH_SECRET_ACCESS_KEY)"
  # rclone crypt key of the OVH snapshot, tfstate, pg_dump and router config
  # copies (rclone-obscured).
  echo "OVH_CRYPT_PASSWORD=$(sn RCLONE_CONFIG_OVHCRYPT_PASSWORD)"
  echo "OVH_CRYPT_PASSWORD2=$(sn RCLONE_CONFIG_OVHCRYPT_PASSWORD2)"

  echo "GARAGE_RESTIC_ACCESS_KEY=$(rs garage AWS_ACCESS_KEY_ID)"
  echo "GARAGE_RESTIC_SECRET=$(rs garage AWS_SECRET_ACCESS_KEY)"
  # No restic repo opens without these, and OpenBao (their home) is itself
  # restored from a backup: the scheme's only circular dependency.
  echo "RESTIC_PASSWORD_GARAGE=$(rs garage RESTIC_PASSWORD)"
  echo "RESTIC_PASSWORD_OVH=$(rs ovh RESTIC_PASSWORD)"
  # VPS fleet repos (bucket/prefix restic-vps): own Garage key and passwords; OVH key as above.
  vp() { local v; v=$(kubectl -n backup-drill get secret drill-restic-vps -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d || true); echo "${v:-MISSING-drill-restic-vps}"; }
  echo "GARAGE_RESTIC_VPS_ACCESS_KEY=$(vp VPS_GARAGE_AK)"
  echo "GARAGE_RESTIC_VPS_SECRET=$(vp VPS_GARAGE_SK)"
  echo "RESTIC_VPS_PASSWORD_GARAGE=$(vp PW_VPS_GARAGE)"
  echo "RESTIC_VPS_PASSWORD_OVH=$(vp PW_VPS_OVH)"

  # Router host and rpcd login are in git (external-dns-openwrt values); only the password is secret.
  OW_PASS=$(kubectl -n external-dns-openwrt get secret openwrt-credentials -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
  [[ -z "$OW_PASS" ]] || echo "OPENWRT_PASS=$OW_PASS"
} > "$DR_PACK_DIR/01-bootstrap.env"
chmod 600 "$DR_PACK_DIR/01-bootstrap.env"
log_ok "wrote 01-bootstrap.env"

# --- 02 latest Raft snapshot ---
log_info "fetching latest OpenBao Raft snapshot"
# Fresh snapshot from the live pod, independent of the daily CronJob; DR phase
# 05 pulls the latest from S3 if this file goes stale.
kubectl -n openbao exec openbao-0 -- env \
  BAO_TOKEN="$ROOT" BAO_ADDR=http://127.0.0.1:8200 \
  bao operator raft snapshot save /tmp/raft.snap >/dev/null
kubectl -n openbao cp openbao/openbao-0:/tmp/raft.snap "$DR_PACK_DIR/02-vault-raft-snapshot.snap"
kubectl -n openbao exec openbao-0 -- rm /tmp/raft.snap >/dev/null
chmod 600 "$DR_PACK_DIR/02-vault-raft-snapshot.snap"
SNAP_SIZE=$(file_size "$DR_PACK_DIR/02-vault-raft-snapshot.snap")
log_ok "wrote 02-vault-raft-snapshot.snap (${SNAP_SIZE} bytes)"

# --- 03 cluster topology ----------------------------------------------------
log_info "writing 03-cluster.env (cluster topology snapshot)"
{
  echo "# Refreshed: $(date -Iseconds)"
  echo "GATEWAY_EXTERNAL_IP=$(kubectl -n kube-system get gateway cilium-gateway -o jsonpath='{.spec.addresses[0].value}' 2>/dev/null)"
  echo "GATEWAY_INTERNAL_IP=$(kubectl -n kube-system get gateway cilium-gateway-internal -o jsonpath='{.spec.addresses[0].value}' 2>/dev/null)"
  echo "GATEWAY_TLS_IP=$(kubectl -n kube-system get gateway cilium-gateway-tls -o jsonpath='{.spec.addresses[0].value}' 2>/dev/null)"
} > "$DR_PACK_DIR/03-cluster.env"
log_ok "wrote 03-cluster.env"

log_ok "DR pack refresh complete at $DR_PACK_DIR"
