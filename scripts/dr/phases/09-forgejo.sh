#!/usr/bin/env bash
# Phase 09 — restore the Forgejo PVC from its VolSync restic repository and
# let ArgoCD (next phase) own
# the actual Forgejo Application. We only need the PVC + ServiceAccount in
# place so ArgoCD's Helm release can adopt them without prune/recreate cycles.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

kubectl create ns forgejo 2>/dev/null || true

# shellcheck source=../lib/volsync-restore.sh
source "$(dirname "$0")/../lib/volsync-restore.sh"
load_bootstrap_env

# forgejo-data: git-репозитории, LFS и conf. Владелец файлов — uid 1000.
volsync_restore forgejo forgejo forgejo-data 20Gi ReadWriteOnce 1000

wait_for "forgejo-data PVC Bound"   "kubectl -n forgejo get pvc forgejo-data -o jsonpath='{.status.phase}' | grep -q Bound"   120

log_ok "phase 09 forgejo complete — PVC restored; ArgoCD will bring up the rest"
