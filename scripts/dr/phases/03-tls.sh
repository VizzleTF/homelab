#!/usr/bin/env bash
# Phase 03 — cert-manager + Cloudflare ClusterIssuer + wildcard cert.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl
load_bootstrap_env
require_env CF_API_TOKEN

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null

log_info "installing cert-manager"
helm_apply cert-manager jetstack/cert-manager cert-manager \
  --version v1.20.2 \
  -f "$REPO_ROOT/argocd/infra/cert-manager/values.yaml"

# CF token Secret — applied directly (ESO not up yet)
log_info "creating cloudflare-api-token Secret"
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token="$CF_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log_info "applying ClusterIssuer"
kubectl apply -f "$REPO_ROOT/argocd/infra/cert-manager/manifests/CloudFlare_ClusterIssuer.yaml"

wait_for "cloudflare-issuer Ready" \
  "kubectl get clusterissuer cloudflare-issuer -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
  120

log_info "requesting wildcard-tls Certificate (Let's Encrypt DNS-01)"
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-tls
  namespace: kube-system
spec:
  secretName: wildcard-tls
  issuerRef: {name: cloudflare-issuer, kind: ClusterIssuer}
  dnsNames:
    - "*.example.com"
    - "example.com"
    - "*.internal.example"
    - "internal.example"
EOF

wait_for "wildcard-tls Certificate Ready" \
  "kubectl -n kube-system get cert wildcard-tls -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
  300

log_ok "phase 03 tls complete"
