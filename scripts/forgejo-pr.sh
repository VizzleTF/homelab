#!/usr/bin/env bash
# Wrapper for opening / squash-merging Forgejo PRs in the homelab monorepo
# under the `vizzle` user (NOT `forgejo-admin`).
#
# Reads the Forgejo PAT from Vault: home/homelab/forgejo/vizzle-merge-token
# (KV v2, key `token`). Using this token — and ONLY this token — for both PR
# creation and merge ensures the squash-commit author = `vizzle`. The
# `branch-protection-token` stamps every squash as `forgejo-admin
# <gitea@local.domain>` regardless of who merges; never use it here.
#
# Usage:
#   scripts/forgejo-pr.sh open  <branch> -- <title> <body>
#   scripts/forgejo-pr.sh merge <pr-number>
#
# Env overrides:
#   FORGEJO_URL    (default: https://git.example.com)
#   FORGEJO_REPO   (default: vizzle/homelab)
#   BASE_BRANCH    (default: main)
#   VAULT_PATH     (default: homelab/forgejo/vizzle-merge-token) — under mount `home`
#   FORGEJO_TOKEN  if set, skips Vault and uses this value
set -euo pipefail

FORGEJO_URL="${FORGEJO_URL:-https://git.example.com}"
FORGEJO_REPO="${FORGEJO_REPO:-vizzle/homelab}"
BASE_BRANCH="${BASE_BRANCH:-main}"
VAULT_PATH="${VAULT_PATH:-homelab/forgejo/vizzle-merge-token}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 open  <branch> -- <title> <body>
  $0 merge <pr-number>

Reads Forgejo PAT from Vault (mount=home, path=\$VAULT_PATH, key=token)
unless \$FORGEJO_TOKEN is set.
EOF
  exit 2
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}

get_token() {
  if [ -n "${FORGEJO_TOKEN:-}" ]; then
    printf '%s' "$FORGEJO_TOKEN"
    return
  fi
  require vault
  require jq
  local out
  out=$(vault kv get -mount=home -format=json "$VAULT_PATH" 2>/dev/null) || {
    echo "vault read failed for home/$VAULT_PATH" >&2
    exit 1
  }
  printf '%s' "$out" | jq -r '.data.data.token // empty'
}

cmd_open() {
  local branch="${1:-}"
  [ -n "$branch" ] || usage
  shift
  [ "${1:-}" = "--" ] || { echo "expected '--' after branch" >&2; usage; }
  shift
  local title="${1:-}"
  local body="${2:-}"
  [ -n "$title" ] || { echo "title is required" >&2; usage; }

  require curl
  require jq
  local token; token=$(get_token)
  [ -n "$token" ] || { echo "empty token (vault key 'token' missing?)" >&2; exit 1; }

  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg body  "$body" \
    --arg head  "$branch" \
    --arg base  "$BASE_BRANCH" \
    '{title: $title, body: $body, head: $head, base: $base}')

  curl -sS -f -X POST \
    -H "Authorization: token $token" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/pulls"
}

cmd_merge() {
  local pr="${1:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "pr-number must be a positive integer" >&2; usage; }

  require curl
  require jq
  local token; token=$(get_token)
  [ -n "$token" ] || { echo "empty token (vault key 'token' missing?)" >&2; exit 1; }

  local meta title body
  meta=$(curl -sS -f \
    -H "Authorization: token $token" \
    "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/pulls/$pr")
  title=$(jq -r '.title' <<<"$meta")
  body=$(jq -r '.body // ""' <<<"$meta")

  # Forgejo/Gitea merge API: Do + MergeTitleField + MergeMessageField (CamelCase).
  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg msg   "$body" \
    '{Do: "squash", MergeTitleField: $title, MergeMessageField: $msg}')

  curl -sS -f -X POST \
    -H "Authorization: token $token" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/pulls/$pr/merge"

  curl -sS -f \
    -H "Authorization: token $token" \
    "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/pulls/$pr" \
    | jq '{number, merged, merged_by: (.merged_by.login // null), merge_commit_sha}'
}

case "${1:-}" in
  open)  shift; cmd_open  "$@" ;;
  merge) shift; cmd_merge "$@" ;;
  *)     usage ;;
esac
