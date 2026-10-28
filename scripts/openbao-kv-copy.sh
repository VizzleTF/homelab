#!/usr/bin/env bash
# Copy one OpenBao KV v2 secret to a new path without printing values: step one
# of moving a legacy path to <namespace>/<purpose> (rule: obsidian `111
# Memory/Vault Paths Reference.md`; procedure: /managing-vault-secrets move).
# Optional jq filter reshapes the data, e.g. '{client_secret: .oidc_client_secret}'.
# Never overwrites a destination (-cas=0); verifies the copy. Delete the old path
# by hand after the PR switching readers is synced.
# Test the write path against `bao server -dev`, never the prod mount.
#
# Paths relative to home/homelab/k8s/ (prefix optional); BAO_ADDR and token from env.
# Exit 0 copied or already identical, 1 refused or failed, 2 usage or a bad <dst>.
set -euo pipefail

[[ $# -ge 2 && $# -le 3 ]] || { echo "usage: $0 <src> <dst> [jq-filter]" >&2; exit 2; }
rel() { local p=${1#home/}; echo "${p#homelab/k8s/}"; }
src=homelab/k8s/$(rel "$1") dst=$(rel "$2") filter=${3:-.}
# The homelab-common VaultPath schema; no ExternalSecret in argocd/ reads another shape.
[[ $dst =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] || { echo "dst must be <namespace>/<purpose>: $2" >&2; exit 2; }
dst=homelab/k8s/$dst
data() { bao kv get -mount=home -format=json "$1" | jq -cS ".data.data | $2"; }

want=$(data "$src" "$filter") || { echo "cannot read $src" >&2; exit 1; }
# A filter naming a missing key yields null values, not an empty object.
[[ $(jq 'type == "object" and length > 0 and all(.[]; . != null and . != "")' <<<"$want") == true ]] ||
  { echo "refusing: empty or null values after filter: $src" >&2; exit 1; }
if have=$(data "$dst" . 2>/dev/null); then
  [[ $have == "$want" ]] && { echo "already identical: $dst"; exit 0; }
  echo "refusing: $dst exists with other data" >&2; exit 1
fi
# -cas=0 also refuses a destination whose latest version is deleted.
bao kv put -mount=home -cas=0 "$dst" - <<<"$want" >/dev/null || { echo "write refused: $dst" >&2; exit 1; }
[[ $(data "$dst" .) == "$want" ]] || { echo "verify failed: $dst" >&2; exit 1; }
echo "copied $src -> $dst keys=$(jq -c keys <<<"$want")"
