#!/usr/bin/env bash
# Provision Garage S3 buckets and keys on the Synology NAS and store the
# credentials in OpenBao; subcommands in usage().
#
# The garage CLI runs on the NAS over SSH: DSM 7.2 mounts /tmp noexec, so no
# binary can be shipped there.
# OpenBao fields ACCESS_KEY_ID / ACCESS_SECRET_KEY; consumers in another
# namespace than the path's need a grant in global.openbao.access
# (scripts/openbao-eso-access.sh).
# `garage key create` is NOT idempotent (same-name keys get distinct IDs), so
# `create` aborts if the key name exists; `revoke` the old one first.
set -euo pipefail

GARAGE_SSH="${GARAGE_SSH:-ivan@10.11.12.237}"
GARAGE_CONFIG="${GARAGE_CONFIG:-/volume4/garage/garage/garage.toml}"
GARAGE_BIN="${GARAGE_BIN:-/volume4/@appstore/garage/bin/garage}"
BAO_MOUNT="${BAO_MOUNT:-${VAULT_MOUNT:-home}}"
BAO_PATH_PREFIX="${BAO_PATH_PREFIX:-${VAULT_PATH_PREFIX:-homelab/k8s}}"
# `bao` also honours the legacy VAULT_ADDR/VAULT_TOKEN if BAO_* are unset.
export BAO_ADDR="${BAO_ADDR:-${VAULT_ADDR:-https://openbao.example.com}}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 create <bucket> <key> --namespace <ns> [--quota <size>]
  $0 status [<bucket>]
  $0 revoke <key> --namespace <ns>

Subcommands:
  create   provision a NEW key + (idempotent) bucket, grant rw+owner,
           write OpenBao $BAO_MOUNT/$BAO_PATH_PREFIX/<ns>/s3-<key>
  status   list buckets + keys (no arg) or detail one bucket
  revoke   delete key from Garage + delete its OpenBao path

Env:
  GARAGE_SSH         ssh target on the NAS (default: $GARAGE_SSH)
  GARAGE_CONFIG      garage.toml path on NAS (default: $GARAGE_CONFIG)
  GARAGE_BIN         garage binary on NAS (default: $GARAGE_BIN)
  BAO_MOUNT          KV v2 mount (default: $BAO_MOUNT; legacy VAULT_MOUNT honoured)
  BAO_PATH_PREFIX    prefix under mount (default: $BAO_PATH_PREFIX; legacy VAULT_PATH_PREFIX honoured)
  BAO_ADDR           OpenBao endpoint (default: $BAO_ADDR)
EOF
}

die_usage() { usage; exit 2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}

garage_remote_cmd() {
  local cmd="sudo $GARAGE_BIN -c $GARAGE_CONFIG"
  local a
  for a in "$@"; do
    cmd+=" $(printf '%q' "$a")"
  done
  printf '%s' "$cmd"
}

garage_cmd() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$GARAGE_SSH" "$(garage_remote_cmd "$@")"
}

probe_health() {
  garage_cmd status >/dev/null 2>&1 || {
    echo "garage status failed on $GARAGE_SSH — is the SynoCommunity package running?" >&2
    exit 1
  }
}

bao_path() {
  printf '%s/%s/s3-%s' "$BAO_PATH_PREFIX" "$1" "$2"
}

# Count keys by name: Garage allows same-name keys with distinct IDs.
key_count_by_name() {
  garage_cmd key list 2>/dev/null \
    | awk -v n="$1" 'NR > 1 && $3 == n { c++ } END { print (c+0) }'
}

# Key name → Key ID; nothing on 0 matches, "AMBIGUOUS" on several.
key_id_by_name() {
  garage_cmd key list 2>/dev/null \
    | awk -v n="$1" 'NR > 1 && $3 == n { ids = ids ? ids " " $1 : $1; c++ } END {
        if (c == 1) print ids
        else if (c > 1) print "AMBIGUOUS"
      }'
}

bucket_exists_by_alias() {
  garage_cmd bucket list 2>/dev/null \
    | awk -v n="$1" 'NR > 1 && $3 == n { found = 1 } END { exit !found }'
}

cmd_status() {
  require ssh
  local bucket="${1:-}"
  if [ -z "$bucket" ]; then
    echo "=== buckets ==="
    garage_cmd bucket list
    echo
    echo "=== keys ==="
    garage_cmd key list
  else
    garage_cmd bucket info "$bucket"
  fi
}

