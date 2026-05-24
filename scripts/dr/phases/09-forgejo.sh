#!/usr/bin/env bash
# Phase 09 — restore Forgejo PVC from Velero and let ArgoCD (next phase) own
# the actual Forgejo Application. We only need the PVC + ServiceAccount in
# place so ArgoCD's Helm release can adopt them without prune/recreate cycles.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

kubectl create ns forgejo 2>/dev/null || true

LATEST_BACKUP=$(kubectl -n velero exec deploy/velero -- /velero backup get 2>/dev/null \
  | awk '/^forgejo-daily-/ && $2 == "Completed" {print $1}' \
  | sort | tail -1)

[ -n "$LATEST_BACKUP" ] || die "no Completed forgejo-daily backup found"
log_info "restoring PVC from $LATEST_BACKUP"

RESTORE_NAME="forgejo-data-restore-$(date +%s)"
kubectl -n velero exec deploy/velero -- /velero restore create "$RESTORE_NAME" \
  --from-backup "$LATEST_BACKUP" \
  --include-namespaces forgejo \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --wait

wait_for "forgejo-data PVC Bound" \
  "kubectl -n forgejo get pvc forgejo-data -o jsonpath='{.status.phase}' | grep -q Bound" \
  120

log_ok "phase 09 forgejo complete — PVC restored; ArgoCD will bring up the rest"
