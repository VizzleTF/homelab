#!/usr/bin/env bash
# Show what an unpublished homelab-common change does to every consumer:
# render each values file with the published version pinned in the AppSets
# (what ArgoCD runs) and with the local charts/homelab-common, then diff.
# argocd-diff in CI only sees the change later, in the PR that bumps the pin.
#
# Usage: scripts/chart-diff.sh [--stat]
#   --stat  print only the changed-line count per consumer
# Exit 1 if a render fails; differences alone are not an error.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
stat=0; [[ "${1:-}" == --stat ]] && stat=1

pin=$(grep -A1 'chart: homelab-common' argocd/appsets/apps-appset.yaml | sed -n 's/.*targetRevision: "\(.*\)"/\1/p')
[[ -n "$pin" ]] || { echo "homelab-common pin not found in apps-appset.yaml" >&2; exit 1; }
local_ver=$(sed -n 's/^version:[[:space:]]*//p' charts/homelab-common/Chart.yaml)
echo "==> homelab-common published $pin vs local charts/ ($local_ver)"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
helm pull homelab-common --repo https://git.example.com/api/packages/vizzle/helm --version "$pin" -d "$tmp" >/dev/null

changed=0
for f in argocd/apps/*/values.yaml argocd/apps/*/homelab-values.yaml \
         argocd/infra/*/values.yaml argocd/infra/*/homelab-values.yaml \
         argocd/values/argocd.yaml; do
  [[ -f "$f" ]] || continue
  grep -qE '^homelab-common:' "$f" || continue
  app=$(basename "$(dirname "$f")"); [[ "$f" == argocd/values/argocd.yaml ]] && app=argocd
  ns=$(sed -n 's/^namespace:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$(dirname "$f")/config.yaml" 2>/dev/null || true)
  ns=${ns:-$app}
  render() { helm template "$app" "$1" --namespace "$ns" -f argocd/values/global.yaml -f "$f"; }
  render "$tmp/homelab-common-$pin.tgz" > "$tmp/old.yaml"
  render charts/homelab-common > "$tmp/new.yaml"
  if ! diff -q "$tmp/old.yaml" "$tmp/new.yaml" >/dev/null; then
    changed=$((changed + 1))
    n=$(diff "$tmp/old.yaml" "$tmp/new.yaml" | grep -c '^[<>]' || true)
    echo "--- $f: $n line(s)"
    [[ $stat == 1 ]] || diff -u --label "$pin" --label local "$tmp/old.yaml" "$tmp/new.yaml" || true
  fi
done
echo "==> $changed consumer(s) change"
