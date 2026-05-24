#!/usr/bin/env bash
# Phase 04 — external-dns CF (in cert-manager ns) + external-dns-openwrt.
# OpenWrt creds come from DR pack pre-Vault.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl
load_bootstrap_env
require_env CF_API_TOKEN

helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null 2>&1 || true
helm repo update external-dns >/dev/null

log_info "creating external-dns-cloudflare Secret"
kubectl -n cert-manager create secret generic external-dns-cloudflare \
  --from-literal=api-token="$CF_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log_info "installing external-dns (Cloudflare)"
helm_apply external-dns external-dns/external-dns cert-manager \
  --version 1.21.1 \
  -f "$REPO_ROOT/argocd/infra/external-dns/values.yaml"

# OpenWrt instance — only if OPENWRT_HOST/USER/PASS are in DR pack
if [ -n "${OPENWRT_HOST:-}" ] && [ -n "${OPENWRT_USER:-}" ] && [ -n "${OPENWRT_PASS:-}" ]; then
  log_info "creating openwrt-credentials Secret"
  kubectl create ns external-dns-openwrt 2>/dev/null || true
  kubectl -n external-dns-openwrt create secret generic openwrt-credentials \
    --from-literal=host="$OPENWRT_HOST" \
    --from-literal=username="$OPENWRT_USER" \
    --from-literal=password="$OPENWRT_PASS" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  log_info "installing external-dns-openwrt"
  helm_apply external-dns-openwrt external-dns/external-dns external-dns-openwrt \
    --version 1.21.1 \
    -f "$REPO_ROOT/argocd/infra/external-dns-openwrt/values.yaml"
else
  log_warn "OPENWRT_* not in DR pack — skipping external-dns-openwrt (will be installed later via ESO after Vault restore)"
fi

log_ok "phase 04 dns complete"
