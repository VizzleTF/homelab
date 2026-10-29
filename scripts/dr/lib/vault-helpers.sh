#!/usr/bin/env bash
# OpenBao helpers (`bao` CLI; no `vault` binary).

# shellcheck disable=SC2034 # sourced; the defaults are read by the caller
: "${BAO_POD_NS:=openbao}"
: "${BAO_POD:=openbao-0}"
: "${BAO_ADDR_INTERNAL:=http://127.0.0.1:8200}"

# BAO_TOKEN from env (legacy VAULT_TOKEN honoured) or the decrypted DR-pack shamir file.
ensure_bao_token() {
  : "${BAO_TOKEN:=${VAULT_TOKEN:-}}"
  if [[ -n "${BAO_TOKEN:-}" ]]; then
    export BAO_TOKEN
    return 0
  fi
  local shamir_gpg="$DR_PACK_DIR/00-shamir.json.gpg"
  # No temp file: the bundle holds the unseal keys, and a function-local trap
  # path would be unbound (set -u) by the time an EXIT trap fires.
  # The off-site pack carries the bundle unencrypted (as in phase 06).
  if [[ -f "$shamir_gpg" ]]; then
    log_info "decrypting Shamir bundle from DR pack"
    BAO_TOKEN=$(gpg --quiet --batch --decrypt "$shamir_gpg" | jq -r '.root_token') \
      || die "shamir decrypt failed (wrong passphrase?)"
  elif [[ -f "$DR_PACK_DIR/00-shamir.json" ]]; then
    BAO_TOKEN=$(jq -r '.root_token' "$DR_PACK_DIR/00-shamir.json") \
      || die "cannot parse $DR_PACK_DIR/00-shamir.json"
  else
    die "no BAO_TOKEN in env and no $DR_PACK_DIR/00-shamir.json[.gpg]"
  fi
  export BAO_TOKEN
  [[ -n "$BAO_TOKEN" ]] && [[ "$BAO_TOKEN" != "null" ]] \
    || die "decrypted shamir bundle has no root_token"
}

# Run `bao ...` inside the openbao-0 pod with token + addr injected.
bao_exec() {
  kubectl -n "$BAO_POD_NS" exec "$BAO_POD" -- \
    env BAO_TOKEN="$BAO_TOKEN" BAO_ADDR="$BAO_ADDR_INTERNAL" "$@"
}

bao_auth_enable() {
  local method="$1" path="${2:-$1}"
  if bao_exec bao auth list -format=json 2>/dev/null \
      | jq -e ".\"$path/\"" >/dev/null 2>&1; then
    log_skip "auth/$path already enabled"
    return 0
  fi
  bao_exec bao auth enable -path="$path" "$method"
  log_ok "auth/$path enabled"
}

bao_secrets_enable() {
  local engine="$1" path="$2" ; shift 2
  if bao_exec bao secrets list -format=json 2>/dev/null \
      | jq -e ".\"$path/\"" >/dev/null 2>&1; then
    log_skip "secrets/$path already mounted"
    return 0
  fi
  bao_exec bao secrets enable -path="$path" "$@" "$engine"
  log_ok "secrets/$path mounted"
}
