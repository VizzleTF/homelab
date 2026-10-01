#!/usr/bin/env bash
# Phase 07 — External Secrets Operator + OpenBao roles for per-release SecretStores.
# Assumes phase 06 left Vault unsealed with the restored keyring (so all
# previously-populated paths are already present).

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/vault-helpers.sh
source "$(dirname "$0")/../lib/vault-helpers.sh"

require_kubectl
ensure_bao_token

helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null

# Ensure k8s auth method + SA + CRB + policy + role exist (idempotent).
log_info "ensuring auth-delegator ClusterRoleBinding for the openbao SA (TokenReview)"
kubectl create clusterrolebinding openbao-auth-delegator-openbao \
  --clusterrole=system:auth-delegator \
  --serviceaccount=openbao:openbao \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

bao_secrets_enable kv home -version=2
bao_auth_enable kubernetes kubernetes

log_info "configuring kubernetes auth (no token_reviewer_jwt — uses SA local JWT)"
bao_exec bao write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443 \
  disable_iss_validation=true >/dev/null

log_info "writing ESO policies + roles from global.openbao.access"
# Read-only, per namespace (scripts/openbao-eso-access.sh). The raft snapshot
# already carries them; re-running keeps a fresh mount (new accessor) correct.
BAO_CMD="kubectl -n $BAO_POD_NS exec -i $BAO_POD -- env BAO_TOKEN=$BAO_TOKEN BAO_ADDR=$BAO_ADDR_INTERNAL bao" \
  "$REPO_ROOT/scripts/openbao-eso-access.sh"

log_info "installing ESO"
helm_apply external-secrets external-secrets/external-secrets external-secrets-system \
  --version 2.5.0 \
  -f "$REPO_ROOT/argocd/infra/external-secrets/values.yaml" \
  --set serviceMonitor.enabled=false

wait_for "ESO webhook Ready" \
  "kubectl -n external-secrets-system rollout status deploy/external-secrets-webhook --timeout=180s"

# No store here: homelab-common renders one SecretStore per release, so stores
# appear with the apps once ArgoCD adopts them (phase 10).

log_ok "phase 07 eso complete — Vault → k8s Secret sync chain operational"
