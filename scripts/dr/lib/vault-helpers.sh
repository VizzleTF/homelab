#!/usr/bin/env bash
# Vault / OpenBao helpers.

# shellcheck disable=SC2034  (sourced)
: "${BAO_POD_NS:=openbao}"
: "${BAO_POD:=openbao-0}"
: "${BAO_ADDR_INTERNAL:=http://127.0.0.1:8200}"

# Read VAULT_TOKEN from env or from decrypted DR pack shamir file.
ensure_bao_token() {
  if [ -n "${VAULT_TOKEN:-}" ]; then
    return 0
  fi
  local shamir_gpg="$DR_PACK_DIR/00-shamir.json.gpg"
  [ -f "$shamir_gpg" ] || die "no VAULT_TOKEN in env and no $shamir_gpg"
  log_info "decrypting Shamir bundle from DR pack"
  local tmp; tmp=$(mktemp)
  trap 'shred -u "$tmp" 2>/dev/null || rm -f "$tmp"' EXIT
  gpg --quiet --batch --output "$tmp" --decrypt "$shamir_gpg" \
    || die "shamir decrypt failed (wrong passphrase?)"
  export VAULT_TOKEN
  VAULT_TOKEN=$(jq -r '.root_token' "$tmp")
  [ -n "$VAULT_TOKEN" ] && [ "$VAULT_TOKEN" != "null" ] \
    || die "decrypted shamir bundle has no root_token"
}

# Run `bao ...` inside the openbao-0 pod with token + addr injected.
bao_exec() {
  kubectl -n "$BAO_POD_NS" exec "$BAO_POD" -- \
    env BAO_TOKEN="$VAULT_TOKEN" BAO_ADDR="$BAO_ADDR_INTERNAL" "$@"
}

# Idempotent kv put — only writes if path missing OR fields differ.
bao_kv_put_if_missing() {
  local path="$1"; shift
  if bao_exec bao kv get "$path" >/dev/null 2>&1; then
    log_skip "vault path exists: $path"
    return 0
  fi
  bao_exec bao kv put "$path" "$@" >/dev/null
  log_ok "vault put: $path"
}

# Force put (overwrites). Use sparingly — usually we want _if_missing.
bao_kv_put_force() {
  local path="$1"; shift
  bao_exec bao kv put "$path" "$@" >/dev/null
  log_ok "vault put (force): $path"
}

# Enable an auth method if not enabled yet.
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

# Enable a secrets engine if not mounted.
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
