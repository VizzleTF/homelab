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
# After a successful merge (and for an already-merged PR), `merge`/`full`
# delete the merged PR's local branch and fast-forward BASE_BRANCH to its
# remote — so the next branch is never cut from a stale local main. Opt out
# with KEEP_BRANCH=1.
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
#   KEEP_BRANCH      if 1, skip post-merge local branch deletion (default: 0)
#   UPDATE_OUTDATED  if 1, merge BASE_BRANCH into an outdated PR branch before
#                    merging (block_on_outdated_branch); re-triggers CI (default: 0)
set -euo pipefail

FORGEJO_URL="${FORGEJO_URL:-https://git.example.com}"
FORGEJO_REPO="${FORGEJO_REPO:-vizzle/homelab}"
BASE_BRANCH="${BASE_BRANCH:-main}"
VAULT_PATH="${VAULT_PATH:-homelab/forgejo/vizzle-merge-token}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
POLL_TIMEOUT="${POLL_TIMEOUT:-600}"
KEEP_BRANCH="${KEEP_BRANCH:-0}"
UPDATE_OUTDATED="${UPDATE_OUTDATED:-0}"

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
  KEEP_BRANCH    if 1, skip post-merge local branch deletion (default: $KEEP_BRANCH)
  UPDATE_OUTDATED if 1, merge $BASE_BRANCH into an outdated PR branch first (default: $UPDATE_OUTDATED)
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

# pr_freshness  (reads a PR meta JSON on stdin)
# Forgejo's `mergeable:true` only means "no merge conflicts"; with
# block_on_outdated_branch enabled, the merge API still returns HTTP 405 when
# the PR branch sits behind the base-branch tip. Detect that here: the branch
# is outdated whenever its merge base differs from the current base tip.
# Emits "behind" or "uptodate" on stdout.
pr_freshness() {
  jq -r '
    if (.merge_base != null and .base.sha != null and .merge_base != .base.sha)
    then "behind" else "uptodate" end'
}

# update_pr_branch <pr-number>
# Server-side merge of the base branch into the PR branch so an outdated branch
# satisfies block_on_outdated_branch. Produces a new head sha → CI re-runs.
update_pr_branch() {
  forgejo_api POST "/api/v1/repos/$FORGEJO_REPO/pulls/$1/update?style=merge" >/dev/null
}

fetch_status() {
  forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/commits/$1/status"
}