cmd_create() {
  local bucket="${1:-}" key="${2:-}"
  [ -n "$bucket" ] && [ -n "$key" ] || die_usage
  shift 2
  local namespace="" quota=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --namespace) namespace="${2:?--namespace requires a value}"; shift 2 ;;
      --quota)     quota="${2:?--quota requires a value}"; shift 2 ;;
      *)           echo "unknown flag: $1" >&2; die_usage ;;
    esac
  done
  [ -n "$namespace" ] || { echo "--namespace is required" >&2; die_usage; }
  require ssh
  require bao
  require jq
  probe_health

  echo "=== 1/6 verify key name '$key' is free ==="
  local existing; existing=$(key_count_by_name "$key")
  if [ "$existing" != "0" ]; then
    echo "key name '$key' already exists ($existing match(es)) — Garage allows duplicates by ID, but this script refuses to create another." >&2
    echo "Use: $0 revoke '$key' --namespace <ns>   to delete the old one first." >&2
    exit 1
  fi

  echo "=== 2/6 create key '$key' ==="
  local key_out key_id secret
  key_out=$(garage_cmd key create "$key")
  # Key ID = "GK" + 24 hex, Secret = 64 hex; match labelled lines, not any hex blob.
  key_id=$(printf '%s\n' "$key_out" | awk -F': *' '/^Key ID:/ { print $2; exit }')
  secret=$(printf '%s\n' "$key_out" | awk -F': *' '/^Secret key:/ { print $2; exit }')
  if [ -z "$key_id" ] || [ -z "$secret" ]; then
    echo "failed to parse key output:" >&2
    printf '%s\n' "$key_out" >&2
    exit 1
  fi
  echo "  KEY_ID=$key_id"

  echo "=== 3/6 create bucket '$bucket' (idempotent) ==="
  if bucket_exists_by_alias "$bucket"; then
    echo "  bucket exists; reusing"
  else
    garage_cmd bucket create "$bucket"
  fi

  echo "=== 4/6 grant rw+owner on '$bucket' to '$key' ==="
  garage_cmd bucket allow --read --write --owner "$bucket" --key "$key"

  if [ -n "$quota" ]; then
    echo "=== 5/6 set quota ($quota) ==="
    garage_cmd bucket set-quotas "$bucket" --max-size "$quota"
  else
    echo "=== 5/6 skip quota (none requested) ==="
  fi

  local vpath; vpath=$(bao_path "$namespace" "$key")
  echo "=== 6/6 write OpenBao $BAO_MOUNT/$vpath ==="
  bao kv put -mount="$BAO_MOUNT" "$vpath" \
    ACCESS_KEY_ID="$key_id" \
    ACCESS_SECRET_KEY="$secret" >/dev/null

  echo
  echo "=== verify ==="
  garage_cmd bucket info "$bucket"
  echo
  bao kv get -mount="$BAO_MOUNT" -format=json "$vpath" \
    | jq '{path: "'"$BAO_MOUNT"/"$vpath"'", access_key_id: .data.data.ACCESS_KEY_ID, secret: "***redacted***"}'

  unset key_id secret
}

cmd_revoke() {
  local key="${1:-}"
  [ -n "$key" ] || die_usage
  shift
  local namespace=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --namespace) namespace="${2:?--namespace requires a value}"; shift 2 ;;
      *)           echo "unknown flag: $1" >&2; die_usage ;;
    esac
  done
  [ -n "$namespace" ] || { echo "--namespace is required" >&2; die_usage; }
  require ssh
  require bao
  probe_health

  local kid; kid=$(key_id_by_name "$key")
  case "$kid" in
    "")
      echo "no key named '$key' in Garage" >&2
      exit 1 ;;
    AMBIGUOUS)
      echo "multiple keys share the name '$key'. Resolve manually with:" >&2
      echo "  ssh $GARAGE_SSH 'sudo $GARAGE_BIN -c $GARAGE_CONFIG key list' | grep '$key'" >&2
      echo "  ssh $GARAGE_SSH 'sudo $GARAGE_BIN -c $GARAGE_CONFIG key delete <ID> --yes'" >&2
      exit 1 ;;
  esac

  echo "=== revoke garage key '$key' (ID $kid) ==="
  garage_cmd key delete "$kid" --yes

  local vpath; vpath=$(bao_path "$namespace" "$key")
  echo "=== delete OpenBao $BAO_MOUNT/$vpath ==="
  bao kv metadata delete -mount="$BAO_MOUNT" "$vpath"
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  status) shift; cmd_status "$@" ;;
  revoke) shift; cmd_revoke "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *) die_usage ;;
esac
