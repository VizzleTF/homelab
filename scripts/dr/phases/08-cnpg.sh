#!/usr/bin/env bash
# Phase 08 — CNPG operator. Cluster CRs themselves come up via ArgoCD in
# phase 10, since ESO is now able to resolve every secret they need.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null

log_info "installing CNPG operator"
helm_apply cnpg-operator cnpg/cloudnative-pg cnpg-system \
  --version 0.28.2

wait_for "CNPG operator Ready" \
  "kubectl -n cnpg-system rollout status deploy/cnpg-operator-cloudnative-pg --timeout=180s"

log_ok "phase 08 cnpg complete (operator only — Cluster CRs created by ArgoCD)"
