#!/usr/bin/env bash
# Review gate for the argocd-diff CI job. Exits 1 when a PR would prune a
# resource or change a CustomResourceDefinition: both render cleanly, so every
# other check stays green and automerge would ship them unread. A human reads
# the diff and adds the `diff-reviewed` label to let the PR through.
#
# Inputs are argocd-diff-preview --output-branch-manifests files. Both hold the
# same set of Applications (the ones the PR touches), so a resource missing from
# target is one ArgoCD will prune. Requires yq (mikefarah).
#
# Usage: scripts/diff-review-gate.sh output/base-branch.yaml output/target-branch.yaml
set -euo pipefail

base=${1:?usage: $0 base-branch.yaml target-branch.yaml}
target=${2:?usage: $0 base-branch.yaml target-branch.yaml}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ids() { yq -N 'select(.kind) | .kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name' "$1" | sort -u; }

# One file per CRD, so `diff -rq` names exactly the CRDs that changed.
split_crds() {
  mkdir -p "$2"
  (cd "$2" && yq -N -s '.metadata.name + ".yaml"' 'select(.kind == "CustomResourceDefinition")' "$1")
}

fail=0

removed=$(comm -23 <(ids "$base") <(ids "$target"))
if [[ -n "$removed" ]]; then
  echo "Resources removed (ArgoCD will prune them):"
  sed 's/^/- /' <<<"$removed"
  fail=1
fi

split_crds "$(realpath "$base")" "$work/base"
split_crds "$(realpath "$target")" "$work/target"
crds=$(diff -rq "$work/base" "$work/target" | sed -E 's#^Only in .*/base: (.+)\.yaml$#removed: \1#; s#^Only in .*/target: (.+)\.yaml$#added: \1#; s#^Files .*/([^/]+)\.yaml and .* differ$#changed: \1#' || true)
if [[ -n "$crds" ]]; then
  echo "CustomResourceDefinitions changed:"
  sed 's/^/- /' <<<"$crds"
  fail=1
fi

exit "$fail"
