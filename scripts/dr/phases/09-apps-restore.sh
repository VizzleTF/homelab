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

# "name namespace pvc" rows; no mapfile, macOS ships bash 3.2.
VOLUMES=$("$RESTORE_SCRIPT" --list | awk 'NR > 1 {
  r = $1 " " $2 " " $3; if ($1 == "immich-library") last = r; else print r
} END { if (last != "") print last }')
[ -n "$VOLUMES" ] || die "restore-app.sh --list returned no volumes"
log_info "volumes to restore: $(awk '{ print $1 }' <<<"$VOLUMES" | tr '\n' ' ')"

# A failed restore stops the phase: phase 10 would start the app on an empty PVC.
# On a rerun, a PVC without its dr-<name> ReplicationDestination was restored
# earlier (cleaned up on success); one with it failed and is retried in place.
FAILED=()
# fd 3: restore-app.sh and kubectl must not eat the list on stdin.
while read -r vol ns pvc <&3; do
  force=0
  if kubectl -n "$ns" get pvc "$pvc" >/dev/null 2>&1; then
    if ! kubectl -n "$ns" get replicationdestination "dr-$vol" >/dev/null 2>&1; then
      log_skip "$vol: $ns/$pvc already restored"
      continue
    fi
    force=1
  fi
  log_info "restoring volume: $vol"
  DR_FORCE=$force "$RESTORE_SCRIPT" "$vol" || { log_error "$vol restore failed"; FAILED+=("$vol"); }
done 3<<<"$VOLUMES"

[ ${#FAILED[@]} -eq 0 ] || die "restore failed for: ${FAILED[*]} — fix and rerun phase 09 before phase 10"

log_ok "phase 09 apps-restore complete"
