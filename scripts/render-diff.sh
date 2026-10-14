#!/usr/bin/env bash
# What the branch changes in the rendered manifests of ArgoCD apps: renders each
# app with scripts/render-app.sh at <base> (default: merge-base with origin/main,
# like `git diff origin/main...`) in a temporary worktree and in the working tree
# (uncommitted edits included), then diffs object by object (one file per
# kind/namespace/name). CI argocd-diff renders the tip of main instead: rebase
# when main has moved under the same apps.
# First prints the CI review-gate summary (scripts/diff-review-gate.sh).
# Paths in the app's config.yaml ignoreDiff.jqPathExpressions are dropped on
# both sides (cilium regenerates its CA on every render).
# --hc-local renders the working tree with the local charts/homelab-common; the
# base keeps the published pin. homelab-common alone, all consumers:
# scripts/chart-diff.sh.
#
# Usage: scripts/render-diff.sh [--base <ref>] [--hc-local] [app ...]
#   no app: every app whose argocd/{apps,infra}/<app>/ differs from <base>,
#   argocd for argocd/standalone/argocd-application.yaml or argocd/values/, and
#   every app plus argocd for argocd/values/global.yaml or argocd/appsets/ (the
#   apps' watch-patterns in CI argocd-diff).
#   Run `git fetch` first when origin/main may be stale.
# Exit codes (3 wins over 1, 1 over 4):
#   0  nothing for the review gate (the diff, if any, is printed)
#   1  prunes a resource or changes a CRD: the PR needs `diff-reviewed`
#   2  usage error, or a render failed
#   3  head render is blind: the live app tracks objects that neither render
#      has (render-app.sh exit 3; a dropped source, or main moved past <base>)
#   4  changed files no app render covers (root's plain manifests, gateway-api,
#      the AppSet objects): read their `git diff`, CI argocd-diff renders them
set -euo pipefail

usage() { echo "usage: $0 [--base <ref>] [--hc-local] [app ...]" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
repo=$PWD base="" hc=""
while [[ ${1:-} == --* ]]; do
  case $1 in
    --base) [[ $# -ge 2 ]] || usage; base=$2; shift 2 ;;
    --hc-local) hc=1; shift ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done
if [[ -z $base ]]; then
  base=$(git merge-base origin/main HEAD) || { echo "no merge-base with origin/main" >&2; exit 2; }
fi
git rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "unknown ref: $base" >&2; exit 2; }
short=$(git rev-parse --short "$base")
tmp=$(mktemp -d)
trap 'git -C "$repo" worktree remove --force "$tmp/tree" 2>/dev/null; rm -rf "$tmp"' EXIT
# A TERM/INT that arrives mid-render (Bash tool timeout, TaskStop) skips the EXIT trap.
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
git worktree add -q --detach "$tmp/tree" "$base"

# --no-renames: a moved app folder must list both its old and its new name.
changed=$( { git diff --no-renames --name-only "$base" -- argocd/; git ls-files --others --exclude-standard argocd/; } | sort -u)
apps=("$@")
for a in "${apps[@]}"; do  # a typo must not pass as "no diff"
  found=$a; [[ $a == argocd ]] || found=$(ls {"$repo","$tmp/tree"}/argocd/{apps,infra}/"$a"/config.yaml 2>/dev/null || true)
  [[ -n $found ]] || { echo "no app $a at $short or in the working tree" >&2; exit 2; }
done
if [[ ${#apps[@]} -eq 0 ]]; then
  list=$( {
    sed -nE -e 's#^argocd/(apps|infra)/([^/]+)/.*#\2#p' -e 's#^argocd/(standalone/argocd-application\.yaml|values/.*)$#argocd#p' <<<"$changed"
    if grep -qE '^argocd/(values/global\.yaml|appsets/.*)$' <<<"$changed"; then
      for c in argocd/{apps,infra}/*/config.yaml; do basename "$(dirname "$c")"; done; echo argocd
    fi
  } | sort -u)
  while IFS= read -r a; do [[ -n $a ]] && apps+=("$a"); done <<<"$list"
fi
unrendered=$(grep -vE '^argocd/(apps|infra|values)/|^argocd/standalone/argocd-application\.yaml$' <<<"$changed" || true)
[[ -z $unrendered ]] || printf 'not rendered here (git diff; CI argocd-diff):\n%s\n' "$unrendered" >&2
[[ ${#apps[@]} -gt 0 ]] || { echo "no app differs from $short"; [[ -z $unrendered ]] || exit 4; exit 0; }
echo "==> ${apps[*]} ($short vs working tree)" >&2

# render <tree> <app> <HC_LOCAL> <side>: normalized manifests; nothing when the app is absent there.
render() {
  local cfg="" c ign="" rc=0
  for c in "$1"/argocd/{apps,infra}/"$2"/config.yaml; do [[ -f $c ]] && cfg=$c; done
  [[ -n $cfg || $2 == argocd ]] || return 0
  # shellcheck disable=SC2016  # $k/$n are yq variables
  [[ -n $cfg ]] && ign=$(yq -r '(.ignoreDiff // "[]") | from_yaml | .[] | select(.jqPathExpressions) | .kind as $k | (.name // "") as $n | .jqPathExpressions[] | "del(select(.kind == \"" + $k + "\" and (\"" + $n + "\" == \"\" or .metadata.name == \"" + $n + "\")) | " + . + ") |"' "$cfg")
  (cd "$1" && HC_LOCAL=$3 "$repo/scripts/render-app.sh" "$2") > "$tmp/raw.yaml" 2> "$tmp/err" || rc=$?
  [[ $4 == base ]] || cat "$tmp/err" >&2
  case $rc in
    0) ;;
    # The guard's list closes stderr. On the base side it is expected: the
    # merge-base lags the live main.
    3) [[ $4 == base ]] || sed -n '/^warning: live app/,$p' "$tmp/err" | tail -n +2 >> "$tmp/missing" ;;
    *) [[ $4 == head ]] || cat "$tmp/err" >&2
       echo "render failed: $2 at $4 (render-app.sh exit $rc)" >&2; exit 2 ;;
  esac
  # no -N: it would glue the documents together
  yq "select(.kind) | $ign sort_keys(..)" "$tmp/raw.yaml" || exit 2
}

: > "$tmp/missing"
for side in base head; do
  for app in "${apps[@]}"; do
    if [[ $side == base ]]; then render "$tmp/tree" "$app" "" base; else render "$repo" "$app" "$hc" head; fi
    echo ---
  done > "$tmp/$side.yaml"
  mkdir "$tmp/$side"
  (cd "$tmp/$side" && yq -N -s '.kind + "_" + (.metadata.namespace // "") + "_" + .metadata.name' 'select(.kind)' "$tmp/$side.yaml")
done

rc=0
scripts/diff-review-gate.sh "$tmp/base.yaml" "$tmp/head.yaml" || rc=1
diff -ruN "$tmp/base" "$tmp/head" | sed "s#$tmp/##g" || true
# Live objects the base renders are the change's removals, listed by the gate above.
blind=$(comm -23 <(sort -u "$tmp/missing") <(yq -N -r 'select(.kind) | .kind + "/" + .metadata.name' "$tmp/base.yaml" | sort -u))
if [[ -n $blind ]]; then
  printf 'blind render: live objects neither %s nor the working tree renders (dropped source, or rebase on origin/main):\n%s\n' "$short" "$blind" >&2
  rc=3
elif [[ $rc -eq 0 && -n $unrendered ]]; then
  rc=4
fi
exit "$rc"
