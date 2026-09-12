#!/usr/bin/env bash
# scripts/dr/restore-app.sh — восстановить данные одного приложения из
# restic-репозитория VolSync.
#
# Заменил velero-версию (2026-09-09). Отличия, которые стоит знать:
#   - восстанавливается ТОМ, а не набор объектов: ни pod, ни SA, ни namespace
#     из бэкапа не приезжают — форму создаёт ArgoCD из git;
#   - namespace больше не переводится в pod-security privileged и ноды не
#     лейблятся как worker: mover VolSync работает без этих послаблений
#     (старый скрипт оставлял кластер ослабленным после каждого восстановления);
#   - источник выбирается через DR_RESTIC_TARGET=garage|ovh.
#
# Usage: scripts/dr/restore-app.sh <app> [repo] [pvc] [size] [accessMode] [uid]
# Без аргументов сверх <app> берёт значения из таблицы ниже.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/volsync-restore.sh
source "$(dirname "$0")/lib/volsync-restore.sh"

APP="${1:-}"
[[ -n "$APP" ]] || die "usage: $0 <app> [repo] [pvc] [size] [accessMode] [uid]"

require_kubectl
load_bootstrap_env

# app -> repo | pvc | size | accessMode | uid (uid пустой = mover от root)
lookup() {
  case "$1" in
    vaultwarden)        echo "vaultwarden|vaultwarden-data-vaultwarden-0|2Gi|ReadWriteOnce|1001" ;;
    nextcloud)          echo "nextcloud|nextcloud-nextcloud|10Gi|ReadWriteOnce|" ;;
    cleanbot)           echo "cleanbot|cleanbot|1Gi|ReadWriteOnce|10001" ;;
    may)                echo "may|may|5Gi|ReadWriteOnce|1000" ;;
    omniroute)          echo "omniroute-data|omniroute-data|5Gi|ReadWriteOnce|1000" ;;
    rsstt)              echo "rss-to-telegram-bot|rss-to-telegram-bot|1Gi|ReadWriteOnce|1000" ;;
    immich)             echo "immich-library|immich-library-pvc|250Gi|ReadWriteMany|" ;;
    forgejo)            echo "forgejo|forgejo-data|20Gi|ReadWriteOnce|" ;;
    opencloud)          echo "opencloud-data|opencloud-data|50Gi|ReadWriteOnce|" ;;
    opencloud-config)   echo "opencloud-config|opencloud-config|1Gi|ReadWriteOnce|" ;;
    trek)               echo "trek-uploads|trek-uploads|10Gi|ReadWriteOnce|" ;;
    trek-data)          echo "trek-data|trek-data|1Gi|ReadWriteOnce|" ;;
    obsidian-livesync)  echo "obsidian-livesync|database-storage-obsidian-livesync-couchdb-0|5Gi|ReadWriteOnce|" ;;
    *) return 1 ;;
  esac
}

if [[ -n "${2:-}" ]]; then
  REPO="$2"; PVC="${3:?pvc required}"; SIZE="${4:?size required}"
  MODE="${5:-ReadWriteOnce}"; UID_="${6:-}"
else
  ROW=$(lookup "$APP") || die "unknown app '$APP' — pass repo/pvc/size explicitly"
  IFS='|' read -r REPO PVC SIZE MODE UID_ <<<"$ROW"
fi

# Namespace приложения совпадает с именем папки в argocd/apps, кроме rsstt.
NS="$APP"
case "$APP" in
  rsstt) NS="rsstt" ;;
  opencloud-config) NS="opencloud" ;;
  trek-data) NS="trek" ;;
  *) ;;  # every other app lives in a namespace named after it
esac

# Защита от запуска на живом кластере: скрипт создаёт PVC с продовым именем в
# продовом namespace и наливает в него данные из репозитория. На пустом кластере
# это ровно то, что нужно; на работающем — перезапись тома под живым подом.
if kubectl -n "$NS" get pvc "$PVC" >/dev/null 2>&1 && [[ "${DR_FORCE:-0}" != "1" ]]; then
  MOUNTED=$(kubectl -n "$NS" get pods -o json 2>/dev/null \
    | grep -c "\"claimName\": *\"$PVC\"" || true)
  die "PVC $NS/$PVC уже существует (подов, использующих его: $MOUNTED).
  Этот скрипт предназначен для восстановления на чистый кластер.
  Чтобы восстановить том поверх существующего — остановите потребителей и
  запустите с DR_FORCE=1, либо восстанавливайте в отдельный namespace вручную
  через lib/volsync-restore.sh."
fi

volsync_restore "$NS" "$REPO" "$PVC" "$SIZE" "$MODE" "$UID_"

# Post-fix'ы, пережившие смену механизма: они про состояние приложения, а не
# про бэкап.
case "$APP" in
  nextcloud)
    log_info "fix: config.php dbpassword должен совпасть с ESO Secret"
    PODN=$(kubectl -n nextcloud get pod -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$PODN" ]]; then
      kubectl -n nextcloud exec "$PODN" -- bash -c '
        sed -i "s/'\''dbpassword'\'' =>.*$/'\''dbpassword'\'' => '\''$POSTGRES_PASSWORD'\'',/" /var/www/html/config/config.php
      ' || log_warn "nextcloud sed-fix failed"
      kubectl -n nextcloud delete pod "$PODN" --force --grace-period=0 >/dev/null 2>&1 || true
    fi
    ;;
  immich)
    log_info "fix: REASSIGN OWNED, если в БД остался старый owner immich_user"
    kubectl -n immich exec immich-cluster-1 -c postgres -- psql -U postgres -d immich \
      -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='immich_user') THEN
          EXECUTE 'REASSIGN OWNED BY immich_user TO immich';
          EXECUTE 'ALTER DATABASE immich OWNER TO immich';
        END IF; END \$\$;" 2>&1 | tail -3 || log_warn "immich REASSIGN skipped"
    ;;
  forgejo)
    log_info "fix: forgejo-init email на неконфликтующий"
    SCRIPT=$(kubectl -n forgejo get secret forgejo-init -o jsonpath='{.data.configure_gitea\.sh}' 2>/dev/null | base64 -d \
      | sed 's|gitea@local\.domain|argocd-temp@example.com|g' | base64 -w0)
    if [[ -n "$SCRIPT" ]]; then
      kubectl -n forgejo patch secret forgejo-init --type=json \
        -p="[{\"op\":\"replace\",\"path\":\"/data/configure_gitea.sh\",\"value\":\"$SCRIPT\"}]" >/dev/null || true
    fi
    ;;
esac

log_ok "restore-app $APP complete"
