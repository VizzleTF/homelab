#!/usr/bin/env bash
# Phase 06 — OpenBao install + restore from Shamir bundle + Raft snapshot.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/vault-helpers.sh
source "$(dirname "$0")/../lib/vault-helpers.sh"

require_kubectl

helm repo add openbao https://openbao.github.io/openbao-helm >/dev/null 2>&1 || true
helm repo add pytoshka https://pytoshka.github.io/vault-autounseal >/dev/null 2>&1 || true
helm repo update openbao pytoshka >/dev/null

kubectl create ns openbao 2>/dev/null || true
kubectl label ns openbao pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null

log_info "installing OpenBao (will start sealed/uninitialized)"
helm_apply openbao openbao/openbao openbao \
  --version 0.28.2 \
  -f "$REPO_ROOT/argocd/infra/openbao/values.yaml"

wait_for "openbao-0 Running" \
  "kubectl -n openbao get pod openbao-0 -o jsonpath='{.status.phase}' | grep -q Running" \
  180

# Decrypt Shamir bundle
log_info "decrypting Shamir bundle"
tmp=$(mktemp)
trap 'shred -u "$tmp" 2>/dev/null || rm -f "$tmp"' EXIT
gpg --quiet --batch --output "$tmp" --decrypt "$DR_PACK_DIR/00-shamir.json.gpg" \
  || die "Shamir decrypt failed"

K0=$(jq -r '.unseal_keys_b64[0]' "$tmp")
K1=$(jq -r '.unseal_keys_b64[1]' "$tmp")
K2=$(jq -r '.unseal_keys_b64[2]' "$tmp")
export VAULT_TOKEN
VAULT_TOKEN=$(jq -r '.root_token' "$tmp")

is_initialized=$(kubectl -n openbao exec openbao-0 -- bao status -format=json 2>/dev/null | jq -r '.initialized // false')

if [ "$is_initialized" = "false" ]; then
  log_warn "OpenBao reports uninitialized — Raft will be empty, restoring from snapshot will populate it"
  log_info "running bao operator init (NEW cluster — generates throwaway keys, we will restore the snapshot over it)"
  # NOTE: init is required even when restoring from snapshot — Raft needs an
  # initial leader. We discard the resulting keys and unseal with the Shamir
  # bundle from the DR pack after restore.
  kubectl -n openbao exec openbao-0 -- bao operator init \
    -key-shares=1 -key-threshold=1 -format=json > /tmp/throwaway-init.json
  trap 'shred -u "$tmp" /tmp/throwaway-init.json 2>/dev/null || rm -f "$tmp" /tmp/throwaway-init.json' EXIT
  TMP_KEY=$(jq -r '.unseal_keys_b64[0]' /tmp/throwaway-init.json)
  TMP_TOKEN=$(jq -r '.root_token' /tmp/throwaway-init.json)
  kubectl -n openbao exec openbao-0 -- bao operator unseal "$TMP_KEY" >/dev/null
  log_info "uploading Raft snapshot — overwrites cluster keyring"
  kubectl -n openbao cp "$DR_PACK_DIR/02-vault-raft-snapshot.snap" openbao/openbao-0:/tmp/snap.gz
  kubectl -n openbao exec openbao-0 -- env BAO_TOKEN="$TMP_TOKEN" BAO_ADDR="$BAO_ADDR_INTERNAL" \
    bao operator raft snapshot restore -force /tmp/snap.gz
  log_info "snapshot restored — cluster keyring now matches DR pack Shamir bundle. Unsealing with original keys."
else
  log_info "OpenBao already initialized — checking if sealed"
fi

# Unseal all 3 pods with original DR pack keys (snapshot put the original keyring back)
log_info "unsealing all 3 openbao pods with DR pack Shamir keys"
for pod in openbao-0 openbao-1 openbao-2; do
  for k in "$K0" "$K1" "$K2"; do
    kubectl -n openbao exec "$pod" -- bao operator unseal "$k" >/dev/null 2>&1 || true
  done
done

# Verify unsealed
wait_for "openbao-0 unsealed" \
  "kubectl -n openbao exec openbao-0 -- bao status -format=json 2>/dev/null | jq -re '.sealed == false'" \
  120

# Store keys in k8s Secrets for autounseal controller (handles future pod restarts)
log_info "creating openbao-keys + openbao-root-token Secrets"
kubectl -n openbao create secret generic openbao-keys \
  --from-literal=key-0="$K0" \
  --from-literal=key-1="$K1" \
  --from-literal=key-2="$K2" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n openbao create secret generic openbao-root-token \
  --from-literal=token="$VAULT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log_info "installing openbao-autounseal controller"
helm_apply openbao-autounseal pytoshka/vault-autounseal openbao \
  --version 0.5.3 \
  -f "$REPO_ROOT/argocd/infra/openbao-autounseal/values.yaml"

log_ok "phase 06 vault-restore complete — Vault holds every other secret now"
