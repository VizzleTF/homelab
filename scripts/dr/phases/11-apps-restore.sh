#!/usr/bin/env bash
# Phase 11 — restore application data PVCs from Velero. ArgoCD already owns
# the Application/Helm release, we just feed it back its old data.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

# Apps with restorable data backups (excludes the ones already handled in
# phase 09, plus CNPG-backed apps whose data comes via barman recovery).
APPS_TO_RESTORE=(
  vaultwarden
  nextcloud
  cleanbot
  may
  omniroute
  rsstt
  immich
)

RESTORE_SCRIPT="$(dirname "$0")/../restore-app.sh"
[ -x "$RESTORE_SCRIPT" ] || die "missing restore-app.sh"

for app in "${APPS_TO_RESTORE[@]}"; do
  log_info "restoring app: $app"
  "$RESTORE_SCRIPT" "$app" || log_warn "$app restore failed — continuing"
done

log_ok "phase 11 apps-restore complete"
