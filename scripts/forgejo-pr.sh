#!/usr/bin/env bash
# Forgejo PR lifecycle for the homelab monorepo; subcommands and env in usage().
#
# Token: ONLY the `vizzle` PAT at home/homelab/forgejo/vizzle-merge-token (key
# `token`); an admin token stamps every squash as `forgejo-admin`.
# `open` refuses a body with task-list checkboxes. `merge`/`full` then wait for
# the push webhook to reach ArgoCD, delete the local branch (and stale
# worktree-wf_* branches) and fast-forward BASE_BRANCH; KEEP_BRANCH=1 opts out.
# `ship` per branch: rebase, push, open or reuse the PR, merge, wait-apps; a
# review gate (5) parks that PR and goes on, any other failure stops.
# VAULT_PATH is a legacy alias of BAO_PATH.
#
# Exit codes (all subcommands):
#   0  success / merged (ship: merged and the touched apps settled)
#   1  CI failure
#   2  timeout (POLL_TIMEOUT) or usage error
#   3  merge API call failed / no merge sha
#   4  refused before push or PR: rebase conflict, diverged from origin/<b>,
#      dirty worktree, nothing to ship, PR body with task-list checkboxes
#   5  review gate: argocd-diff waits for diff-reviewed, PR left open
#   6  merged, deploy not confirmed: no push webhook counted in 60s,
#      or the touched apps did not settle within APPS_TIMEOUT
set -euo pipefail

