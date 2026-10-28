#!/usr/bin/env bash
# Phase 02 — local-path-provisioner + Longhorn + snapshot-controller + BackupTarget
# + VolSync.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo add piraeus https://piraeus.io/helm-charts/ >/dev/null 2>&1 || true
helm repo add containeroo https://charts.containeroo.ch >/dev/null 2>&1 || true
helm repo update longhorn piraeus containeroo >/dev/null

# local-path first: OpenBao (phase 06) and every VolSync restic cache (phase 09)
# bind to StorageClass local-path; without it their PVCs stay Pending.
log_info "installing local-path-provisioner"
helm_apply local-path-provisioner containeroo/local-path-provisioner local-path-provisioner \
  --version "$(chart_version local-path-provisioner)" \
  -f "$REPO_ROOT/argocd/infra/local-path-provisioner/values.yaml"

kubectl create ns longhorn-system 2>/dev/null || true

log_info "installing Longhorn"
helm_apply longhorn longhorn/longhorn longhorn-system \
  --version "$(chart_version longhorn)" \
  -f "$REPO_ROOT/argocd/infra/longhorn/values.yaml"

wait_for "longhorn-manager DS Ready" \
  "kubectl -n longhorn-system rollout status ds/longhorn-manager --timeout=300s"

# Release name = ArgoCD Application name, so ArgoCD adopts these objects
# instead of running a second snapshot-controller.
log_info "installing snapshot-controller"
helm_apply snapshot-controller piraeus/snapshot-controller snapshot-controller \
  --version "$(chart_version snapshot-controller)" \
  -f "$REPO_ROOT/argocd/infra/snapshot-controller/values.yaml"

# Explicit list: the directory also holds VMRule/VMServiceScrape, whose CRDs
# arrive only with the VictoriaMetrics stack in phase 10.
log_info "applying Longhorn extras (BackupTarget, RecurringJobs, network policies)"
longhorn_manifests="$REPO_ROOT/argocd/infra/longhorn/manifests"
kubectl apply \
  -f "$longhorn_manifests/longhorn-backuptarget.yaml" \
  -f "$longhorn_manifests/recurringjob-snapshot-cleanup.yaml" \
  -f "$longhorn_manifests/recurringjob-trim.yaml" \
  -f "$longhorn_manifests/networkpolicy-allow-monitoring.yaml" \
  -f "$longhorn_manifests/networkpolicy-ui.yaml"

log_info "applying VolumeSnapshotClass for VolSync (driver.longhorn.io)"
kubectl apply -f "$REPO_ROOT/argocd/infra/volsync/manifests/volumesnapshotclass.yaml"

# VolSync now, not via ArgoCD (phase 10): phase 09 needs its CRDs, else
# "no matches for kind ReplicationDestination". ArgoCD adopts the release later.
log_info "installing VolSync (needed by phase 09)"
helm repo add backube https://backube.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update backube >/dev/null
helm_apply volsync backube/volsync volsync-system \
  --version "$(chart_version volsync)" \
  -f "$REPO_ROOT/argocd/infra/volsync/values.yaml"

wait_for "VolSync CRDs registered" \
  "kubectl get crd replicationdestinations.volsync.backube >/dev/null 2>&1" \
  120
wait_for "volsync deployment Ready" \
  "kubectl -n volsync-system rollout status deploy/volsync --timeout=180s"

log_ok "phase 02 storage complete"
