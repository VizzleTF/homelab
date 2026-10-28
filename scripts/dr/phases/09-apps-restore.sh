#!/usr/bin/env bash
# Phase 09 — restore app data volumes from VolSync restic. Before ArgoCD on
# purpose: the apps AppSet would create every PVC empty, and restore-app.sh
# refuses an existing PVC; ArgoCD adopts the restored ones.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

# Every homelab-common.volsync[] volume (restore-app.sh --list). DBs come back
# via barman/pg_dump; Forgejo lives on the ops node (obsidian/113
# Backups/Forgejo Recovery.md). immich-library (250Gi) goes last.
RESTORE_SCRIPT="$(dirname "$0")/../restore-app.sh"
[ -x "$RESTORE_SCRIPT" ] || die "missing restore-app.sh"

mapfile -t VOLUMES < <("$RESTORE_SCRIPT" --list | awk 'NR > 1 { print $1 }' | grep -v '^immich-library$'; echo immich-library)
log_info "volumes to restore: ${VOLUMES[*]}"

for vol in "${VOLUMES[@]}"; do
  log_info "restoring volume: $vol"
  "$RESTORE_SCRIPT" "$vol" || log_warn "$vol restore failed — continuing"
done

log_ok "phase 09 apps-restore complete"
