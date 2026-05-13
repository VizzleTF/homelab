#!/usr/bin/env bash
# Migrate KV secrets, policies, Kubernetes auth method, and AppRole roles
# from HashiCorp Vault to OpenBao.
#
# Idempotent: re-running overwrites secrets/policies/roles with latest Vault state.
#
# Requires: vault CLI (or bao — same binary), jq.
#
# Env:
#   VAULT_ADDR   source Vault address (e.g. http://vault.vault:8200 from a pod,
#                or https://vault.example.com from a workstation)
#   VAULT_TOKEN  Vault root token
#   BAO_ADDR     target OpenBao address (e.g. http://openbao.openbao:8200)
#   BAO_TOKEN    OpenBao root token
#
# Usage:
#   scripts/migrate-vault-to-openbao.sh [--dry-run]

set -euo pipefail

: "${VAULT_ADDR:?required}"
: "${VAULT_TOKEN:?required}"
: "${BAO_ADDR:?required}"
: "${BAO_TOKEN:?required}"

DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  echo "*** DRY RUN — no writes to OpenBao ***"
fi

v() { VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" vault "$@"; }
b() { VAULT_ADDR="$BAO_ADDR" VAULT_TOKEN="$BAO_TOKEN" vault "$@"; }

apply() {
  if [[ -n "$DRY_RUN" ]]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

echo "== Pre-flight =="
v status >/dev/null && echo "  vault: reachable, unsealed"
b status >/dev/null && echo "  openbao: reachable, unsealed"

echo "== KV v2 mount 'home' on OpenBao =="
if ! b secrets list -format=json | jq -e '."home/"' >/dev/null 2>&1; then
  apply b secrets enable -path=home -version=2 kv
  echo "  enabled"
else
  echo "  already present"
fi

echo "== Walk Vault KV and copy to OpenBao =="
walk() {
  local prefix="$1"
  local keys
  keys=$(v kv list -format=json "home/$prefix" 2>/dev/null | jq -r '.[]' || true)
  [[ -z "$keys" ]] && return 0
  while IFS= read -r k; do
    if [[ "$k" == */ ]]; then
      walk "${prefix}${k}"
    else
      local path="${prefix}${k}"
      echo "  home/$path"
      local data
      data=$(v kv get -format=json "home/$path" | jq -c '.data.data')
      if [[ -n "$DRY_RUN" ]]; then
        echo "    DRY: bao kv put home/$path <data-redacted>"
      else
        echo "$data" | b kv put "home/$path" - >/dev/null
      fi
    fi
  done <<<"$keys"
}
walk ""

echo "== Policies =="
for pol in $(v policy list | grep -vE '^(default|root)$'); do
  echo "  $pol"
  body=$(v policy read "$pol")
  if [[ -n "$DRY_RUN" ]]; then
    echo "    DRY: bao policy write $pol -"
  else
    printf '%s' "$body" | b policy write "$pol" -
  fi
done

echo "== Kubernetes auth method =="
if ! b auth list -format=json | jq -e '."kubernetes/"' >/dev/null 2>&1; then
  apply b auth enable kubernetes
fi

# In-cluster CA + service host; disable_iss_validation matches source Vault config.
apply b write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  disable_iss_validation=true >/dev/null

echo "== Kubernetes auth roles =="
roles=$(v list -format=json auth/kubernetes/role 2>/dev/null | jq -r '.[]' || true)
while IFS= read -r role; do
  [[ -z "$role" ]] && continue
  echo "  $role"
  cfg=$(v read -format=json "auth/kubernetes/role/$role" | jq '.data')
  bsan=$(echo "$cfg" | jq -r '.bound_service_account_names | join(",")')
  bsns=$(echo "$cfg" | jq -r '.bound_service_account_namespaces | join(",")')
  pols=$(echo "$cfg" | jq -r '.token_policies | join(",")')
  ttl=$(echo "$cfg" | jq -r '.token_ttl')
  ans=$(echo "$cfg" | jq -r '.alias_name_source')
  apply b write "auth/kubernetes/role/$role" \
    bound_service_account_names="$bsan" \
    bound_service_account_namespaces="$bsns" \
    token_policies="$pols" \
    token_ttl="${ttl}s" \
    alias_name_source="$ans" >/dev/null
done <<<"$roles"

echo "== AppRole =="
approles=$(v list -format=json auth/approle/role 2>/dev/null | jq -r '.[]' || true)
if [[ -n "$approles" ]]; then
  if ! b auth list -format=json | jq -e '."approle/"' >/dev/null 2>&1; then
    apply b auth enable approle
  fi
  while IFS= read -r role; do
    [[ -z "$role" ]] && continue
    echo "  $role"
    cfg=$(v read -format=json "auth/approle/role/$role" | jq '.data')
    pols=$(echo "$cfg" | jq -r '.token_policies | join(",")')
    ttl=$(echo "$cfg" | jq -r '.token_ttl')
    maxttl=$(echo "$cfg" | jq -r '.token_max_ttl')
    apply b write "auth/approle/role/$role" \
      token_policies="$pols" \
      token_ttl="${ttl}s" \
      token_max_ttl="${maxttl}s" >/dev/null
  done <<<"$approles"
fi

echo "== Verification =="
src=$(v kv list -format=json home/homelab/ 2>/dev/null | jq -r '. | length')
dst=$(b kv list -format=json home/homelab/ 2>/dev/null | jq -r '. | length' || echo 0)
echo "  top-level entries under home/homelab/: vault=$src openbao=$dst"
[[ "$src" == "$dst" ]] || echo "  WARN: counts differ"

echo "== Done =="
