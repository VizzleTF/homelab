#!/usr/bin/env bash
# Phase 09 — restore application data volumes from their VolSync restic
# repositories. Runs before ArgoCD (phase 10) on purpose: once root is applied,
# the apps AppSet creates every chart's PVC empty, and restore-app.sh refuses an
# existing PVC. Here the PVCs do not exist yet; ArgoCD adopts the restored ones
# on its first sync. Everything the restore needs (local-path, Longhorn, VolSync)
# comes from phase 02, the restic keys from the DR pack.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

# Every homelab-common.volsync[] volume in git (restore-app.sh --list). DBs come
# back through barman/pg_dump, not here; Forgejo lives on the ops node
# (obsidian/113 Backups/Forgejo Recovery.md). immich-library (250Gi) goes last.
RESTORE_SCRIPT="$(dirname "$0")/../restore-app.sh"
[ -x "$RESTORE_SCRIPT" ] || die "missing restore-app.sh"

mapfile -t VOLUMES < <("$RESTORE_SCRIPT" --list | awk 'NR > 1 { print $1 }' | grep -v '^immich-library$'; echo immich-library)
log_info "volumes to restore: ${VOLUMES[*]}"

for vol in "${VOLUMES[@]}"; do
  log_info "restoring volume: $vol"
  "$RESTORE_SCRIPT" "$vol" || log_warn "$vol restore failed — continuing"
done

log_ok "phase 09 apps-restore complete"
