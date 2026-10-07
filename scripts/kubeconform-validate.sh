#!/usr/bin/env bash
# Validate Kubernetes manifests with kubeconform: the rendered output of the
# homelab-common chart from the local charts/ source, for every values file that
# uses it (a render or values-schema failure fails the run too). ArgoCD deploys
# the published chart version, so this is the only check that sees an
# unpublished chart change.
#
# Raw manifests (argocd/**/manifests, argocd/standalone) are not schema-checked
# here: the argocd-diff CI job validates them as part of the full rendered output
# of every Application the PR touches. They do get a pluto pass (below) that fails
# on any deprecated or removed apiVersion, rules from .pluto-versions.yaml, so a
# stale API (e.g. cilium.io/v2alpha1 BGP kinds) is caught in the PR that adds it.
#
# Single source of truth shared by `.forgejo/workflows/ci.yaml` (kubeconform job)
# and `task ci:kubeconform`. Requires `kubeconform`, `helm` and `pluto` on PATH
# (provided by .mise.toml locally, or installed in CI).
#
# With file arguments it validates only those files (the argocd-diff CI job
# passes the fully rendered target branch), using the same flags.
#
# CRD schemas come from the datreeio/CRDs-catalog; kinds not in the catalog
# (tuppr TalosUpgrade/KubernetesUpgrade, Cilium BGP CRDs, …) are skipped via
# -ignore-missing-schemas instead of failing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
command -v pluto >/dev/null || { echo "pluto not on PATH" >&2; exit 1; }

KUBE_VERSION="${KUBE_VERSION:-1.37.0}"
CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# tuppr CRDs (KubernetesUpgrade/TalosUpgrade) live in the catalog but its
# schema lags upstream (missing maintenance/drain/parallelism) → -strict would
# false-fail valid manifests. -ignore-missing-schemas can't help (schema exists),
# so skip these kinds explicitly.
SKIP_KINDS="${SKIP_KINDS:-KubernetesUpgrade,TalosUpgrade}"

kc() {
  kubeconform \
    -strict \
    -summary \
    -ignore-missing-schemas \
    -skip "$SKIP_KINDS" \
    -kubernetes-version "$KUBE_VERSION" \
    -schema-location default \
    -schema-location "$CATALOG" \
    "$@"
}

if [[ "$#" -gt 0 ]]; then
  echo "==> $*"
  kc "$@"
  exit
fi

echo "==> Rendered homelab-common"
fails=0
for f in argocd/apps/*/values.yaml argocd/apps/*/homelab-values.yaml argocd/apps/*/cnpg-values.yaml \
         argocd/infra/*/values.yaml argocd/infra/*/homelab-values.yaml \
         argocd/values/argocd.yaml; do
  [[ -f "$f" ]] || continue
  grep -qE '^homelab-common:|^global:' "$f" || continue
  if ! helm template test charts/homelab-common \
        -f argocd/values/global.yaml -f "$f" \
        | kc -; then
    echo "  FAIL: $f"
    fails=$((fails + 1))
  fi
done

echo "==> pluto: deprecated APIs in raw manifests"
CILIUM=$(sed -n 's/^targetRevision:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' argocd/infra/cilium/config.yaml)
if ! pluto detect-files -d argocd -o wide -f .pluto-versions.yaml \
      -t "k8s=v${KUBE_VERSION},cilium=v${CILIUM}"; then
  echo "  FAIL: deprecated/removed apiVersion in argocd/ (see table above)"
  fails=$((fails + 1))
fi

if [[ "$fails" -gt 0 ]]; then
  echo "kubeconform: $fails check(s) failed"
  exit 1
fi
echo "kubeconform: clean"
