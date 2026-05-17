#!/usr/bin/env bash
# Wrapper for the full Forgejo PR lifecycle in the homelab monorepo, under
# the `vizzle` user (NOT `forgejo-admin`).
#
# Reads the Forgejo PAT from Vault: home/homelab/forgejo/vizzle-merge-token
# (KV v2, key `token`). Using this token — and ONLY this token — for both PR
# creation and merge ensures the squash-commit author = `vizzle`. The
# `branch-protection-token` stamps every squash as `forgejo-admin
# <gitea@local.domain>` regardless of who merges; never use it here.
#
# Subcommands:
#   open    <branch> -- <title> <body>   create a PR
#   status  <pr-number>                  one-shot CI snapshot (exit 0/1/2)
#   monitor <pr-number>                  poll CI until terminal state
#   merge   <pr-number>                  monitor + squash-merge if green
#   full    <branch> -- <title> <body>   open + merge in one flow
#
# Exit codes (monitor/merge/full):
#   0  success / merged
#   1  CI failure
#   2  timeout (POLL_TIMEOUT exceeded) or usage error
#   3  merge API call failed
#
# Env overrides:
#   FORGEJO_URL      (default: https://git.example.com)
#   FORGEJO_REPO     (default: vizzle/homelab)
#   BASE_BRANCH      (default: main)
#   VAULT_PATH       (default: homelab/forgejo/vizzle-merge-token) — mount `home`
#   FORGEJO_TOKEN    if set, skips Vault and uses this value
#   POLL_INTERVAL    seconds between status polls (default: 15)
#   POLL_TIMEOUT     max seconds in monitor/merge (default: 600)
set -euo pipefail

FORGEJO_URL="${FORGEJO_URL:-https://git.example.com}"
FORGEJO_REPO="${FORGEJO_REPO:-vizzle/homelab}"
BASE_BRANCH="${BASE_BRANCH:-main}"
VAULT_PATH="${VAULT_PATH:-homelab/forgejo/vizzle-merge-token}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
POLL_TIMEOUT="${POLL_TIMEOUT:-600}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 open    <branch> -- <title> <body>
  $0 status  <pr-number>
  $0 monitor <pr-number>
  $0 merge   <pr-number>
  $0 full    <branch> -- <title> <body>

Env:
  FORGEJO_URL    (default: $FORGEJO_URL)
  FORGEJO_REPO   (default: $FORGEJO_REPO)
  BASE_BRANCH    (default: $BASE_BRANCH)
  VAULT_PATH     (default: $VAULT_PATH) — mount=home, key=token
  FORGEJO_TOKEN  override Vault lookup
  POLL_INTERVAL  seconds between CI polls (default: $POLL_INTERVAL)
  POLL_TIMEOUT   max seconds to wait for CI (default: $POLL_TIMEOUT)
EOF
}

die_usage() { usage; exit 2; }

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

__TOKEN=""
token() {
  if [ -z "$__TOKEN" ]; then
    __TOKEN=$(get_token)
    [ -n "$__TOKEN" ] || { echo "empty token (vault key 'token' missing?)" >&2; exit 1; }
  fi
  printf '%s' "$__TOKEN"
}

# forgejo_api <method> <path> [json-body]
# stdout: response body on 2xx. stderr: HTTP code + body on non-2xx.
# Returns the raw HTTP status code (0 if curl itself failed).
forgejo_api() {
  local method="$1" path="$2" data="${3:-}"
  local t; t=$(token)
  local tmp; tmp=$(mktemp)
  local code
  if [ -n "$data" ]; then
    code=$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: token $t" \
      -H "Content-Type: application/json" \
      -d "$data" \
      "$FORGEJO_URL$path") || code=0
  else
    code=$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: token $t" \
      "$FORGEJO_URL$path") || code=0
  fi
  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi
  echo "forgejo API $method $path -> HTTP $code" >&2
  cat "$tmp" >&2
  echo >&2
  rm -f "$tmp"
  return "$code"
}

get_pr_sha() {
  forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$1" | jq -r '.head.sha'
}

fetch_status() {
  forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/commits/$1/status"
}

# Reads a status payload on stdin, emits sorted "context: state" lines.
# Null state (job has registered but not started) is normalised to "queued".
format_statuses() {
  jq -r '.statuses[]? | "\(.context): \(.state // "queued")"' | sort -u
}

# poll_loop <sha> <verbose:0|1>
# Returns 0 on success, 1 on failure/error, 2 on timeout.
# In verbose=1, prints incremental status changes to stderr.
poll_loop() {
  local sha="$1" verbose="${2:-0}"
  local start=$SECONDS
  local prev="" payload state lines

  while :; do
    payload=$(fetch_status "$sha")
    state=$(jq -r '.state' <<<"$payload")
    lines=$(printf '%s' "$payload" | format_statuses)

    if [ "$verbose" = "1" ] && [ "$lines" != "$prev" ]; then
      diff <(printf '%s\n' "$prev") <(printf '%s\n' "$lines") \
        | sed -n 's/^> //p' >&2
      prev="$lines"
    fi

    case "$state" in
      success)        return 0 ;;
      failure|error)  return 1 ;;
      pending|"")     : ;;
      *)              echo "unknown CI state: $state" >&2; return 1 ;;
    esac

    if [ $((SECONDS - start)) -ge "$POLL_TIMEOUT" ]; then
      echo "timeout after ${POLL_TIMEOUT}s (state=$state)" >&2
      return 2
    fi
    sleep "$POLL_INTERVAL"
  done
}

