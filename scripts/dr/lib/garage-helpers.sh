#!/usr/bin/env bash
# Garage CLI helpers (executes via SSH to the Synology NAS).

: "${GARAGE_SSH:=ivan@10.11.12.237}"
: "${GARAGE_CONFIG:=/volume4/garage/garage/garage.toml}"
: "${GARAGE_BIN:=/volume4/@appstore/garage/bin/garage}"

garage() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$GARAGE_SSH" \
    "sudo $GARAGE_BIN -c $GARAGE_CONFIG $(printf '%q ' "$@")"
}

# Return access key ID for a named key, empty if not found.
garage_key_id_by_name() {
  local key_name="$1"
  garage key list 2>/dev/null \
    | awk -v n="$key_name" '$2 == n {print $1}' \
    | head -1
}

# Rotate a Garage key: delete old by ID, create new with same name, grant
# read/write/owner on the bucket. Echoes "$ACCESS_ID $SECRET" on success.
garage_rotate_key() {
  local bucket="$1" key_name="$2"
  local old_id; old_id=$(garage_key_id_by_name "$key_name")
  if [ -n "$old_id" ]; then
    log_info "deleting old Garage key $key_name ($old_id)"
    garage key delete --yes "$old_id" >/dev/null
  fi
  log_info "creating Garage key $key_name"
  local out; out=$(garage key create "$key_name")
  local new_id new_secret
  new_id=$(echo "$out" | awk '/^Key ID/ {print $NF}')
  new_secret=$(echo "$out" | awk '/^Secret key/ {print $NF}')
  [ -n "$new_id" ] && [ -n "$new_secret" ] || die "Garage key create failed"
  garage bucket allow --key "$key_name" --read --write --owner "$bucket" >/dev/null
  printf '%s %s\n' "$new_id" "$new_secret"
}

# Verify a Garage key still works against the bucket. Returns 0 on success.
garage_key_works() {
  local access_id="$1" secret="$2" bucket="$3"
  AWS_ACCESS_KEY_ID="$access_id" \
  AWS_SECRET_ACCESS_KEY="$secret" \
  AWS_DEFAULT_REGION=garage \
  aws --endpoint-url https://s3.example.com s3api head-bucket --bucket "$bucket" \
    >/dev/null 2>&1
}
