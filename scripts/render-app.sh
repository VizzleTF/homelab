#!/usr/bin/env bash
# Render one ApplicationSet app as ArgoCD does, manifests to stdout. Sources
# mirror argocd/appsets/{apps,infra}-appset.yaml:
#   1. upstream chart (config.yaml) with values.yaml — unless homelabOnly: true
#   2. homelab-common with global.yaml + {apps,infra}.yaml + the WHOLE values.yaml (or
#      homelabValuesFile); the chart reads its `homelab-common:` key itself
#   3. raw manifests/*.yaml — when extraManifests: true
# homelab-common is the appset-pinned chart-museum version; HC_LOCAL=1 uses
# charts/homelab-common. `argocd` renders the standalone argocd Application.
# Requires helm and yq (.mise.toml); kubectl for the cluster capabilities.
# Exit 3: the live Application tracks objects this render lacks (removed by the
# change, or a dropped source); list on stderr.
set -euo pipefail

usage() { echo "usage: $0 <app>  (folder name under argocd/apps or argocd/infra, or argocd)" >&2; exit 2; }
[[ $# -eq 1 ]] || usage

cd "$(git rev-parse --show-toplevel)"
app="$1"
std=""
case $app in
  argocd) std=argocd/standalone/argocd-application.yaml; ns=argocd ;;
  *)
    if [[ -f "argocd/apps/$app/config.yaml" ]]; then kind=apps
    elif [[ -f "argocd/infra/$app/config.yaml" ]]; then kind=infra
    else echo "no argocd/{apps,infra}/$app/config.yaml (standalone: argocd)" >&2; exit 1; fi
    dir="argocd/$kind/$app"
    cfg="$dir/config.yaml"
    appset="argocd/appsets/$kind-appset.yaml"
    get() { yq -r ".$1 // \"\"" "$cfg"; }
    ns=$(get namespace); ns=${ns:-$app} ;;
esac

# Like ArgoCD, pass the cluster's version and API groups so charts that gate on
# .Capabilities (cilium GatewayClass, VAPs) render the same; offline = without.
caps=()
if kv=$(kubectl version -o json --request-timeout=5s 2>/dev/null | yq -r '.serverVersion.gitVersion'); then
  caps+=(--kube-version "$kv")
  # api-resources columns: NAME [SHORTNAMES] APIVERSION NAMESPACED KIND
  while read -r gv res_kind; do caps+=(--api-versions "$gv" --api-versions "$gv/$res_kind"); done \
    < <(kubectl api-resources --no-headers --request-timeout=10s | awk '{print $(NF-2), $NF}' | sort -u)
else
  echo "warning: cluster unreachable, rendering without --kube-version/--api-versions" >&2
fi

# ArgoCD names the Helm release after the app.
tpl() { helm template "$app" "$@" --namespace "$ns" --include-crds "${caps[@]}"; }

out=$(mktemp); trap 'rm -f "$out"' EXIT
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP  # else a signal mid-render skips EXIT
{
  if [[ -n "$std" ]]; then
    # Standalone argocd: argo-cd chart + homelab-common, versions from its Application.
    src() { yq -r ".spec.sources[$1].$2" "$std"; }
    tpl "$(src 0 chart)" --repo "$(src 0 repoURL)" --version "$(src 0 targetRevision)" -f argocd/values/argocd.yaml
    if [[ "${HC_LOCAL:-}" == 1 ]]; then hc=(charts/homelab-common)
    else hc=(homelab-common --repo "$(src 1 repoURL)" --version "$(src 1 targetRevision)"); fi
    tpl "${hc[@]}" -f argocd/values/global.yaml -f argocd/values/argocd.yaml
  else
    if [[ "$(get homelabOnly)" != "true" ]]; then
      repo=$(get repoURL); chart=$(get chart)
      if [[ "$repo" == http* ]]; then
        tpl "$chart" --repo "$repo" --version "$(get targetRevision)" -f "$dir/values.yaml"
      else  # scheme-less repoURL = OCI registry
        tpl "oci://$repo/$chart" --version "$(get targetRevision)" -f "$dir/values.yaml"
      fi
    fi

    hcv=$(get homelabValuesFile); hc_values="$dir/${hcv:-values.yaml}"
    # Absent on a base older than the class files (render-diff.sh renders it with this script).
    class_values=(); [[ -f "argocd/values/$kind.yaml" ]] && class_values=(-f "argocd/values/$kind.yaml")
    if [[ "${HC_LOCAL:-}" == 1 ]]; then
      tpl charts/homelab-common -f argocd/values/global.yaml "${class_values[@]}" -f "$hc_values"
    else
      hc_ver=$(grep -A1 'chart: homelab-common' "$appset" | sed -n 's/.*targetRevision: "\(.*\)"/\1/p')
      tpl homelab-common --repo https://git.example.com/api/packages/vizzle/helm --version "$hc_ver" \
        -f argocd/values/global.yaml "${class_values[@]}" -f "$hc_values"
    fi

    if [[ "$(get extraManifests)" == "true" ]]; then
      for f in "$dir"/manifests/*.{yaml,yml,json}; do
        [[ -f "$f" ]] || continue
        echo "---"; echo "# Source: $f"; cat "$f"; echo  # echo: file may lack a trailing newline
      done
    fi
  fi
} | tee "$out"

# Blind-render guard (cd7f7f55: a shadowed variable dropped a whole source).
# requiresPruning objects are already gone from git. Not the jsonpath filter
# ?(@.requiresPruning!=true): it matches nothing when the field is absent.
# shortcut: misses a dropped source with no live objects yet; upgrade if a new-app render goes blind.
if [[ ${#caps[@]} -gt 0 ]]; then
  missing=$(comm -13 <(yq -N -r 'select(.kind) | .kind + "/" + .metadata.name' "$out" | sort -u) \
    <(kubectl -n argocd get app "$app" -o json 2>/dev/null \
      | yq -p json -r '.status.resources[]? | select(.requiresPruning != true) | .kind + "/" + .name' | sort -u))
  [[ -z $missing ]] || { printf 'warning: live app %s tracks objects missing from this render (removed by the change, or the render is blind):\n%s\n' "$app" "$missing" >&2; exit 3; }
fi
