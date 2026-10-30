#!/usr/bin/env bash
# Copy the DR secrets from OpenBao into Vaultwarden, so they survive the cluster:
# OpenBao's restore needs the restic passwords that OpenBao itself holds.
# Values pass via env vars, never to the screen; only names and status print.
#
# Writes need bw: since Vaultwarden 1.37.4 (GHSA-7ccc-c43j-4p36) POST
# /api/ciphers requires `encryptedFor`; rbw 1.15.0 gets 422, so it only reads
# (default when unlocked; DR_CLIENT=bw forces bw). bw "Master password unlock
# data is required..." = stale state: `bw logout && bw login`.
#
# Usage, in your own terminal (bw unlock needs a TTY, so not under `!`):
#   DR_CLIENT=bw BW_SESSION=$(bw unlock --raw) scripts/dr-pack/to-bitwarden.sh [--dry-run]
# Env: BW_FOLDER (Infra / Homelab DR), BAO_MOUNT (home), BAO_PREFIX (homelab/k8s).

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

# Names continue items 01..07 in the same folder.
# 11: without SECRET_KEY a Forgejo DB restored on a new ops node cannot decrypt
# its Authentik client secret, 2FA and push-mirror passwords.
# 12: rclone-obscured crypt key of the OVH etcd/OpenBao snapshots, tfstate,
# pg_dump and router config (item name kept: renaming makes a duplicate)
# 13: VPS fleet restic-vps repos (Garage key + passwords; OVH key is item 09).
# (use as RCLONE_CONFIG_<remote>_PASSWORD{,2}; `rclone reveal` prints the plain one).
# Format: name | path:fields[,fields];path:fields
ITEMS='
08 - Restic repo passwords (backup v2)|shared/restic-garage:password;shared/restic-ovh:password
09 - S3 keys backup v2 (restic-apps, snapshots, OVH)|shared/s3-restic-apps:ACCESS_KEY_ID,ACCESS_SECRET_KEY;shared/s3-snapshots:ACCESS_KEY_ID,ACCESS_SECRET_KEY;shared/s3-ovh:ACCESS_KEY_ID,ACCESS_SECRET_KEY
10 - DR pack passphrase (off-site)|shared/dr-pack:passphrase
11 - Forgejo instance secrets|forgejo/instance-secrets:SECRET_KEY,INTERNAL_TOKEN,JWT_SECRET,LFS_JWT_SECRET,MINIO_ACCESS_KEY_ID,MINIO_SECRET_ACCESS_KEY
12 - OVH rclone crypt (snapshots, tfstate)|shared/ovh-crypt:password,password2
13 - VPS restic (restic-vps)|shared/s3-restic-vps:ACCESS_KEY_ID,ACCESS_SECRET_KEY;shared/restic-vps-garage:password;shared/restic-vps-ovh:password
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

  # Values stay in a variable for the client; never to stdout.
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

  # Line 1 = password field: a single value goes there for one-click copy;
  # otherwise everything is in the note.
  if [[ "$count" = "1" ]]; then first_line="$last_val"; else first_line="(see notes)"; fi

  if [[ "$DRY_RUN" = "1" ]]; then
    echo "  DRY  $name  <- $(echo "$spec" | tr ';' ' ')"
    return 0
  fi

  if [[ "$CLIENT" = "rbw" ]]; then
    # With non-interactive stdin rbw reads the payload from stdin (line 1 =
    # password, rest = note), not $EDITOR; a substituted EDITOR made an empty
    # item. Here-string, not a pipe: the calling loop owns its stdin.
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
# Here-string, not a pipe: rbw/bw consume stdin, and with a pipe rows after
# the first silently vanished (item 09 was never created).
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
