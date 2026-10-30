#!/usr/bin/env bash
# Phase 04 — external-dns-openwrt, before Vault exists.
# OpenWrt creds come from the DR pack; label homelab.dr/bootstrap=true
# lets phase 10 delete them so ESO recreates them from OpenBao.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl
load_bootstrap_env

# OpenWrt only if OPENWRT_PASS is in the DR pack; router host and login come
# from the app's values in git, the chart reads only the password from the Secret.
if [ -n "${OPENWRT_PASS:-}" ]; then
  log_info "creating openwrt-credentials Secret"
  kubectl create ns external-dns-openwrt 2>/dev/null || true
  kubectl -n external-dns-openwrt create secret generic openwrt-credentials \
    --from-literal=password="$OPENWRT_PASS" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - homelab.dr/bootstrap=true -o yaml \
    | kubectl apply -f - >/dev/null

  OW_DIR="$REPO_ROOT/argocd/infra/external-dns-openwrt"
  OW_CHART="oci://$(yq -r '.repoURL' "$OW_DIR/config.yaml")/$(yq -r '.chart' "$OW_DIR/config.yaml")"
  log_info "installing external-dns-openwrt ($OW_CHART)"
  helm_apply external-dns-openwrt "$OW_CHART" external-dns-openwrt \
    --version "$(chart_version external-dns-openwrt)" \
    -f "$OW_DIR/values.yaml"
else
  log_warn "OPENWRT_PASS not in DR pack — skipping external-dns-openwrt (ArgoCD installs it after the OpenBao restore)"
fi

log_ok "phase 04 dns complete"
