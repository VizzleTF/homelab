#!/usr/bin/env bash
# Phase 07 — External Secrets Operator + ClusterSecretStore.
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
log_info "ensuring openbao-auth ServiceAccount + ClusterRoleBinding"
kubectl -n openbao create sa openbao-auth --dry-run=client -o yaml | kubectl apply -f - >/dev/null
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

log_info "writing homelab-universal policy"
kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$VAULT_TOKEN" BAO_ADDR="$BAO_ADDR_INTERNAL" \
  bao policy write homelab-universal - <<'EOF' >/dev/null
path "home/*" {
  capabilities = ["create","read","update","delete","list"]
}
path "sys/leases/renew" { capabilities = ["update"] }
path "auth/token/renew-self" { capabilities = ["update"] }
EOF

log_info "writing homelab-universal role (any SA, any ns)"
bao_exec bao write auth/kubernetes/role/homelab-universal \
  'bound_service_account_names=*' \
  'bound_service_account_namespaces=*' \
  token_policies=homelab-universal \
  token_ttl=1h \
  alias_name_source=serviceaccount_uid >/dev/null

log_info "installing ESO"
helm_apply external-secrets external-secrets/external-secrets external-secrets-system \
  --version 2.5.0 \
  -f "$REPO_ROOT/argocd/infra/external-secrets/values.yaml" \
  --set serviceMonitor.enabled=false

wait_for "ESO webhook Ready" \
  "kubectl -n external-secrets-system rollout status deploy/external-secrets-webhook --timeout=180s"

log_info "applying ClusterSecretStore openbao-backend-cluster"
kubectl apply -f "$REPO_ROOT/argocd/infra/openbao/manifests/openbao-backend-cluster.yaml"

wait_for "ClusterSecretStore Ready" \
  "kubectl get clustersecretstore openbao-backend-cluster -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
  60

log_ok "phase 07 eso complete — Vault → k8s Secret sync chain operational"
