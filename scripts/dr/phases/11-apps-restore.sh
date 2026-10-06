#!/usr/bin/env bash
# Phase 11 — restore application data volumes from their VolSync restic
# repositories. ArgoCD already owns the Application/Helm release; we only feed
# the old data back into freshly created PVCs.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

# Apps with restorable data backups. Ключи таблицы в restore-app.sh. БД
# приезжают через barman/pg_dump, не сюда. Forgejo живёт на ops-ноде и
# восстанавливается отдельно (obsidian/113 Backups/Forgejo Recovery.md). netbird и crowdsec-scraper
# намеренно отсутствуют: их PVC пусты — state пира лежит вне тома
# (/var/lib/netbird), это известная дыра, а не потеря бэкапа.
APPS_TO_RESTORE=(
  vaultwarden
  cleanbot
  may
  rsstt
  opencloud-config
  opencloud
  trek-data
  trek
  obsidian-livesync
  immich
  wazuh-manager
)

RESTORE_SCRIPT="$(dirname "$0")/../restore-app.sh"
[ -x "$RESTORE_SCRIPT" ] || die "missing restore-app.sh"

for app in "${APPS_TO_RESTORE[@]}"; do
  log_info "restoring app: $app"
  "$RESTORE_SCRIPT" "$app" || log_warn "$app restore failed — continuing"
done

log_ok "phase 11 apps-restore complete"
