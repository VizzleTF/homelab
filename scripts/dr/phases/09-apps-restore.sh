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

log_ok "phase 09 apps-restore complete"
