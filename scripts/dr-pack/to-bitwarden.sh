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
[[ "${1:-}" = "--dry-run" ]] && DRY_RUN=1

BW_FOLDER="${BW_FOLDER:-Infra / Homelab DR}"
BAO_MOUNT="${BAO_MOUNT:-home}"
BAO_PREFIX="${BAO_PREFIX:-homelab/k8s}"

command -v bao >/dev/null 2>&1 || { echo "missing dependency: bao" >&2; exit 1; }

CLIENT=""
if [[ "$DRY_RUN" = "0" ]]; then
  if command -v rbw >/dev/null 2>&1 && rbw unlocked >/dev/null 2>&1; then
    CLIENT=rbw
    rbw sync >/dev/null 2>&1 || true
  elif [[ -n "${BW_SESSION:-}" ]] && command -v bw >/dev/null 2>&1; then
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

# Имена продолжают нумерацию существующих записей 01..07 в той же папке.
# Формат: имя | путь:поля[,поля];путь:поля
ITEMS='
08 - Restic repo passwords (backup v2)|shared/restic-garage:password;shared/restic-ovh:password
09 - S3 keys backup v2 (restic-apps, snapshots, OVH)|shared/s3-restic-apps:ACCESS_KEY_ID,ACCESS_SECRET_KEY;shared/s3-snapshots:ACCESS_KEY_ID,ACCESS_SECRET_KEY;velero/s3-ovh:ACCESS_KEY_ID,ACCESS_SECRET_KEY
10 - DR pack passphrase (off-site)|shared/dr-pack:passphrase
'

folder_id=""
if [[ "$DRY_RUN" = "0" ]] && [[ "$CLIENT" = "bw" ]]; then
  folder_id=$(bw list folders --search "$BW_FOLDER" 2>/dev/null \
    | jq -r --arg n "$BW_FOLDER" '.[] | select(.name == $n) | .id' | head -1)
  if [[ -z "$folder_id" ]]; then
    echo "creating folder: $BW_FOLDER"
    folder_id=$(jq -nc --arg n "$BW_FOLDER" '{name: $n}' | bw encode | bw create folder | jq -r .id)
  fi
fi

upsert() {
  local name="$1" spec="$2"
  local notes entry path fields f val missing=0 count=0 last_val="" first_line
  notes="# заполняется scripts/dr-pack/to-bitwarden.sh из OpenBao
"

  # Значения читаются в переменную и уходят в клиент; на stdout не попадают.
  for entry in $(echo "$spec" | tr ';' ' '); do
    path="${entry%%:*}"; fields="${entry#*:}"
    notes="${notes}
[$BAO_MOUNT/$BAO_PREFIX/$path]
"
    for f in $(echo "$fields" | tr ',' ' '); do
      val=$(bao kv get -mount="$BAO_MOUNT" -field="$f" "$BAO_PREFIX/$path" </dev/null 2>/dev/null) || {
        echo "  SKIP $name — нет $BAO_MOUNT/$BAO_PREFIX/$path:$f"
        missing=1
        break 2
      }
      notes="${notes}${f}=${val}
"
      count=$((count + 1))
      last_val="$val"
    done
  done
  if [[ "$missing" = "1" ]]; then return 0; fi

  # Первая строка payload'а становится полем «пароль». Если значение одно —
  # кладём его туда, чтобы копировалось одним нажатием; иначе всё в заметке.
  if [[ "$count" = "1" ]]; then first_line="$last_val"; else first_line="(see notes)"; fi

  if [[ "$DRY_RUN" = "1" ]]; then
    echo "  DRY  $name  <- $(echo "$spec" | tr ';' ' ')"
    return 0
  fi

  if [[ "$CLIENT" = "rbw" ]]; then
    # Справка rbw обещает $EDITOR, но при неинтерактивном stdin редактор не
    # запускается вовсе — payload читается прямо со stdin (первая строка =
    # пароль, остальное = заметка). Через подменённый EDITOR запись молча
    # создавалась пустой. Here-string, а не пайп: у цикла вызова свой stdin.
    local action=add
    if rbw get "$name" >/dev/null 2>&1; then action=edit; fi
    if rbw "$action" --folder "$BW_FOLDER" "$name" <<< "$first_line
$notes" >/dev/null 2>&1; then
      if [[ "$action" = "edit" ]]; then echo "  UPD  $name"; else echo "  NEW  $name"; fi
    else
      echo "  ERR  $name — rbw $action не отработал"
    fi
    return 0
  fi

  local existing_id
  existing_id=$(bw list items --search "$name" 2>/dev/null \
    | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1)

  local payload
  payload=$(jq -nc --arg n "$name" --arg notes "$notes" --arg fid "$folder_id" \
    '{organizationId:null, folderId:$fid, type:2, name:$n, notes:$notes, secureNote:{type:0}}')

  if [[ -n "$existing_id" ]]; then
    printf '%s' "$payload" | bw encode | bw edit item "$existing_id" >/dev/null 2>&1
    echo "  UPD  $name"
  else
    printf '%s' "$payload" | bw encode | bw create item >/dev/null
    echo "  NEW  $name"
  fi
}

echo "=== DR secrets -> Vaultwarden (folder: $BW_FOLDER) ==="
# Цикл читает из here-string, а не из пайпа: клиенты (rbw, bw) забирают stdin
# себе, и при чтении из пайпа вторая и последующие строки таблицы просто
# исчезали — запись 09 молча не создавалась.
while IFS='|' read -r name spec; do
  if [[ -z "$name" ]]; then continue; fi
  upsert "$name" "$spec"
done <<< "$ITEMS"

cat <<'NOTE'

Отдельно, руками (эти вещи не живут в OpenBao):
  - Shamir-ключи OpenBao и root token — в DR-pack 00-shamir.json.gpg;
    в Vaultwarden кладите их только как отдельную запись, если хотите
    вторую копию вне GPG-файла.
  - Парольная фраза GPG от DR-pack — она не должна лежать там же, где пакет.
NOTE