cmd_open() {
  local branch="${1:-}"
  [ -n "$branch" ] || die_usage
  shift
  [ "${1:-}" = "--" ] || { echo "expected '--' after branch" >&2; die_usage; }
  shift
  local title="${1:-}" body="${2:-}"
  [ -n "$title" ] || { echo "title is required" >&2; die_usage; }

  require curl
  require jq

  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg body  "$body" \
    --arg head  "$branch" \
    --arg base  "$BASE_BRANCH" \
    '{title: $title, body: $body, head: $head, base: $base}')

  forgejo_api POST "/api/v1/repos/$FORGEJO_REPO/pulls" "$payload"
}

cmd_status() {
  local pr="${1:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "pr-number must be a positive integer" >&2; die_usage; }
  require curl
  require jq

  local sha; sha=$(get_pr_sha "$pr")
  local payload; payload=$(fetch_status "$sha")
  printf '%s\n' "$payload" \
    | jq '{state, statuses: [.statuses[]? | {context, state: (.state // "queued")}] | sort_by(.context)}'

  case "$(jq -r '.state' <<<"$payload")" in
    success)       exit 0 ;;
    failure|error) exit 1 ;;
    *)             exit 2 ;;
  esac
}

cmd_monitor() {
  local pr="${1:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "pr-number must be a positive integer" >&2; die_usage; }
  require curl
  require jq

  local sha; sha=$(get_pr_sha "$pr")
  echo "monitoring PR #$pr (head $sha), interval=${POLL_INTERVAL}s timeout=${POLL_TIMEOUT}s" >&2

  local rc=0
  poll_loop "$sha" 1 || rc=$?
  case $rc in
    0) echo "CI: success" >&2 ;;
    1) echo "CI: failure" >&2 ;;
    2) echo "CI: timeout" >&2 ;;
  esac
  return $rc
}

cmd_merge() {
  local pr="${1:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "pr-number must be a positive integer" >&2; die_usage; }
  require curl
  require jq

  local meta merged
  meta=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr")
  merged=$(jq -r '.merged' <<<"$meta")
  if [ "$merged" = "true" ]; then
    echo "PR #$pr already merged — skipping merge API call" >&2
    printf '%s\n' "$meta" \
      | jq '{number, merged, merged_by: (.merged_by.login // null), merge_commit_sha}'
    return 0
  fi

  local sha; sha=$(jq -r '.head.sha' <<<"$meta")
  echo "waiting for CI on PR #$pr (head $sha)..." >&2

  local rc=0
  poll_loop "$sha" 1 || rc=$?
  if [ $rc -ne 0 ]; then
    echo "merge aborted: CI not green (rc=$rc)" >&2
    return $rc
  fi

  local title body payload
  title=$(jq -r '.title' <<<"$meta")
  body=$(jq -r '.body // ""' <<<"$meta")
  # Forgejo/Gitea merge API uses CamelCase fields.
  payload=$(jq -n \
    --arg title "$title" \
    --arg msg   "$body" \
    '{Do: "squash", MergeTitleField: $title, MergeMessageField: $msg}')

  # Forgejo BP readiness lags ~30s behind poll_loop success state — server
  # may still return 405 ("Merge cannot succeed") right after CI goes green.
  # Retry up to 5x with 30s backoff before giving up.
  local attempt rc=0
  for attempt in 1 2 3 4 5; do
    if forgejo_api POST "/api/v1/repos/$FORGEJO_REPO/pulls/$pr/merge" "$payload" >/dev/null; then
      rc=0; break
    fi
    rc=$?
    if [ "$rc" = "405" ] && [ "$attempt" -lt 5 ]; then
      echo "merge attempt $attempt got HTTP 405 (BP not ready); retrying in 30s..." >&2
      sleep 30
      continue
    fi
    echo "merge api call failed (HTTP $rc)" >&2
    return 3
  done

  forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr" \
    | jq '{number, merged, merged_by: (.merged_by.login // null), merge_commit_sha}'
}

cmd_full() {
  local branch="${1:-}"
  [ -n "$branch" ] || die_usage

  local open_resp pr_number
  open_resp=$(cmd_open "$@")
  pr_number=$(jq -r '.number' <<<"$open_resp")
  [[ "$pr_number" =~ ^[0-9]+$ ]] || {
    echo "could not parse PR number from open response" >&2
    printf '%s\n' "$open_resp" >&2
    return 2
  }
  printf '%s\n' "$open_resp" | jq '{number, url: .html_url, title}'
  echo "opened PR #$pr_number — handing off to merge" >&2
  cmd_merge "$pr_number"
}

case "${1:-}" in
  open)           shift; cmd_open    "$@" ;;
  status)         shift; cmd_status  "$@" ;;
  monitor)        shift; cmd_monitor "$@" ;;
  merge)          shift; cmd_merge   "$@" ;;
  full)           shift; cmd_full    "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *)              die_usage ;;
esac
