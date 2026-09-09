#!/usr/bin/env bash
# Phase 11 — restore application data volumes from their VolSync restic
# repositories. ArgoCD already owns the Application/Helm release; we only feed
# the old data back into freshly created PVCs.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

# Apps with restorable data backups (excludes the ones already handled in
# phase 09, plus CNPG-backed apps whose data comes via barman recovery).
# Ключи таблицы в restore-app.sh. forgejo уже восстановлен в фазе 09; БД
# приезжают через barman/pg_dump, не сюда. netbird и crowdsec-scraper
# намеренно отсутствуют: их PVC пусты — state пира лежит вне тома
# (/var/lib/netbird), это известная дыра, а не потеря бэкапа.
APPS_TO_RESTORE=(
  vaultwarden
  nextcloud
  cleanbot
  may
  omniroute
  rsstt
  opencloud-config
  opencloud
  trek-data
  trek
  obsidian-livesync
  immich
)

RESTORE_SCRIPT="$(dirname "$0")/../restore-app.sh"
[ -x "$RESTORE_SCRIPT" ] || die "missing restore-app.sh"

for app in "${APPS_TO_RESTORE[@]}"; do
  log_info "restoring app: $app"
  "$RESTORE_SCRIPT" "$app" || log_warn "$app restore failed — continuing"
done

log_ok "phase 11 apps-restore complete"
