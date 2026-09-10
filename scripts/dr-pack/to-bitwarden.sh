#!/usr/bin/env bash
# scripts/dr-pack/to-bitwarden.sh — переложить DR-секреты из OpenBao в
# Vaultwarden (bw CLI), чтобы они были доступны, когда кластера нет.
#
# Зачем: восстановление упирается в замкнутый круг — пароли restic лежат в
# OpenBao, а OpenBao восстанавливается из бэкапа, зашифрованного этими же
# паролями. Круг разрывают две независимые копии вне кластера: офлайн DR-pack
# и запись в Vaultwarden (у него собственная копия на каждом клиенте).
#
# Значения секретов передаются из bao в bw через переменные окружения и на
# экран не выводятся: скрипт печатает только имена записей и статус.
#
# Два клиента, выбор автоматический:
#   rbw — предпочтительный. Официальный bw CLI 2026.8 не открывает хранилище
#         Vaultwarden 1.37.2: падает с "Master password unlock data is required
#         is null or undefined" (клиент ждёт поля новой схемы, сервер их не
#         отдаёт). rbw — независимая реализация, этой зависимости не имеет.
#   bw  — используется, если задан BW_SESSION и rbw заблокирован.
#
# Usage:
#   rbw login && rbw unlock          # мастер-пароль вводите сами, в своём терминале
#   scripts/dr-pack/to-bitwarden.sh [--dry-run]
#
# Env:
#   BW_FOLDER   имя папки в Vaultwarden (default: HomeLab DR)
#   BAO_MOUNT   KV-mount OpenBao (default: home)
#   BAO_PREFIX  префикс путей (default: homelab/k8s)
#   BW_SESSION  сессия официального CLI (альтернатива rbw)

set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

BW_FOLDER="${BW_FOLDER:-HomeLab DR}"
BAO_MOUNT="${BAO_MOUNT:-home}"
BAO_PREFIX="${BAO_PREFIX:-homelab/k8s}"

command -v bao >/dev/null 2>&1 || { echo "missing dependency: bao" >&2; exit 1; }

CLIENT=""
if [ "$DRY_RUN" = "0" ]; then
  if command -v rbw >/dev/null 2>&1 && rbw unlocked >/dev/null 2>&1; then
    CLIENT=rbw
    rbw sync >/dev/null 2>&1 || true
  elif [ -n "${BW_SESSION:-}" ] && command -v bw >/dev/null 2>&1; then
    CLIENT=bw
    command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq (нужен для bw)" >&2; exit 1; }
    bw sync --quiet 2>/dev/null || true
  else
    cat >&2 <<'MSG'
Хранилище заблокировано. Разблокируйте сами, в своём терминале:

  rbw login && rbw unlock          # предпочтительно
  # или, если пользуетесь официальным CLI:
  export BW_SESSION=$(bw unlock --raw)

Затем запустите скрипт снова. Мастер-пароль через автоматику не проходит.
MSG
    exit 1
  fi
  echo "client: $CLIENT"
fi

# name | vault path | поля через запятую
ITEMS='
restic repository password (Garage on-prem)|shared/restic-garage|password
restic repository password (OVH off-site)|shared/restic-ovh|password
S3 key — Garage bucket restic-apps|shared/s3-restic-apps|ACCESS_KEY_ID,ACCESS_SECRET_KEY
S3 key — Garage bucket snapshots|shared/s3-snapshots|ACCESS_KEY_ID,ACCESS_SECRET_KEY
S3 key — OVH vaka-homelab|velero/s3-ovh|ACCESS_KEY_ID,ACCESS_SECRET_KEY
'

folder_id=""
if [ "$DRY_RUN" = "0" ] && [ "$CLIENT" = "bw" ]; then
  folder_id=$(bw list folders --search "$BW_FOLDER" 2>/dev/null \
    | jq -r --arg n "$BW_FOLDER" '.[] | select(.name == $n) | .id' | head -1)
  if [ -z "$folder_id" ]; then
    echo "creating folder: $BW_FOLDER"
    folder_id=$(jq -nc --arg n "$BW_FOLDER" '{name: $n}' | bw encode | bw create folder | jq -r .id)
  fi
fi

upsert() {
  local name="$1" path="$2" fields="$3"
  local notes="" f val

  # Значения читаются в переменную и уходят в bw; на stdout не попадают.
  for f in $(echo "$fields" | tr ',' ' '); do
    val=$(bao kv get -mount="$BAO_MOUNT" -field="$f" "$BAO_PREFIX/$path" 2>/dev/null) || {
      echo "  SKIP $name — нет $BAO_MOUNT/$BAO_PREFIX/$path:$f"
      return 0
    }
    notes="${notes}${f}=${val}"$'\n'
  done

  if [ "$DRY_RUN" = "1" ]; then
    echo "  DRY  $name  <- $BAO_MOUNT/$BAO_PREFIX/$path ($fields)"
    return 0
  fi

  local existing_id
  existing_id=$(bw list items --search "$name" 2>/dev/null \
    | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1)

  local payload
  payload=$(jq -nc --arg n "$name" --arg notes "$notes" --arg fid "$folder_id" \
    '{organizationId:null, folderId:$fid, type:2, name:$n, notes:$notes, secureNote:{type:0}}')

  if [ -n "$existing_id" ]; then
    printf '%s' "$payload" | bw encode | bw edit item "$existing_id" >/dev/null
    echo "  UPD  $name"
  else
    printf '%s' "$payload" | bw encode | bw create item >/dev/null
    echo "  NEW  $name"
  fi
}

echo "=== DR secrets -> Vaultwarden (folder: $BW_FOLDER) ==="
echo "$ITEMS" | while IFS='|' read -r name path fields; do
  [ -z "$name" ] && continue
  upsert "$name" "$path" "$fields"
done

cat <<'NOTE'

Отдельно, руками (эти вещи не живут в OpenBao):
  - Shamir-ключи OpenBao и root token — в DR-pack 00-shamir.json.gpg;
    в Vaultwarden кладите их только как отдельную запись, если хотите
    вторую копию вне GPG-файла.
  - Парольная фраза GPG от DR-pack — она не должна лежать там же, где пакет.
NOTE
