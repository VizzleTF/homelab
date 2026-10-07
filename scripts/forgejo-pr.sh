#!/usr/bin/env bash
# Wrapper for the full Forgejo PR lifecycle in the homelab monorepo, under
# the `vizzle` user (NOT `forgejo-admin`).
#
# Reads the Forgejo PAT from Vault: home/homelab/forgejo/vizzle-merge-token
# (KV v2, key `token`). Using this token — and ONLY this token — for both PR
# creation and merge ensures the squash-commit author = `vizzle`. An admin
# token stamps every squash as `forgejo-admin <gitea@local.domain>`
# regardless of who merges; never use one here. (A dedicated
# `branch-protection-token` was never created.)
#
# Subcommands:
#   open    <branch> -- <title> <body>   create a PR
#   status  <pr-number>                  one-shot CI snapshot (exit 0/1/2)
#   monitor <pr-number>                  poll CI until terminal state
#   merge   <pr-number>                  monitor + squash-merge if green
#   full    <branch> -- <title> <body>   open + merge in one flow
#   label   <pr-number> <label-name>     add an existing repo label to a PR
#   diff-comment <pr-number>             print the latest argocd-diff bot comment
#   rerun   <pr-number>                  re-trigger CI: empty commit on the checked-out
#                                        PR branch (Forgejo has no rerun API); not renovate/*
#
# Every <pr-number> except in `full` also takes an open PR's branch name.
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
#   BAO_ADDR         OpenBao endpoint (default: https://openbao.example.com) — a
#                    non-interactive shell does not inherit it from the profile
#   BAO_PATH         (default: homelab/forgejo/vizzle-merge-token) — mount `home`
#                    (legacy alias VAULT_PATH still honoured)
#   FORGEJO_TOKEN    if set, skips OpenBao and uses this value
#   POLL_INTERVAL    seconds between status polls (default: 15)
#   POLL_TIMEOUT     max seconds in monitor/merge (default: 600)
#   KEEP_BRANCH      if 1, skip post-merge local branch deletion (default: 0)
#   UPDATE_OUTDATED  if 1, merge BASE_BRANCH into an outdated PR branch before
#                    merging (block_on_outdated_branch); re-triggers CI (default: 0)
set -euo pipefail

