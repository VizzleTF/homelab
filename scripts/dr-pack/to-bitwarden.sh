#!/usr/bin/env bash
# scripts/dr-pack/to-bitwarden.sh: copy the DR secrets from OpenBao into
# Vaultwarden (bw CLI) so they are at hand when the cluster is gone.
#
# Why: recovery hits a loop. The restic passwords live in OpenBao, and OpenBao
# is restored from a backup encrypted with those same passwords. Two
# independent copies outside the cluster break the loop: the offline DR-pack
# and a Vaultwarden item (every client keeps its own copy).
#
# Secret values go from bao to bw through environment variables and never
# reach the screen: the script prints only item names and status.
#
# Two clients:
#   bw  - writes. Since Vaultwarden 1.37.4 only bw can: after the
#         GHSA-7ccc-c43j-4p36 fix the server requires the `encryptedFor` field
#         in POST /api/ciphers, which the official CLI sends. If `bw unlock`
#         answers "Master password unlock data is required is null or
#         undefined", the cached state is stale: `bw logout && bw login`.
#   rbw - read-only: rbw 1.15.0 does not send the field and gets 422 on add/edit.
#         It is the default when unlocked; DR_CLIENT=bw forces bw.
#
# Usage:
#   # in your own terminal, not under `!` in Claude Code: bw unlock needs a TTY
#   DR_CLIENT=bw BW_SESSION=$(bw unlock --raw) scripts/dr-pack/to-bitwarden.sh [--dry-run]
#
# Env:
#   BW_FOLDER   Vaultwarden folder name (default: Infra / Homelab DR)
#   BAO_MOUNT   OpenBao KV mount (default: home)
#   BAO_PREFIX  path prefix (default: homelab/k8s)
#   BW_SESSION  official CLI session (alternative to rbw)
#   DR_CLIENT   rbw | bw: pick the client explicitly (default rbw when unlocked)

set -euo pipefail
export BAO_ADDR="${BAO_ADDR:-https://openbao.example.com}"

DRY_RUN=0
[[ "${1:-}" = "--dry-run" ]] && DRY_RUN=1

BW_FOLDER="${BW_FOLDER:-Infra / Homelab DR}"
BAO_MOUNT="${BAO_MOUNT:-home}"
BAO_PREFIX="${BAO_PREFIX:-homelab/k8s}"

command -v bao >/dev/null 2>&1 || { echo "missing dependency: bao" >&2; exit 1; }

CLIENT=""
if [[ "$DRY_RUN" = "0" ]]; then
  if [[ "${DR_CLIENT:-}" != "bw" ]] && command -v rbw >/dev/null 2>&1 && rbw unlocked >/dev/null 2>&1; then
    CLIENT=rbw
    rbw sync >/dev/null 2>&1 || true
  elif [[ -n "${BW_SESSION:-}" ]] && command -v bw >/dev/null 2>&1; then
    CLIENT=bw
    command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq (нужен для bw)" >&2; exit 1; }
    bw sync --quiet 2>/dev/null || true
  else
    cat >&2 <<'MSG'
Нет сессии клиента. Запустите в своём терминале (bw unlock нужен TTY):

  DR_CLIENT=bw BW_SESSION=$(bw unlock --raw) scripts/dr-pack/to-bitwarden.sh

rbw с Vaultwarden 1.37.4+ записывать не может (422, нет encryptedFor).
"Master password unlock data is required" от bw лечится `bw logout && bw login`.
MSG
    exit 1
  fi
  echo "client: $CLIENT"
fi

# Names continue the numbering of the existing items 01..07 in the same folder.
# 11: without SECRET_KEY a Forgejo database restored on a new ops node cannot
# decrypt the Authentik client secret, 2FA and push-mirror passwords, and after
# a full cluster loss OpenBao itself is not up yet.
# Format: name | path:fields[,fields];path:fields
ITEMS='
08 - Restic repo passwords (backup v2)|shared/restic-garage:password;shared/restic-ovh:password
09 - S3 keys backup v2 (restic-apps, snapshots, OVH)|shared/s3-restic-apps:ACCESS_KEY_ID,ACCESS_SECRET_KEY;shared/s3-snapshots:ACCESS_KEY_ID,ACCESS_SECRET_KEY;shared/s3-ovh:ACCESS_KEY_ID,ACCESS_SECRET_KEY
10 - DR pack passphrase (off-site)|shared/dr-pack:passphrase
11 - Forgejo instance secrets|forgejo/instance-secrets:SECRET_KEY,INTERNAL_TOKEN,JWT_SECRET,LFS_JWT_SECRET,MINIO_ACCESS_KEY_ID,MINIO_SECRET_ACCESS_KEY
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

  # Values are read into a variable and handed to the client; never to stdout.
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

  # The first payload line becomes the password field. With a single value it
  # goes there so it copies with one click; otherwise everything is in the note.
  if [[ "$count" = "1" ]]; then first_line="$last_val"; else first_line="(see notes)"; fi

  if [[ "$DRY_RUN" = "1" ]]; then
    echo "  DRY  $name  <- $(echo "$spec" | tr ';' ' ')"
    return 0
  fi

  if [[ "$CLIENT" = "rbw" ]]; then
    # rbw's help promises $EDITOR, but with a non-interactive stdin no editor
    # starts at all: the payload is read straight from stdin (first line =
    # password, the rest = note). A substituted EDITOR silently created an
    # empty item. Here-string, not a pipe: the calling loop owns its stdin.
    local action=add
    if rbw get "$name" >/dev/null 2>&1; then action=edit; fi
    local err
    # rbw's stderr carries only the API error message, never values.
    if err=$(rbw "$action" --folder "$BW_FOLDER" "$name" <<< "$first_line
$notes" 2>&1 >/dev/null); then
      if [[ "$action" = "edit" ]]; then echo "  UPD  $name"; else echo "  NEW  $name"; fi
    else
      echo "  ERR  $name — rbw $action: ${err:-no message}"
      case "$err" in *422*) echo "       Vaultwarden 1.37.4+ отклоняет запись rbw (нет encryptedFor), см. шапку: DR_CLIENT=bw" ;; esac
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
# The loop reads a here-string, not a pipe: the clients (rbw, bw) take stdin
# for themselves, and with a pipe the second and later table rows simply
# vanished, so item 09 was silently never created.
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
