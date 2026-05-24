#!/usr/bin/env bash
# Phase 02 — Longhorn + snapshot-controller + BackupTarget + extra StorageClass.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo add piraeus https://piraeus.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update longhorn piraeus >/dev/null

kubectl create ns longhorn-system 2>/dev/null || true
kubectl label ns longhorn-system pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null

log_info "installing Longhorn"
helm_apply longhorn longhorn/longhorn longhorn-system \
  --version 1.11.2 \
  -f "$REPO_ROOT/argocd/infra/longhorn/values.yaml"

wait_for "longhorn-manager DS Ready" \
  "kubectl -n longhorn-system rollout status ds/longhorn-manager --timeout=300s"

log_info "installing snapshot-controller"
helm_apply snapshot-controller piraeus/snapshot-controller csi-snapshotter \
  --version 5.0.4 \
  -f "$REPO_ROOT/argocd/infra/csi-snapshotter/values.yaml"

log_info "applying Longhorn extras (default BackupTarget + longhorn-retain SC)"
kubectl apply -f "$REPO_ROOT/argocd/infra/longhorn/manifests/"

log_info "applying VolumeSnapshotClass for Velero (driver.longhorn.io)"
kubectl apply -f "$REPO_ROOT/argocd/infra/velero/manifests/volume-snapshot-class.yaml"

log_ok "phase 02 storage complete"
