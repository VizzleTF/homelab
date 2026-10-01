#!/usr/bin/env bash
# Write the OpenBao policies and Kubernetes-auth roles that ESO uses, from the
# access map `global.openbao.access` in argocd/values/global.yaml.
#
#   eso-own                 policy, templated: read <pathPrefix>/<SA namespace>/*
#   eso-grant-<group>       policy: read the exact paths of one grant group
#   eso-own                 role: SA `eso-*` in any namespace -> eso-own
#   eso-ns-<namespace>      role: SA `eso-*` in that namespace -> eso-own + its grants
#
# homelab-common renders SA `eso-<release>` + SecretStore per release and picks
# `eso-ns-<namespace>` when the namespace is in the map, `eso-own` otherwise.
# Idempotent: re-run after every change of the map. Roles and policies that
# left the map are not deleted (list them with --dry-run and remove by hand).
#
# Needs: bao (admin token in ~/.vault-token or BAO_TOKEN), yq (mikefarah), jq.
# Usage: scripts/openbao-eso-access.sh [--dry-run]
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
export BAO_ADDR="${BAO_ADDR:-https://openbao.example.com}"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

AUTH_MOUNT=kubernetes
TTL=1h

global=$(yq -o json '.global' < argocd/values/global.yaml)
prefix=$(jq -r '.vault.pathPrefix' <<<"$global")
access=$(jq -c '.openbao.access' <<<"$global")
KV_MOUNT=$(jq -r '.openbao.kvMount' <<<"$global")
accessor=$(bao auth list -format=json | jq -r --arg m "$AUTH_MOUNT/" '.[$m].accessor')
[[ -n "$accessor" && "$accessor" != null ]] || { echo "auth mount $AUTH_MOUNT/ not found" >&2; exit 1; }

# Fail on a namespace that names a group with no paths: it would silently get nothing.
unknown=$(jq -r '.grants as $g | .namespaces | to_entries[] | .value[] | select($g[.] == null)' <<<"$access" | sort -u)
[[ -z "$unknown" ]] || { echo "unknown grant group(s): $unknown" >&2; exit 1; }

run() {
  if [[ "$DRY" -eq 1 ]]; then echo "+ $*"; else "$@" >/dev/null; fi
}

write_policy() {
  local name=$1 body=$2
  if [[ "$DRY" -eq 1 ]]; then printf '+ policy %s\n%s\n' "$name" "$body"; return; fi
  bao policy write "$name" - <<<"$body" >/dev/null
  echo "policy $name"
}

read_rule() {
  printf 'path "%s/data/%s" { capabilities = ["read"] }\npath "%s/metadata/%s" { capabilities = ["read", "list"] }\n' \
    "$KV_MOUNT" "$1" "$KV_MOUNT" "$1"
}

ns_tpl="{{identity.entity.aliases.${accessor}.metadata.service_account_namespace}}"
write_policy eso-own "$(read_rule "$prefix/$ns_tpl/*")"

for group in $(jq -r '.grants | keys[]' <<<"$access"); do
  body=""
  for p in $(jq -r --arg g "$group" '.grants[$g][]' <<<"$access"); do
    body+=$(read_rule "$prefix/$p")$'\n'
  done
  write_policy "eso-grant-$group" "$body"
done

run bao write "auth/$AUTH_MOUNT/role/eso-own" \
  bound_service_account_names='eso-*' \
  bound_service_account_namespaces='*' \
  token_policies=eso-own \
  token_ttl="$TTL"
[[ "$DRY" -eq 1 ]] || echo "role eso-own"

for ns in $(jq -r '.namespaces | keys[]' <<<"$access"); do
  policies="eso-own$(jq -r --arg n "$ns" '.namespaces[$n][] | ",eso-grant-" + .' <<<"$access" | tr -d '\n')"
  run bao write "auth/$AUTH_MOUNT/role/eso-ns-$ns" \
    bound_service_account_names='eso-*' \
    bound_service_account_namespaces="$ns" \
    token_policies="$policies" \
    token_ttl="$TTL"
  [[ "$DRY" -eq 1 ]] || echo "role eso-ns-$ns ($policies)"
done
