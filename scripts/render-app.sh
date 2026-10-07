#!/usr/bin/env bash
# Render one ApplicationSet app the way ArgoCD does and print the manifests to
# stdout. Sources mirror argocd/appsets/{apps,infra}-appset.yaml:
#   1. upstream chart (repoURL/chart/targetRevision from config.yaml) with
#      values.yaml — skipped when homelabOnly: true
#   2. cloudnative-pg/cluster with cnpgValuesFile — when set (apps only)
#   3. homelab-common with global.yaml + values.yaml (or homelabValuesFile) —
#      the WHOLE file, the chart reads its `homelab-common:` key itself
#   4. raw manifests/*.yaml — when extraManifests: true
# homelab-common comes from the Forgejo chart-museum at the version pinned in
# the appset (what ArgoCD deploys); HC_LOCAL=1 uses charts/homelab-common
# instead (to preview an unpublished chart change).
#
# Usage: scripts/render-app.sh <app>
# Requires helm and yq (.mise.toml); kubectl for the cluster capabilities.
set -euo pipefail

usage() { echo "usage: $0 <app>  (folder name under argocd/apps or argocd/infra)" >&2; exit 2; }
[[ $# -eq 1 ]] || usage

cd "$(git rev-parse --show-toplevel)"
app="$1"
if [[ -f "argocd/apps/$app/config.yaml" ]]; then kind=apps
elif [[ -f "argocd/infra/$app/config.yaml" ]]; then kind=infra
else echo "no argocd/{apps,infra}/$app/config.yaml" >&2; exit 1; fi

dir="argocd/$kind/$app"
cfg="$dir/config.yaml"
appset="argocd/appsets/$kind-appset.yaml"
get() { yq -r ".$1 // \"\"" "$cfg"; }
ns=$(get namespace); ns=${ns:-$app}

# Like ArgoCD, pass the cluster's version and API groups so charts that gate on
# .Capabilities (cilium GatewayClass, VAPs) render the same; offline = without.
caps=()
if kv=$(kubectl version -o json --request-timeout=5s 2>/dev/null | yq -r '.serverVersion.gitVersion'); then
  caps+=(--kube-version "$kv")
  # api-resources columns: NAME [SHORTNAMES] APIVERSION NAMESPACED KIND
  while read -r gv kind; do caps+=(--api-versions "$gv" --api-versions "$gv/$kind"); done \
    < <(kubectl api-resources --no-headers --request-timeout=10s | awk '{print $(NF-2), $NF}' | sort -u)
else
  echo "warning: cluster unreachable, rendering without --kube-version/--api-versions" >&2
fi

# ArgoCD names the Helm release after the app.
tpl() { helm template "$app" "$@" --namespace "$ns" --include-crds "${caps[@]}"; }

if [[ "$(get homelabOnly)" != "true" ]]; then
  repo=$(get repoURL); chart=$(get chart); chart=${chart:-$app}
  if [[ "$repo" == http* ]]; then
    tpl "$chart" --repo "$repo" --version "$(get targetRevision)" -f "$dir/values.yaml"
  else  # scheme-less repoURL = OCI registry
    tpl "oci://$repo/$chart" --version "$(get targetRevision)" -f "$dir/values.yaml"
  fi
fi

if [[ $kind == apps && -n "$(get cnpgValuesFile)" ]]; then
  cnpg_ver=$(grep -A2 'chart: cluster' "$appset" | sed -n 's/.*targetRevision: "\(.*\)"/\1/p')
  tpl cluster --repo https://cloudnative-pg.github.io/charts --version "$cnpg_ver" \
    -f "$dir/$(get cnpgValuesFile)"
fi

hcv=$(get homelabValuesFile); hc_values="$dir/${hcv:-values.yaml}"
if [[ "${HC_LOCAL:-}" == 1 ]]; then
  tpl charts/homelab-common -f argocd/values/global.yaml -f "$hc_values"
else
  hc_ver=$(grep -A1 'chart: homelab-common' "$appset" | sed -n 's/.*targetRevision: "\(.*\)"/\1/p')
  tpl homelab-common --repo https://git.example.com/api/packages/vizzle/helm --version "$hc_ver" \
    -f argocd/values/global.yaml -f "$hc_values"
fi

if [[ "$(get extraManifests)" == "true" ]]; then
  for f in "$dir"/manifests/*.{yaml,yml,json}; do
    [[ -f "$f" ]] || continue
    echo "---"; echo "# Source: $f"; cat "$f"; echo  # echo: file may lack a trailing newline
  done
fi
