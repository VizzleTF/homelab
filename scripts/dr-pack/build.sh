#!/usr/bin/env bash
# scripts/dr-pack/build.sh — refresh the minimal DR pack at $DR_PACK_DIR.
#
# Idempotent: overwrites the 4 pack files, never deletes user-added extras.
# Fails loudly if it can't source the openbao-keys Secret OR pull a fresh
# Raft snapshot from S3 — those are the two non-negotiables.

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

[ -n "$K0" ] && [ -n "$K1" ] && [ -n "$K2" ] && [ -n "$ROOT" ] \
  || die "openbao Secrets incomplete — cannot rebuild Shamir bundle"

jq -n \
  --arg k0 "$K0" --arg k1 "$K1" --arg k2 "$K2" --arg rt "$ROOT" \
  '{unseal_keys_b64: [$k0,$k1,$k2], unseal_shares: 3, unseal_threshold: 3, root_token: $rt}' \
  > "$TMP_JSON"

if [ -n "${GPG_PASSPHRASE:-}" ]; then
  gpg --batch --yes --passphrase "$GPG_PASSPHRASE" \
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
log_info "writing 01-bootstrap.env (CF + Garage + OVH + OpenWrt)"
{
  echo "# Refreshed: $(date -Iseconds)"
  echo "CF_API_TOKEN=${CF_API_TOKEN:-MISSING-export-CF_API_TOKEN-first}"

  GARAGE_AK=$(kubectl -n velero get secret velero-garage-creds -o jsonpath='{.data.cloud}' 2>/dev/null \
    | base64 -d | awk -F' = ' '/aws_access_key_id/{print $2}')
  GARAGE_SK=$(kubectl -n velero get secret velero-garage-creds -o jsonpath='{.data.cloud}' 2>/dev/null \
    | base64 -d | awk -F' = ' '/aws_secret_access_key/{print $2}')
  echo "GARAGE_VELERO_ACCESS_KEY=${GARAGE_AK:-MISSING}"
  echo "GARAGE_VELERO_SECRET=${GARAGE_SK:-MISSING}"

  OVH_AK=$(kubectl -n velero get secret velero-ovh-creds -o jsonpath='{.data.cloud}' 2>/dev/null \
    | base64 -d | awk -F' = ' '/aws_access_key_id/{print $2}')
  OVH_SK=$(kubectl -n velero get secret velero-ovh-creds -o jsonpath='{.data.cloud}' 2>/dev/null \
    | base64 -d | awk -F' = ' '/aws_secret_access_key/{print $2}')
  echo "OVH_S3_ACCESS_KEY=${OVH_AK:-MISSING}"
  echo "OVH_S3_SECRET_KEY=${OVH_SK:-MISSING}"

  OW_HOST=$(kubectl -n external-dns-openwrt get secret openwrt-credentials -o jsonpath='{.data.host}' 2>/dev/null | base64 -d || true)
  OW_USER=$(kubectl -n external-dns-openwrt get secret openwrt-credentials -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)
  OW_PASS=$(kubectl -n external-dns-openwrt get secret openwrt-credentials -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
  if [ -n "$OW_HOST" ]; then
    echo "OPENWRT_HOST=$OW_HOST"
    echo "OPENWRT_USER=$OW_USER"
    echo "OPENWRT_PASS=$OW_PASS"
  fi
} > "$DR_PACK_DIR/01-bootstrap.env"
chmod 600 "$DR_PACK_DIR/01-bootstrap.env"
log_ok "wrote 01-bootstrap.env"

# --- 02 latest Raft snapshot via approle (Velero hook already creates these) ---
log_info "fetching latest OpenBao Raft snapshot"
# The Velero schedule openbao-hourly runs `bao operator raft snapshot save`
# inside the openbao-0 pod and pushes the snapshot to S3 as part of the
# scheduled backup. We pull the freshest one straight from the live pod —
# avoids racing the next backup window.
kubectl -n openbao exec openbao-0 -- env \
  BAO_TOKEN="$ROOT" BAO_ADDR=http://127.0.0.1:8200 \
  bao operator raft snapshot save /tmp/raft.snap >/dev/null
kubectl -n openbao cp openbao/openbao-0:/tmp/raft.snap "$DR_PACK_DIR/02-vault-raft-snapshot.snap"
kubectl -n openbao exec openbao-0 -- rm /tmp/raft.snap >/dev/null
chmod 600 "$DR_PACK_DIR/02-vault-raft-snapshot.snap"
SNAP_SIZE=$(stat -c '%s' "$DR_PACK_DIR/02-vault-raft-snapshot.snap")
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