# Reads a status payload on stdin, emits sorted "context: state" lines.
# Forgejo Actions never POSTs back to the legacy commit-statuses table, so
# per-context `.state` stays null forever even after a workflow finishes.
# The combined `.state` at the top of the payload is authoritative — fall
# back to it when per-context is null so the output reflects reality.
format_statuses() {
  jq -r '
    (.state // "queued") as $combined |
    .statuses[]? | "\(.context): \(.state // $combined)"
  ' | sort -u
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

# cleanup_local_branch <branch>
# Post-merge housekeeping: delete the merged PR's local branch and fast-forward
# BASE_BRANCH to its remote. A stale local main is a known footgun — branching
# off it silently re-does already-merged work. Best-effort: every step is
# non-fatal so a cleanup hiccup never masks a successful merge.
cleanup_local_branch() {
  local branch="${1:-}"
  [ "$KEEP_BRANCH" = "1" ] && return 0
  [ -n "$branch" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 0

  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "local branch '$branch' not present — nothing to delete" >&2
    return 0
  fi

  # If the merged branch is checked out, move to BASE_BRANCH first.
  local current
  current=$(git symbolic-ref --short -q HEAD || echo "")
  if [ "$current" = "$branch" ]; then
    if ! git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
      echo "could not switch off '$branch' (uncommitted changes?) — local branch kept" >&2
      return 0
    fi
  fi

  # -D (force): a squash-merged branch never looks "merged" to `git branch -d`.
  if git branch -D "$branch" >/dev/null 2>&1; then
    echo "deleted local branch '$branch'" >&2
  else
    echo "could not delete local branch '$branch'" >&2
  fi

  # Fast-forward BASE_BRANCH so the next branch is cut from up-to-date main.
  if git fetch --quiet origin "$BASE_BRANCH" 2>/dev/null \
    && git merge --ff-only "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    echo "fast-forwarded $BASE_BRANCH to origin/$BASE_BRANCH" >&2
  else
    echo "note: refresh $BASE_BRANCH manually (git checkout $BASE_BRANCH && git pull)" >&2
  fi
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

  local meta; meta=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr")
  local sha; sha=$(jq -r '.head.sha' <<<"$meta")
  if [ "$(printf '%s' "$meta" | pr_freshness)" = "behind" ]; then
    echo "note: PR #$pr branch is behind $BASE_BRANCH (outdated) — block_on_outdated_branch will reject merge until updated (UPDATE_OUTDATED=1)" >&2
  fi
  local payload; payload=$(fetch_status "$sha")
  # Combined .state is authoritative for Forgejo Actions (per-context entries
  # stay null forever — Actions never POSTs back to the legacy statuses table).
  printf '%s\n' "$payload" \
    | jq '
        (.state // "queued") as $combined |
        {state, statuses: [.statuses[]? | {context, state: (.state // $combined)}] | sort_by(.context)}
      '

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

  local meta merged head_ref
  meta=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr")
  merged=$(jq -r '.merged' <<<"$meta")
  head_ref=$(jq -r '.head.ref' <<<"$meta")
  if [ "$merged" = "true" ]; then
    echo "PR #$pr already merged — skipping merge API call" >&2
    printf '%s\n' "$meta" \
      | jq '{number, merged, merged_by: (.merged_by.login // null), merge_commit_sha}'
    cleanup_local_branch "$head_ref"
    return 0
  fi

  # block_on_outdated_branch: an outdated branch passes CI yet 405s on merge.
  # Surface it up front (and optionally update the branch) so the failure isn't
  # an opaque "HTTP 405" after the CI wait.
  if [ "$(printf '%s' "$meta" | pr_freshness)" = "behind" ]; then
    if [ "$UPDATE_OUTDATED" = "1" ]; then
      echo "PR #$pr branch is behind $BASE_BRANCH — merging $BASE_BRANCH in (UPDATE_OUTDATED=1)..." >&2
      if ! update_pr_branch "$pr"; then
        echo "branch update failed — merge would be rejected as outdated" >&2
        return 3
      fi
      # New head sha after the update merge → re-fetch so CI polls the right commit.
      meta=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr")
      echo "branch updated; CI re-runs on new head $(jq -r '.head.sha' <<<"$meta")" >&2
    else
      echo "WARNING: PR #$pr branch is behind $BASE_BRANCH; block_on_outdated_branch=true will 405 the merge." >&2
      echo "         re-run with UPDATE_OUTDATED=1 to merge $BASE_BRANCH in first (re-triggers CI)." >&2
    fi
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

  # Forgejo BP readiness lags ~30s behind poll_loop success state — the merge
  # API may still return 405 ("Merge cannot succeed") or 409 (mergeability being
  # recomputed, e.g. right after a branch update) just after CI goes green.
  # Retry those up to 5x with 30s backoff. Crucially, a non-2xx response does NOT
  # always mean the merge failed: Forgejo has been observed returning 409 with
  # the PR object on a merge that actually went through — so after any failure,
  # re-check the authoritative .merged flag before giving up.
  local attempt rc=0
  for attempt in 1 2 3 4 5; do
    if forgejo_api POST "/api/v1/repos/$FORGEJO_REPO/pulls/$pr/merge" "$payload" >/dev/null 2>&1; then
      rc=0; break
    fi
    rc=$?
    if [ "$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr" 2>/dev/null | jq -r '.merged')" = "true" ]; then
      echo "merge attempt $attempt returned HTTP $rc but PR #$pr is merged — treating as success" >&2
      rc=0; break
    fi
    if { [ "$rc" = "405" ] || [ "$rc" = "409" ]; } && [ "$attempt" -lt 5 ]; then
      echo "merge attempt $attempt got HTTP $rc (BP/mergeability not ready); retrying in 30s..." >&2
      sleep 30
      continue
    fi
    echo "merge api call failed (HTTP $rc)" >&2
    return 3
  done

  forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr" \
    | jq '{number, merged, merged_by: (.merged_by.login // null), merge_commit_sha}'

  cleanup_local_branch "$head_ref"
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
