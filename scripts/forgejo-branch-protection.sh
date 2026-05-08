#!/usr/bin/env bash
# Apply (or update) Forgejo branch protection rule for `main` so that:
#   - direct push is disabled
#   - PRs are required
#   - the `gitleaks` status check must be green
#   - force-push and deletion are blocked
#
# Idempotent: PATCHes if the rule already exists, POSTs otherwise.
# Forgejo API: https://docs.codeberg.org/api/  (Gitea-compatible)
#
# Usage:
#   FORGEJO_TOKEN=<token> ./scripts/forgejo-branch-protection.sh <owner>/<repo> [<owner>/<repo> ...]
#
# Token must have `write:repository` scope on the listed repos.
# Get one from Forgejo: User Settings → Applications → Generate New Token.
# Recommended: store in Vault at home/homelab/forgejo/branch-protection-token.
set -euo pipefail

: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set}"
FORGEJO_URL="${FORGEJO_URL:-https://git.example.com}"
BRANCH="${BRANCH:-main}"
STATUS_CHECK="${STATUS_CHECK:-gitleaks}"

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <owner>/<repo> [<owner>/<repo> ...]" >&2
  exit 2
fi

protection_payload() {
  jq -n \
    --arg branch "$BRANCH" \
    --arg check "$STATUS_CHECK" \
    '{
      branch_name: $branch,
      enable_push: false,
      enable_push_whitelist: false,
      push_whitelist_usernames: [],
      push_whitelist_teams: [],
      push_whitelist_deploy_keys: false,
      enable_force_push: false,
      enable_force_push_whitelist: false,
      enable_merge_whitelist: false,
      require_signed_commits: false,
      protected_file_patterns: "",
      unprotected_file_patterns: "",
      block_on_rejected_reviews: false,
      block_on_official_review_requests: false,
      block_on_outdated_branch: true,
      dismiss_stale_approvals: true,
      ignore_stale_approvals: false,
      require_pull_request: true,
      required_approvals: 0,
      enable_status_check: true,
      status_check_contexts: [$check]
    }'
}

apply_one() {
  local repo="$1"
  local existing http_code
  echo "→ ${repo}"

  http_code=$(curl -sS -o /tmp/bp-existing.json -w "%{http_code}" \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    "${FORGEJO_URL}/api/v1/repos/${repo}/branch_protections/${BRANCH}")

  local payload
  payload=$(protection_payload)

  if [ "$http_code" = "200" ]; then
    echo "   exists → PATCH"
    curl -sS -f -X PATCH \
      -H "Authorization: token ${FORGEJO_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${FORGEJO_URL}/api/v1/repos/${repo}/branch_protections/${BRANCH}" >/dev/null
  elif [ "$http_code" = "404" ]; then
    echo "   missing → POST"
    curl -sS -f -X POST \
      -H "Authorization: token ${FORGEJO_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${FORGEJO_URL}/api/v1/repos/${repo}/branch_protections" >/dev/null
  else
    echo "   unexpected HTTP ${http_code} from Forgejo:" >&2
    cat /tmp/bp-existing.json >&2
    return 1
  fi

  curl -sS -f \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    "${FORGEJO_URL}/api/v1/repos/${repo}/branch_protections/${BRANCH}" \
    | jq '{branch_name, enable_push, require_pull_request, enable_status_check, status_check_contexts, enable_force_push}'
}

for r in "$@"; do
  apply_one "$r"
done