FORGEJO_URL="${FORGEJO_URL:-https://git.example.com}"
FORGEJO_REPO="${FORGEJO_REPO:-vizzle/homelab}"
BASE_BRANCH="${BASE_BRANCH:-main}"
BAO_PATH="${BAO_PATH:-${VAULT_PATH:-homelab/forgejo/vizzle-merge-token}}"
# `bao` reads BAO_ADDR (and the legacy VAULT_ADDR); the fallback chain below
# sets BAO_ADDR explicitly either way.
export BAO_ADDR="${BAO_ADDR:-${VAULT_ADDR:-https://openbao.example.com}}"
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
  $0 label   <pr-number> <label-name>   (e.g. diff-reviewed)
  $0 diff-comment <pr-number>
  $0 rerun   <pr-number>                (on the checked-out PR branch; not renovate/*)

<pr-number> may also be the branch name of an open PR.

Env:
  FORGEJO_URL    (default: $FORGEJO_URL)
  FORGEJO_REPO   (default: $FORGEJO_REPO)
  BASE_BRANCH    (default: $BASE_BRANCH)
  BAO_ADDR       OpenBao endpoint (default: $BAO_ADDR)
  BAO_PATH       (default: $BAO_PATH) — mount=home, key=token
  FORGEJO_TOKEN  override the OpenBao lookup
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
  if [[ -n "${FORGEJO_TOKEN:-}" ]]; then
    printf '%s' "$FORGEJO_TOKEN"
    return
  fi
  require bao
  bao kv get -mount=home -field=token "$BAO_PATH" 2>/dev/null || {
    echo "openbao read failed for home/$BAO_PATH (BAO_ADDR=$BAO_ADDR)" >&2
    exit 1
  }
}

__TOKEN=""
token() {
  if [[ -z "$__TOKEN" ]]; then
    __TOKEN=$(get_token)
    [[ -n "$__TOKEN" ]] || { echo "empty token (openbao key 'token' missing?)" >&2; exit 1; }
  fi
  printf '%s' "$__TOKEN"
}

# forgejo_api <method> <path> [json-body]
# stdout: response body on 2xx. stderr: HTTP code + body on non-2xx.
# Returns 0 on 2xx and 1 otherwise; the HTTP status of the call is left in
# FORGEJO_HTTP_CODE (0 if curl itself failed). The status is deliberately not
# the return value: exit statuses are taken modulo 256, which turns 405 into
# 149 and a curl failure (0) into success. FORGEJO_HTTP_CODE is only visible to
# a caller that invokes forgejo_api directly, not through $(...).
FORGEJO_HTTP_CODE=0
forgejo_api() {
  local method="$1" path="$2" data="${3:-}"
  local t; t=$(token)
  local tmp; tmp=$(mktemp)
  local code
  if [[ -n "$data" ]]; then
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
  FORGEJO_HTTP_CODE="$code"
  if [[ "$code" -ge 200 ]] && [[ "$code" -lt 300 ]]; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi
  echo "forgejo API $method $path -> HTTP $code" >&2
  cat "$tmp" >&2
  echo >&2
  rm -f "$tmp"
  return 1
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
# Forgejo puts the per-context result in `.status`; `.state` stays null. The
# combined `.state` at the top of the payload is the fallback.
format_statuses() {
  jq -r '
    (.state // "queued") as $combined |
    .statuses[]? | "\(.context): \(.status // .state // $combined)"
  ' | sort -u
}

# The argocd-diff CI job posts (and later edits) one PR comment starting with
# this marker; see the "Comment on PR" step in .forgejo/workflows/ci.yaml.
DIFF_MARKER='<!-- argocd-diff -->'

# diff_comment <pr-number> — latest argocd-diff comment as {updated_at, body}, or nothing.
diff_comment() {
  forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/issues/$1/comments" \
    | jq -c --arg m "$DIFF_MARKER" '[.[] | select(.body | contains($m))] | last | select(.) | {updated_at, body}'
}

# jq: Forgejo timestamp ("2026-10-07T09:03:40+03:00", "...Z", optional fraction)
# -> epoch seconds, or null when empty/unparseable.
JQ_TS='def ts: try (sub("\\.[0-9]+"; "") | (.[0:19] + "Z" | fromdateiso8601)
  - (if .[19:] == "Z" then 0 else (.[19:20] + "1" | tonumber) * ((.[20:22] | tonumber) * 3600 + (.[23:25] | tonumber) * 60) end)) catch null;'

RENOVATE_RERUN_HINT="Renovate stops updating modified branches; use Re-run in the web UI or the rebase checkbox"

# resolve_pr <pr-number|branch> — a number passes through; a branch name maps to
# its single open PR. Forgejo ignores ?head=, so the filter runs client-side.
resolve_pr() {
  local arg="${1:-}" nums="" n
  [[ -n "$arg" ]] || { echo "pr-number or branch is required" >&2; die_usage; }
  if [[ "$arg" =~ ^[0-9]+$ ]]; then printf '%s' "$arg"; return; fi
  require curl
  require jq
  local page=1 resp
  while :; do
    resp=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls?state=open&limit=50&page=$page") \
      || { echo "could not list open PRs to resolve branch '$arg'" >&2; exit 1; }
    nums+=$(jq -r --arg b "$arg" '.[] | select(.head.ref == $b) | "\(.number)\n"' <<<"$resp")
    [[ "$(jq 'length' <<<"$resp")" -ge 50 ]] || break
    page=$((page + 1))
  done
  n=$(grep -c . <<<"$nums" || true)
  nums=$(grep . <<<"$nums" || true)
  [[ "$n" = 1 ]] || { echo "branch '$arg' has $n open PRs (need exactly 1)" >&2; exit 2; }
  printf '%s' "$nums"
}

# failure_hints <pr-number> <head-ref> (reads a status payload on stdin)
# For each failed check, say where the reason is. argocd-diff explains itself
# in its PR comment (kubeconform, pluto, review gate) — but only when that
# comment is from this run: one older than the latest `pending` of the
# argocd-diff context (its start, also after a web-UI re-run of just that job)
# is stale.
# Job logs are only in the web UI.
failure_hints() {
  local pr="$1" head_ref="$2" payload ctx url comment body started stale
  payload=$(cat)
  jq -r '.statuses[]? | select((.status // .state) | IN("failure", "error")) | "\(.context)\t\(.target_url)"' <<<"$payload" \
    | while IFS=$'\t' read -r ctx url; do
        echo "--- $ctx failed" >&2
        if [[ "$ctx" == *argocd-diff* ]]; then
          comment=$(diff_comment "$pr")
          if [[ -z "$comment" ]]; then
            echo "no argocd-diff comment: the render itself failed — log: $FORGEJO_URL$url" >&2
            continue
          fi
          # Status history, newest first: the first `pending` is this run's start.
          started=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/commits/$(jq -r '.sha' <<<"$payload")/statuses?limit=50" \
            | jq -r --arg c "$ctx" '[.[] | select(.context == $c and .status == "pending")][0].created_at // ""') || started=""
          stale=$(jq -rn --arg c "$(jq -r '.updated_at' <<<"$comment")" --arg s "$started" \
            "$JQ_TS"' ($c | ts) as $a | ($s | ts) as $b | if $a != null and $b != null then $a < $b else "unknown" end')
          if [[ "$stale" = "true" ]]; then
            echo "argocd-diff comment is from a previous run — this run failed before posting; log: $FORGEJO_URL$url" >&2
            continue
          elif [[ "$stale" = "unknown" ]]; then
            echo "warning: could not compare comment time with the job start (comment vs '${started:-none}') — it may be stale" >&2
          fi
          body=$(jq -r '.body' <<<"$comment")
          # Checks part of the comment only; the manifest diff follows the heading.
          awk -v m="$DIFF_MARKER" '/^## Argo CD Diff Preview/ {exit} $0 != m' <<<"$body" >&2
          if grep -q 'Blocked.*diff-reviewed' <<<"$body"; then
            echo "review gate: read the diff ($0 diff-comment $pr); with the user's consent run" >&2
            if [[ "$head_ref" == renovate/* ]]; then
              echo "  $0 label $pr diff-reviewed; then re-run: $RENOVATE_RERUN_HINT" >&2
            else
              echo "  $0 label $pr diff-reviewed && $0 rerun $pr" >&2
            fi
          else
            echo "no blocked check in the comment — job failed elsewhere; log (web UI only): $FORGEJO_URL$url" >&2
          fi
        else
          echo "log (web UI only): $FORGEJO_URL$url" >&2
        fi
      done
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

    if [[ "$verbose" = "1" ]] && [[ "$lines" != "$prev" ]]; then
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

    if [[ $((SECONDS - start)) -ge "$POLL_TIMEOUT" ]]; then
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
  [[ "$KEEP_BRANCH" = "1" ]] && return 0
  [[ -n "$branch" ]] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 0

  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "local branch '$branch' not present — nothing to delete" >&2
    return 0
  fi

  # If the merged branch is checked out, move to BASE_BRANCH first.
  local current
  current=$(git symbolic-ref --short -q HEAD || echo "")
  if [[ "$current" = "$branch" ]]; then
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
  [[ -n "$branch" ]] || die_usage
  shift
  [[ "${1:-}" = "--" ]] || { echo "expected '--' after branch" >&2; die_usage; }
  shift
  local title="${1:-}" body="${2:-}"
  [[ -n "$title" ]] || { echo "title is required" >&2; die_usage; }

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
  local pr; pr=$(resolve_pr "${1:-}") || exit $?
  require curl
  require jq

  local meta; meta=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr")
  local sha; sha=$(jq -r '.head.sha' <<<"$meta")
  if [[ "$(printf '%s' "$meta" | pr_freshness)" = "behind" ]]; then
    echo "note: PR #$pr branch is behind $BASE_BRANCH — this only blocks the merge if block_on_outdated_branch is on (then use UPDATE_OUTDATED=1)" >&2
  fi
  local payload; payload=$(fetch_status "$sha")
  # Per-context result lives in .status (.state stays null); combined .state is the fallback.
  printf '%s\n' "$payload" \
    | jq '
        (.state // "queued") as $combined |
        {state, statuses: [.statuses[]? | {context, state: (.status // .state // $combined)}] | sort_by(.context)}
      '

  case "$(jq -r '.state' <<<"$payload")" in
    success)       exit 0 ;;
    failure|error) failure_hints "$pr" "$(jq -r '.head.ref' <<<"$meta")" <<<"$payload"; exit 1 ;;
    *)             exit 2 ;;
  esac
}

cmd_monitor() {
  local pr; pr=$(resolve_pr "${1:-}") || exit $?
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
  local pr; pr=$(resolve_pr "${1:-}") || exit $?
  require curl
  require jq

  local meta merged head_ref
  meta=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr")
  merged=$(jq -r '.merged' <<<"$meta")
  head_ref=$(jq -r '.head.ref' <<<"$meta")
  if [[ "$merged" = "true" ]]; then
    echo "PR #$pr already merged — skipping merge API call" >&2
    printf '%s\n' "$meta" \
      | jq '{number, merged, merged_by: (.merged_by.login // null), merge_commit_sha}'
    cleanup_local_branch "$head_ref"
    return 0
  fi

  # block_on_outdated_branch: an outdated branch passes CI yet 405s on merge.
  # Surface it up front (and optionally update the branch) so the failure isn't
  # an opaque "HTTP 405" after the CI wait.
  if [[ "$(printf '%s' "$meta" | pr_freshness)" = "behind" ]]; then
    if [[ "$UPDATE_OUTDATED" = "1" ]]; then
      echo "PR #$pr branch is behind $BASE_BRANCH — merging $BASE_BRANCH in (UPDATE_OUTDATED=1)..." >&2
      if ! update_pr_branch "$pr"; then
        echo "branch update failed — merge would be rejected as outdated" >&2
        return 3
      fi
      # New head sha after the update merge → re-fetch so CI polls the right commit.
      meta=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr")
      echo "branch updated; CI re-runs on new head $(jq -r '.head.sha' <<<"$meta")" >&2
    else
      echo "note: PR #$pr branch is behind $BASE_BRANCH. If block_on_outdated_branch is on, the merge will 405;" >&2
      echo "      re-run with UPDATE_OUTDATED=1 to merge $BASE_BRANCH in first (re-triggers CI)." >&2
    fi
  fi

  local sha; sha=$(jq -r '.head.sha' <<<"$meta")
  echo "waiting for CI on PR #$pr (head $sha)..." >&2

  local rc=0
  poll_loop "$sha" 1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "merge aborted: CI not green (rc=$rc)" >&2
    return $rc
  fi

  local title body payload
  title=$(jq -r '.title' <<<"$meta")
  body=$(jq -r '.body // ""' <<<"$meta")
  # Forgejo/Gitea merge API uses CamelCase fields. The repo keeps
  # default_delete_branch_after_merge off, so the head branch is deleted here;
  # otherwise every merged PR leaves a branch on Forgejo and on the NAS mirror.
  payload=$(jq -n \
    --arg title "$title" \
    --arg msg   "$body" \
    '{Do: "squash", MergeTitleField: $title, MergeMessageField: $msg, delete_branch_after_merge: true}')

  # Forgejo BP readiness lags ~30s behind poll_loop success state — the merge
  # API may still return 405 ("Merge cannot succeed") or 409 (mergeability being
  # recomputed, e.g. right after a branch update) just after CI goes green.
  # Retry those up to 5x with 30s backoff. Crucially, a non-2xx response does NOT
  # always mean the merge failed: Forgejo has been observed returning 409 with
  # the PR object on a merge that actually went through — so after any failure,
  # re-check the authoritative .merged flag before giving up.
  local attempt rc=0
  for attempt in 1 2 3 4 5; do
    # Called directly, not in $(...), so FORGEJO_HTTP_CODE survives. Capturing
    # $? here would read the status of the `if` itself, which is always 0.
    # stderr stays visible: the response body says why a merge was refused.
    if forgejo_api POST "/api/v1/repos/$FORGEJO_REPO/pulls/$pr/merge" "$payload" >/dev/null; then
      rc=0; break
    fi
    rc="$FORGEJO_HTTP_CODE"
    if [[ "$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr" 2>/dev/null | jq -r '.merged')" = "true" ]]; then
      echo "merge attempt $attempt returned HTTP $rc but PR #$pr is merged — treating as success" >&2
      rc=0; break
    fi
    if { [[ "$rc" = "405" ]] || [[ "$rc" = "409" ]]; } && [[ "$attempt" -lt 5 ]]; then
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

cmd_label() {
  local pr name="${2:-}"
  pr=$(resolve_pr "${1:-}") || exit $?
  [[ -n "$name" ]] || { echo "label name is required" >&2; die_usage; }
  require curl
  require jq

  local id
  id=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/labels?limit=50" \
    | jq -r --arg n "$name" '.[] | select(.name == $n) | .id')
  [[ -n "$id" ]] || { echo "repo has no label named '$name'" >&2; exit 2; }

  forgejo_api POST "/api/v1/repos/$FORGEJO_REPO/issues/$pr/labels" "{\"labels\": [$id]}" \
    | jq -r --arg pr "$pr" '"PR #\($pr) labels: " + (map(.name) | join(", "))'
}

cmd_diff_comment() {
  local pr; pr=$(resolve_pr "${1:-}") || exit $?
  require curl
  require jq

  local comment; comment=$(diff_comment "$pr")
  [[ -n "$comment" ]] || { echo "PR #$pr has no argocd-diff comment (the job did not get to post one)" >&2; exit 1; }
  jq -r '"updated_at: \(.updated_at)\n\(.body)"' <<<"$comment"
}

# Forgejo has no API to re-run a job, so a new head sha is the only re-trigger:
# an empty commit and a plain push (PRs are squash-merged, the commit vanishes).
cmd_rerun() {
  local pr; pr=$(resolve_pr "${1:-}") || exit $?
  require curl
  require jq
  require git

  local meta head_ref head_sha current
  meta=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr")
  [[ "$(jq -r '.state' <<<"$meta")" = "open" ]] || { echo "PR #$pr is not open — nothing to re-run" >&2; exit 1; }
  head_ref=$(jq -r '.head.ref' <<<"$meta")
  head_sha=$(jq -r '.head.sha' <<<"$meta")
  if [[ "$head_ref" == renovate/* ]]; then
    echo "refusing: $head_ref is a Renovate branch — $RENOVATE_RERUN_HINT" >&2
    exit 1
  fi
  current=$(git symbolic-ref --short -q HEAD || echo "")
  if [[ "$current" != "$head_ref" ]]; then
    echo "refusing: PR #$pr head is '$head_ref', checked out is '${current:-detached HEAD}' — git checkout $head_ref first" >&2
    exit 1
  fi
  if [[ "$(git rev-parse HEAD)" != "$head_sha" ]]; then
    echo "refusing: local $head_ref is at $(git rev-parse --short HEAD), PR head is ${head_sha:0:8} — push or pull first" >&2
    exit 1
  fi
  if ! git diff --cached --quiet; then
    echo "refusing: staged changes would go into the re-trigger commit — commit or unstage them first" >&2
    exit 1
  fi

  # Pre-commit hooks run here as on any commit.
  git commit --allow-empty --quiet -m 'ci: re-trigger checks'
  git push --quiet origin "$head_ref"
  echo "PR #$pr: CI re-triggered ($(git rev-parse --short HEAD)); wait with: $0 monitor $pr" >&2
}

cmd_full() {
  local branch="${1:-}"
  [[ -n "$branch" ]] || die_usage

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
  label)          shift; cmd_label   "$@" ;;
  diff-comment)   shift; cmd_diff_comment "$@" ;;
  rerun)          shift; cmd_rerun   "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *)              die_usage ;;
esac