FORGEJO_URL="${FORGEJO_URL:-https://git.example.com}"
FORGEJO_REPO="${FORGEJO_REPO:-vizzle/homelab}"
BASE_BRANCH="${BASE_BRANCH:-main}"
BAO_PATH="${BAO_PATH:-${VAULT_PATH:-homelab/forgejo/vizzle-merge-token}}"
# A non-interactive shell does not inherit BAO_ADDR from the profile.
export BAO_ADDR="${BAO_ADDR:-${VAULT_ADDR:-https://openbao.example.com}}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
POLL_TIMEOUT="${POLL_TIMEOUT:-1800}"
APPS_TIMEOUT="${APPS_TIMEOUT:-900}"
KEEP_BRANCH="${KEEP_BRANCH:-0}"
UPDATE_OUTDATED="${UPDATE_OUTDATED:-0}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 open    <branch> -- <title> <body>
  $0 status  <pr-number>
  $0 monitor <pr-number>
  $0 merge   <pr-number>
  $0 full    <branch> [-- <title> <body>]
  $0 ship    <branch>...
  $0 wait-apps <sha>
  $0 get     '<api-path>'               (read-only, e.g. 'repos/vizzle/homelab/actions/runs?limit=5')
  $0 comment <pr-number> < results.md   (post-merge outcome; after merge pass the number)
  $0 label   <pr-number> <label-name>   (e.g. diff-reviewed)
  $0 diff-comment <pr-number>
  $0 rerun   <pr-number>                (empty commit on the PR branch; renovate/*: ticks rebase-check)

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
  APPS_TIMEOUT   max seconds to wait for the ArgoCD apps (default: $APPS_TIMEOUT)
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

# forgejo_api <method> <path> [json-body] — body on stdout for 2xx, else code+body
# on stderr and return 1. HTTP status goes to FORGEJO_HTTP_CODE (0 = curl failed),
# not $?, which is mod 256 (405 → 149); visible only to a direct call, not $(...).
FORGEJO_HTTP_CODE=0
forgejo_api() {
  local method="$1" path="$2" data="${3:-}"
  local t; t=$(token)
  local tmp; tmp=$(mktemp)
  local code
  if [[ -n "$data" ]]; then
    # stdin, not argv: a Renovate PR body can exceed the 128 KiB argument limit.
    code=$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: token $t" \
      -H "Content-Type: application/json" \
      --data-binary @- \
      "$FORGEJO_URL$path" <<<"$data") || code=0
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

# pr_freshness (PR meta JSON on stdin) → "behind"|"uptodate". `mergeable:true`
# only means no conflicts; with block_on_outdated_branch the merge still 405s
# when the merge base differs from the base tip.
pr_freshness() {
  jq -r '
    if (.merge_base != null and .base.sha != null and .merge_base != .base.sha)
    then "behind" else "uptodate" end'
}

# update_pr_branch <pr-number> — server-side merge of base into the PR branch;
# new head sha, so CI re-runs.
update_pr_branch() {
  forgejo_api POST "/api/v1/repos/$FORGEJO_REPO/pulls/$1/update?style=merge" >/dev/null
}

fetch_status() {
  forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/commits/$1/status"
}

# status payload on stdin → sorted "context: state". Per-context result is in
# `.status` (`.state` stays null); top-level `.state` is the fallback.
format_statuses() {
  jq -r '
    (.state // "queued") as $combined |
    .statuses[]? | "\(.context): \(.status // .state // $combined)"
  ' | sort -u
}

# Marker of the argocd-diff PR comment ("Comment on PR" step, .forgejo/workflows/ci.yaml).
DIFF_MARKER='<!-- argocd-diff -->'

# diff_comment <pr-number> — latest argocd-diff comment as {updated_at, body}, or nothing.
diff_comment() {
  forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/issues/$1/comments" \
    | jq -c --arg m "$DIFF_MARKER" '[.[] | select(.body | contains($m))] | last | select(.) | {updated_at, body}'
}

# jq: Forgejo timestamp (offset or Z, optional fraction) → epoch, null if unparseable.
JQ_TS='def ts: try (sub("\\.[0-9]+"; "") | (.[0:19] + "Z" | fromdateiso8601)
  - (if .[19:] == "Z" then 0 else (.[19:20] + "1" | tonumber) * ((.[20:22] | tonumber) * 3600 + (.[23:25] | tonumber) * 60) end)) catch null;'

# resolve_pr <pr-number|branch> — branch → its single open PR, filtered
# client-side: Forgejo ignores ?head=.
open_prs_of() {
  local page=1 resp
  while :; do
    resp=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls?state=open&limit=50&page=$page") \
      || { echo "could not list open PRs to resolve branch '$1'" >&2; exit 1; }
    jq -r --arg b "$1" '.[] | select(.head.ref == $b) | .number' <<<"$resp"
    [[ "$(jq 'length' <<<"$resp")" -ge 50 ]] || break
    page=$((page + 1))
  done
}

resolve_pr() {
  local arg="${1:-}" nums="" n
  [[ -n "$arg" ]] || { echo "pr-number or branch is required" >&2; die_usage; }
  if [[ "$arg" =~ ^[0-9]+$ ]]; then printf '%s' "$arg"; return; fi
  require curl
  require jq
  nums=$(open_prs_of "$arg")
  n=$(grep -c . <<<"$nums" || true)
  nums=$(grep . <<<"$nums" || true)
  [[ "$n" = 1 ]] || { echo "branch '$arg' has $n open PRs (need exactly 1)" >&2; exit 2; }
  printf '%s' "$nums"
}

# fresh_diff_body <pr> <sha> <context> — the argocd-diff comment body of this
# run; return 1 if none, 3 if it predates the run.
fresh_diff_body() {
  local comment started stale
  comment=$(diff_comment "$1")
  [[ -n "$comment" ]] || return 1
  # Newest first: the first `pending` is this run's start.
  started=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/commits/$2/statuses?limit=50" \
    | jq -r --arg c "$3" '[.[] | select(.context == $c and .status == "pending")][0].created_at // ""') || started=""
  stale=$(jq -rn --arg c "$(jq -r '.updated_at' <<<"$comment")" --arg s "$started" \
    "$JQ_TS"' ($c | ts) as $a | ($s | ts) as $b | if $a != null and $b != null then $a < $b else "unknown" end')
  [[ "$stale" != "true" ]] || return 3
  [[ "$stale" != "unknown" ]] || echo "warning: could not compare comment time with the job start (comment vs '${started:-none}') — it may be stale" >&2
  jq -r '.body' <<<"$comment"
}

# failure_hints <pr-number> (status payload on stdin) — where each failure is
# explained: the argocd-diff PR comment if newer than that context's latest
# `pending` (also a web-UI re-run), else stale; job logs are web-UI only.
failure_hints() {
  local pr="$1" payload ctx url body rc
  payload=$(cat)
  jq -r '.statuses[]? | select((.status // .state) | IN("failure", "error")) | "\(.context)\t\(.target_url)"' <<<"$payload" \
    | while IFS=$'\t' read -r ctx url; do
        echo "--- $ctx failed" >&2
        if [[ "$ctx" == *argocd-diff* ]]; then
          rc=0; body=$(fresh_diff_body "$pr" "$(jq -r '.sha' <<<"$payload")" "$ctx") || rc=$?
          if [[ $rc -eq 1 ]]; then
            echo "no argocd-diff comment: the render itself failed — log: $FORGEJO_URL$url" >&2
            continue
          elif [[ $rc -ne 0 ]]; then
            echo "argocd-diff comment is from a previous run — this run failed before posting; log: $FORGEJO_URL$url" >&2
            continue
          fi
          # Checks part only; the manifest diff follows the heading.
          awk -v m="$DIFF_MARKER" '/^## Argo CD Diff Preview/ {exit} $0 != m' <<<"$body" >&2
          if grep -q 'Blocked.*diff-reviewed' <<<"$body"; then
            echo "review gate: check that $0 diff-comment $pr lists only the removals this PR intends;" >&2
            echo "  if so, run as separate commands: $0 label $pr diff-reviewed, then $0 rerun $pr" >&2
          else
            echo "no blocked check in the comment — job failed elsewhere; log (web UI only): $FORGEJO_URL$url" >&2
          fi
        else
          echo "log (web UI only): $FORGEJO_URL$url" >&2
        fi
      done
}

# poll_loop <sha> <verbose:0|1> — 0 success, 1 failure, 2 timeout.
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

# cleanup_local_branch <branch> — delete the merged local branch and fast-forward
# BASE_BRANCH: a branch cut from a stale main silently re-does merged work.
# Every step is non-fatal so cleanup never masks a successful merge.
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

  local current
  current=$(git symbolic-ref --short -q HEAD || echo "")
  if [[ "$current" = "$branch" ]]; then
    if ! git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
      echo "could not switch off '$branch' (uncommitted changes?) — local branch kept" >&2
      return 0
    fi
  fi

  # -D: a squash-merged branch never looks merged to `git branch -d`.
  if git branch -D "$branch" >/dev/null 2>&1; then
    echo "deleted local branch '$branch'" >&2
  else
    echo "could not delete local branch '$branch'" >&2
  fi

  if git fetch --quiet origin "$BASE_BRANCH" 2>/dev/null \
    && git merge --ff-only "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    echo "fast-forwarded $BASE_BRANCH to origin/$BASE_BRANCH" >&2
  else
    echo "note: refresh $BASE_BRANCH manually (git checkout $BASE_BRANCH && git pull)" >&2
  fi
  prune_workflow_branches
}

# prune_workflow_branches — delete `worktree-wf_*` branches no worktree holds and
# with no commit beyond origin/BASE_BRANCH.
prune_workflow_branches() {
  local b
  git worktree prune 2>/dev/null || return 0
  for b in $(git for-each-ref --format='%(refname:short)' 'refs/heads/worktree-wf_*'); do
    git worktree list --porcelain | grep -qxF "branch refs/heads/$b" && continue
    [[ -z "$(git rev-list "origin/$BASE_BRANCH..$b" 2>/dev/null || echo keep)" ]] || continue
    git branch -D "$b" >/dev/null 2>&1 && echo "deleted workflow branch '$b'" >&2
  done
  return 0
}

# use_branch_worktree <branch> — set WT to a clean worktree on <branch>: its
# current holder, else a temporary one (TEMP_WT). Never detached, so a plain
# push to origin works. Returns 4 on a dirty holder.
WT="" TEMP_WT=""
use_branch_worktree() {
  local b="$1"
  git worktree prune  # a deleted workflow worktree still "holds" its branch until pruned
  WT=$(git worktree list --porcelain | awk -v b="branch refs/heads/$b" '/^worktree /{w=substr($0,10)} $0==b{print w}')
  if [[ -z "$WT" ]]; then
    git show-ref --verify --quiet "refs/heads/$b" || git branch -q "$b" "origin/$b" || return 4
    TEMP_WT=$(mktemp -d)
    trap drop_temp_wt EXIT
    git worktree add -q "$TEMP_WT" "$b" || return 4
    WT="$TEMP_WT"
  fi
  [[ "$WT" = "$TEMP_WT" || "$WT" = "$(git rev-parse --show-toplevel)" ]] || echo "note: working in $WT, the worktree that holds '$b'" >&2
  if [[ -n "$(git -C "$WT" status --porcelain --untracked-files=no)" ]]; then
    echo "worktree $WT holding '$b' has uncommitted changes — commit them or remove that worktree" >&2
    drop_temp_wt
    return 4
  fi
}
drop_temp_wt() {
  [[ -z "$TEMP_WT" ]] || git worktree remove --force "$TEMP_WT"
  TEMP_WT=""
}

# argocd_webhooks — argocd-server push-webhook counter for this repo, via the
# apiserver proxy (nothing scrapes it); raw REST paths skip discovery, so an
# unreachable cluster costs 5s, not ~150s. 0 if absent, empty if unreachable.
# shortcut: reads one argocd-server pod; sum over pods if the server is scaled out.
argocd_webhooks() {
  command -v kubectl >/dev/null 2>&1 || return 0
  local pod m
  pod=$(kubectl --request-timeout=5s get --raw \
    '/api/v1/namespaces/argocd/pods?labelSelector=app.kubernetes.io/name%3Dargocd-server' 2>/dev/null \
    | jq -r '.items[0].metadata.name // empty') || return 0
  [[ -n "$pod" ]] || return 0
  m=$(kubectl --request-timeout=5s get --raw "/api/v1/namespaces/argocd/pods/$pod:8083/proxy/metrics" 2>/dev/null) || return 0
  awk -v s="argocd_webhook_requests_total{repo=\"$FORGEJO_URL/$FORGEJO_REPO\"}" \
    'index($0, s " ") == 1 {n = $2} END {print n + 0}' <<<"$m"
}

# expect_webhook <count-before-merge> — the merge push must reach ArgoCD in 60s,
# else apps silently wait for timeout.reconciliation (2026-10: every delivery failed unnoticed).
expect_webhook() {
  local before="$1" now=""
  [[ -n "$before" ]] || { echo "note: ArgoCD metrics unreadable, webhook check skipped" >&2; return 0; }
  for _ in $(seq 12); do
    sleep 5
    now=$(argocd_webhooks)
    [[ -n "$now" ]] || continue
    (( now > before )) && return 0
    # shortcut: a restart that climbs back to exactly $before reads as a lost webhook; fine with one argocd-server replica.
    (( now < before )) && { echo "note: argocd-server restarted, webhook check skipped" >&2; return 0; }
  done
  echo "WARNING: ArgoCD counted no push webhook for this merge in 60s (argocd_webhook_requests_total $before -> ${now:-?})." >&2
  echo "  Apps now sync only by polling (up to 10 min). Do NOT refresh all apps to compensate; read the failed delivery:" >&2
  echo "  ssh root@10.11.11.153 \"sudo -u postgres psql -d git -At -c 'select hook_id, is_succeed, left(response_content,300) from hook_task order by id desc limit 3'\"" >&2
  return 6
}

# check_body <body> — the body becomes the squash commit: a checkbox there claims
# a check open (or done) forever. shortcut: also matches inside fenced code;
# strip fences if a PR quoting a checklist trips it.
check_body() {
  local boxes
  boxes=$(grep -nE '^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+\[[ xX]\]' <<<"$1" || true)
  [[ -n "$boxes" ]] || return 0
  echo "refusing: PR body has task-list checkboxes:" >&2
  printf '%s\n' "$boxes" >&2
  echo "state what already ran as plain past-tense bullets; put post-merge steps under '## After merge' as plain bullets; required CI checks need no line" >&2
  return 4
}

cmd_open() {
  local branch="${1:-}"
  [[ -n "$branch" ]] || die_usage
  shift
  [[ "${1:-}" = "--" ]] || { echo "expected '--' after branch" >&2; die_usage; }
  shift
  local title="${1:-}" body="${2:-}"
  [[ -n "$title" ]] || { echo "title is required" >&2; die_usage; }
  check_body "$body" || exit 4

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
  printf '%s\n' "$payload" \
    | jq '
        (.state // "queued") as $combined |
        {state, statuses: [.statuses[]? | {context, state: (.status // .state // $combined)}] | sort_by(.context)}
      '

  case "$(jq -r '.state' <<<"$payload")" in
    success)       exit 0 ;;
    failure|error) failure_hints "$pr" <<<"$payload"; exit 1 ;;
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
  # After the head branch is deleted .head.ref becomes refs/pull/<n>/head; .head.label keeps the name.
  head_ref=$(jq -r 'if (.head.ref | startswith("refs/pull/")) then .head.label else .head.ref end' <<<"$meta")
  if [[ "$merged" = "true" ]]; then
    echo "PR #$pr already merged — skipping merge API call" >&2
    printf '%s\n' "$meta" \
      | jq '{number, merged, merged_by: (.merged_by.login // null), merge_commit_sha}'
    after_merge_hint "$pr" "$meta"
    cleanup_local_branch "$head_ref"
    return 0
  fi

  # An outdated branch passes CI yet 405s on merge: catch it before the CI wait.
  if [[ "$(printf '%s' "$meta" | pr_freshness)" = "behind" ]]; then
    if [[ "$UPDATE_OUTDATED" = "1" ]]; then
      echo "PR #$pr branch is behind $BASE_BRANCH — merging $BASE_BRANCH in (UPDATE_OUTDATED=1)..." >&2
      if ! update_pr_branch "$pr"; then
        echo "branch update failed — merge would be rejected as outdated" >&2
        return 3
      fi
      # New head sha → re-fetch so CI polls the right commit.
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
  # Merge API fields are CamelCase. default_delete_branch_after_merge is off, so
  # the head branch is deleted here (else it lingers on Forgejo and the NAS mirror).
  payload=$(jq -n \
    --arg title "$title" \
    --arg msg   "$body" \
    '{Do: "squash", MergeTitleField: $title, MergeMessageField: $msg, delete_branch_after_merge: true}')

  # Just after CI goes green the merge API may 405 (BP readiness lags ~30s) or
  # 409 (mergeability recomputing): retry 5x with 30s backoff. A 409 has come
  # back on a merge that went through, so re-check .merged before giving up.
  local attempt rc=0 hooks_before
  hooks_before=$(argocd_webhooks)
  for attempt in 1 2 3 4 5; do
    # Direct call, not $(...), so FORGEJO_HTTP_CODE survives ($? would be the
    # `if`'s, always 0). stderr stays visible: it says why a merge was refused.
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

  after_merge_hint "$pr" "$meta"
  cleanup_local_branch "$head_ref"
  expect_webhook "$hooks_before" || return 6
}

# after_merge_hint <pr-number> <pr-json> — print the body's "## After merge"
# section: the squash commit is immutable, so the outcome goes to a PR comment.
after_merge_hint() {
  local plan
  plan=$(jq -r '.body // ""' <<<"$2" | awk '/^## /{p = ($0 ~ /^## After merge/); next} p')
  [[ -n "${plan//[[:space:]]/}" ]] || return 0
  printf 'post-merge steps of PR #%s: run each, then post one line per step (verified / not done / pending / owner):\n  %s comment %s <<'"'"'EOF'"'"' ... EOF\n%s\n' "$1" "$0" "$1" "$plan" >&2
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

# No re-run API: an empty commit makes a new head sha (squash-merge drops it).
# Renovate abandons a branch with a foreign commit, so renovate/* ticks the
# rebase-check box instead.
cmd_rerun() {
  local pr; pr=$(resolve_pr "${1:-}") || exit $?
  require curl
  require jq
  require git

  local meta head_ref head_sha
  meta=$(forgejo_api GET "/api/v1/repos/$FORGEJO_REPO/pulls/$pr")
  [[ "$(jq -r '.state' <<<"$meta")" = "open" ]] || { echo "PR #$pr is not open — nothing to re-run" >&2; exit 1; }
  head_ref=$(jq -r '.head.ref' <<<"$meta")
  head_sha=$(jq -r '.head.sha' <<<"$meta")
  if [[ "$head_ref" == renovate/* ]]; then
    local box='- [ ] <!-- rebase-check -->' ticked='- [x] <!-- rebase-check -->'
    if jq -e --arg b "$box" '.body // "" | contains($b)' <<<"$meta" >/dev/null; then
      forgejo_api PATCH "/api/v1/repos/$FORGEJO_REPO/pulls/$pr" \
        "$(jq -c --arg b "$box" --arg x "$ticked" '{body: (.body | split($b) | join($x))}' <<<"$meta")" >/dev/null
      echo "PR #$pr: rebase-check ticked" >&2
    elif jq -e --arg x "$ticked" '.body // "" | contains($x)' <<<"$meta" >/dev/null; then
      echo "PR #$pr: rebase-check already ticked" >&2
    else
      echo "PR #$pr has no rebase-check box in its body — nothing to tick" >&2
      exit 1
    fi
    echo "Renovate recreates $head_ref on its next run (CronJob renovate, 06:00 UTC) and CI runs again; off-schedule:" >&2
    echo "  kubectl -n renovate create job --from=cronjob/renovate manual-$(date +%s)" >&2
    return 0
  fi
  git fetch -q origin "$head_ref"
  use_branch_worktree "$head_ref" || exit 1
  if [[ "$(git -C "$WT" rev-parse HEAD)" != "$head_sha" ]]; then
    echo "refusing: local $head_ref is at $(git -C "$WT" rev-parse --short HEAD), PR head is ${head_sha:0:8} — push or pull first" >&2
    drop_temp_wt; exit 1
  fi

  # Pre-commit hooks run here as on any commit.
  git -C "$WT" commit --allow-empty --quiet -m 'ci: re-trigger checks'
  git -C "$WT" push --quiet origin "$head_ref"
  echo "PR #$pr: CI re-triggered ($(git -C "$WT" rev-parse --short HEAD)); wait with: $0 monitor $pr" >&2
  drop_temp_wt
}

cmd_comment() {
  local pr; pr=$(resolve_pr "${1:-}") || exit $?
  require curl
  require jq
  local body; body=$(cat)
  [[ -n "${body//[[:space:]]/}" ]] || { echo "comment body (stdin) is empty" >&2; die_usage; }
  forgejo_api POST "/api/v1/repos/$FORGEJO_REPO/issues/$pr/comments" "$(jq -n --arg b "$body" '{body: $b}')" \
    | jq -r '.html_url'
}

# full <branch> [-- <title> <body>] — `ship` runs it as a child process: a
# function in an `||` list runs with errexit off.
cmd_full() {
  [[ -n "${1:-}" ]] || die_usage
  [[ $# -eq 1 || ( "${2:-}" = "--" && -n "${3:-}" ) ]] || die_usage
  ship_one "$1" "${3:-}" "${4:-}"
}

# The apps a merge touches, as ArgoCD's webhook decides: manifest-generate-paths
# matching a changed file (all for argocd/appsets/), plus app folders in the commit
# (a new one waits for the AppSet's 3-min git poll). Prints "<app> <why>" for each
# missing, on a chart version other than $pins, not at $revs, or not Synced/Healthy.
# shellcheck disable=SC2016  # $-names are jq variables
JQ_PENDING='def hit($paths): any($changed[]; . as $f | any($paths[]; . as $p | $f == $p or ($f | startswith($p + "/"))));
[.items[].metadata.name] as $have
| ($expected - $have | .[] | "\(.) missing"),
  (.items[]
   | ((.metadata.annotations["argocd.argoproj.io/manifest-generate-paths"] // "") | split(";") | map(ltrimstr("/") | select(. != ""))) as $paths
   | select(hit($paths) or any($changed[]; startswith("argocd/appsets/")) or (.metadata.name | IN($expected[])))
   | (.spec.sources // [.spec.source]) as $src
   | (.status.sync.revisions // [.status.sync.revision]) as $rev
   | ($pins[.metadata.name] // null) as $pin
   | if $pin != null and (($src[0].targetRevision // "") | IN($pin[]) | not)
     then "\(.metadata.name) targetRevision \($src[0].targetRevision // "-") (config.yaml: \($pin | join(" or ")))"
     elif [range($src | length) | select($src[.].repoURL | test("vizzle/homelab")) | $rev[.]] | all(IN($revs[])) | not
     then "\(.metadata.name) stale"
     elif .status.sync.status != "Synced" or .status.health.status != "Healthy" or .status.operationState.phase == "Running"
     then "\(.metadata.name) \(.status.sync.status)/\(.status.health.status)/\(.status.operationState.phase // "-")"
     else empty end)'

lines_json() { jq -Rsc 'split("\n") | map(select(. != ""))'; }

# app_pins <sha> — {"<app>": [targetRevision...]} for apps whose config.yaml <sha>
# changes (homelabOnly apps have no chart): the pin at <sha> and at every later
# BASE_BRANCH commit that changes it.
app_pins() {
  local sha="$1" layer name f c v
  git diff-tree --no-commit-id --name-only -r "$sha" | sed -nE 's#^argocd/(apps|infra)/([^/]+)/config\.yaml$#\1 \2#p' \
    | while read -r layer name; do
        f="argocd/$layer/$name/config.yaml"
        git cat-file -e "$sha:$f" 2>/dev/null || continue
        [[ "$(git show "$sha:$f" | yq '.homelabOnly // false')" != "true" ]] || continue
        for c in $(git rev-list "$sha^..origin/$BASE_BRANCH" -- "$f"); do
          v=$(git show "$c:$f" 2>/dev/null | yq '.targetRevision // ""') || v=""
          [[ -z "$v" ]] || printf '%s\t%s\n' "$name" "$v"
        done
      done \
    | jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | select(.[1] != ""))
        | group_by(.[0]) | map({key: .[0][0], value: map(.[1]) | unique}) | from_entries'
}

# wait_apps <sha> — read-only, no refresh: the push webhook refreshes these apps;
# without it the periodic reconcile (600s + jitter) still lands inside APPS_TIMEOUT.
wait_apps() {
  local sha changed expected revs pins apps pending layer name t start=$SECONDS
  for t in kubectl yq; do
    command -v "$t" >/dev/null 2>&1 || { echo "$t not on PATH: apps of ${1:-?} not checked" >&2; return 6; }
  done
  git fetch -q origin "$BASE_BRANCH" || echo "warning: git fetch origin $BASE_BRANCH failed" >&2
  sha=$(git rev-parse -q --verify "${1:-}^{commit}") || { echo "unknown commit '${1:-}'" >&2; return 2; }
  changed=$(git diff-tree --no-commit-id --name-only -r "$sha" | lines_json)
  # A deleted folder has no config.yaml at <sha>: nothing to wait for.
  expected=$(git diff-tree --no-commit-id --name-only -r "$sha" | sed -nE 's#^argocd/(apps|infra)/([^/]+)/.*#\1 \2#p' | sort -u \
    | while read -r layer name; do
        if git cat-file -e "$sha:argocd/$layer/$name/config.yaml" 2>/dev/null; then echo "$name"; fi
      done | lines_json)
  while :; do
    revs=$(git rev-list "$sha^..origin/$BASE_BRANCH" | lines_json)
    pins=$(app_pins "$sha")
    # A failed read must never look like "nothing pending".
    if apps=$(kubectl -n argocd get applications.argoproj.io -o json --request-timeout=10s); then
      pending=$(jq -r --argjson changed "$changed" --argjson expected "$expected" --argjson revs "$revs" \
        --argjson pins "$pins" "$JQ_PENDING" <<<"$apps") || pending="(jq failed on the applications list)"
    else
      pending="(kubectl get applications failed)"
    fi
    if [[ -z "$pending" ]]; then
      echo "apps settled at ${sha:0:8}" >&2
      return 0
    fi
    if [[ $((SECONDS - start)) -ge "$APPS_TIMEOUT" ]]; then
      printf 'apps not settled at %s after %ss:\n%s\n' "${sha:0:8}" "$APPS_TIMEOUT" "$pending" >&2
      return 6
    fi
    sleep "$POLL_INTERVAL"
    git fetch -q origin "$BASE_BRANCH" || true
  done
}

ship_one() {
  local b="$1" title="${2:-}" body="${3:-}" pr rc=0 sha payload failed out cherry
  if [[ "$b" = "$BASE_BRANCH" || "$b" == renovate/* ]]; then
    echo "refusing to ship '$b' (base branch or Renovate-owned)" >&2; return 2
  fi
  require curl
  require jq
  git fetch -q --prune origin || { echo "git fetch origin failed" >&2; return 4; }

  use_branch_worktree "$b" || return 4
  # Never force-push over commits pushed elsewhere: catch up, or refuse when
  # origin/$b has a commit with no equivalent patch here. Older copies of local
  # commits are replaced by the force-with-lease push.
  if git rev-parse -q --verify "origin/$b" >/dev/null && ! git merge-base --is-ancestor "origin/$b" "$b"; then
    if git merge-base --is-ancestor "$b" "origin/$b"; then
      git -C "$WT" merge -q --ff-only "origin/$b" || { drop_temp_wt; return 4; }
    else
      cherry=$(git cherry "$b" "origin/$b") || { drop_temp_wt; return 4; }
      if grep -q '^+' <<<"$cherry"; then
        echo "'$b' and origin/$b diverged: origin has commits '$b' lacks — merge them in, then ship again" >&2
        drop_temp_wt; return 4
      fi
    fi
  fi

  # PR text from the pre-rebase commits, so a refusal leaves the branch as it was.
  pr=$(open_prs_of "$b") || return 3
  pr="${pr%%$'\n'*}"
  if [[ -z "$pr" ]]; then
    local range=(--no-merges --cherry-pick --right-only "origin/$BASE_BRANCH...$b")
    [[ -n "$title" ]] || title=$(git log --reverse --format=%s "${range[@]}" | sed -n 1p)
    [[ -n "$body" ]] || body=$(git log --reverse --format='## %s%n%n%b' "${range[@]}")
    check_body "$body" || { echo "pass the PR text explicitly: $0 full $b -- <title> <body>" >&2; drop_temp_wt; return 4; }
  elif [[ -n "$title" ]]; then
    echo "note: reusing PR #$pr; its title and body stay as they are" >&2
  fi

  # argocd-diff renders the PR head, not the merge result: rebase so CI checks what
  # main will hold.
  if ! git merge-base --is-ancestor "origin/$BASE_BRANCH" "$b"; then
    if ! git -C "$WT" rebase -q "origin/$BASE_BRANCH"; then
      git -C "$WT" diff --name-only --diff-filter=U >&2
      git -C "$WT" rebase --abort
      drop_temp_wt
      echo "rebase conflict: $b onto origin/$BASE_BRANCH — resolve it, then ship again" >&2
      return 4
    fi
  fi
  if [[ -z "$(git rev-list "origin/$BASE_BRANCH..$b")" ]]; then
    echo "'$b' has no commits ahead of $BASE_BRANCH — nothing to ship" >&2; drop_temp_wt; return 4
  fi
  if [[ "$(git rev-parse "$b")" != "$(git rev-parse -q --verify "origin/$b" || true)" ]]; then
    git -C "$WT" push -q --force-with-lease -u origin "$b" || { drop_temp_wt; return 4; }
  fi
  drop_temp_wt
  if [[ -z "$pr" ]]; then
    pr=$(cmd_open "$b" -- "$title" "$body" | jq -r '.number') || true
    [[ "$pr" =~ ^[0-9]+$ ]] || { echo "could not open a PR for '$b'" >&2; return 3; }
  else
    # The PR head moves asynchronously after a push: don't poll the replaced commit's CI.
    sha=$(git rev-parse "$b")
    for _ in $(seq 24); do
      [[ "$(get_pr_sha "$pr")" != "$sha" ]] || break
      sleep 5
    done
  fi
  echo "PR #$pr ($b): $FORGEJO_URL/$FORGEJO_REPO/pulls/$pr" >&2

  out=$("$0" merge "$pr") || rc=$?
  [[ -z "$out" ]] || printf '%s\n' "$out"
  if [[ $rc -eq 1 ]]; then
    sha=$(get_pr_sha "$pr")
    payload=$(fetch_status "$sha")
    failure_hints "$pr" <<<"$payload"
    # Contexts contain spaces ("CI / argocd-diff (pull_request)"): count in jq.
    failed=$(jq -r '[.statuses[]? | select((.status // .state) | IN("failure", "error")) | .context] | if length == 1 then .[0] else "" end' <<<"$payload")
    # Not `| grep -q`: an early grep exit SIGPIPEs the writer and pipefail reads a found gate as none.
    if [[ "$failed" == *argocd-diff* ]] && out=$(fresh_diff_body "$pr" "$sha" "$failed" 2>/dev/null) \
      && grep -q 'Blocked.*diff-reviewed' <<<"$out"; then
      return 5
    fi
  fi
  # merge exit 6 = no webhook seen: still wait for the apps, keep the 6.
  [[ $rc -eq 0 || $rc -eq 6 ]] || return "$rc"

  sha=$(jq -r '.merge_commit_sha // empty' <<<"$out")
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "PR #$pr merged, but no merge_commit_sha — run: $0 wait-apps <sha>" >&2; return 3; }
  wait_apps "$sha" || return $?
  return "$rc"
}

# ship <branch>... — each branch in a child (`set -e` stays on). Exit: the code
# that stopped it, else 5 if a PR was parked, else 0.
cmd_ship() {
  [[ $# -gt 0 ]] || die_usage
  local b rc parked=""
  while [[ $# -gt 0 ]]; do
    b="$1"; shift; rc=0
    "$0" full "$b" || rc=$?
    case $rc in
      0) echo "SHIPPED $b" >&2 ;;
      5) echo "PARKED $b (exit 5): its PR waits for the diff-reviewed label" >&2; parked+=" $b" ;;
      *) echo "SHIP STOPPED at $b (exit $rc); not shipped: ${*:-none}${parked:+; parked:$parked}" >&2
         return "$rc" ;;
    esac
  done
  [[ -z "$parked" ]] || { echo "parked at the review gate:$parked" >&2; return 5; }
}

cmd_wait_apps() {
  [[ -n "${1:-}" ]] || die_usage
  require jq
  wait_apps "$1"
}

cmd_get() {
  [[ -n "${1:-}" ]] || die_usage
  require curl
  forgejo_api GET "/api/v1/${1#/}"
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
  ship)           shift; cmd_ship    "$@" ;;
  wait-apps)      shift; cmd_wait_apps "$@" ;;
  get)            shift; cmd_get     "$@" ;;
  comment)        shift; cmd_comment "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  *)              die_usage ;;
esac
