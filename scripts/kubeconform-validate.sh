#!/usr/bin/env bash
# Validate Kubernetes manifests with kubeconform — both raw manifests under
# argocd/**/manifests + standalone Applications, and the rendered output of the
# homelab-common chart for every values file that uses it.
#
# Single source of truth shared by `.forgejo/workflows/ci.yaml` (kubeconform job)
# and `task ci:kubeconform`. Requires `kubeconform` and `helm` on PATH
# (provided by .mise.toml locally, or installed in CI).
#
# CRD schemas come from the datreeio/CRDs-catalog; kinds not in the catalog
# (tuppr TalosUpgrade/KubernetesUpgrade, Cilium BGP CRDs, …) are skipped via
# -ignore-missing-schemas instead of failing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

KUBE_VERSION="${KUBE_VERSION:-1.36.0}"
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

echo "==> Raw manifests (argocd/**/manifests, standalone, manifests)"
mapfile -t RAW < <(
  find argocd/apps argocd/infra -path '*/manifests/*.yaml' -type f
  find argocd/standalone argocd/manifests -name '*.yaml' -type f
)
if [ "${#RAW[@]}" -gt 0 ]; then
  kc "${RAW[@]}"
else
  echo "  (no raw manifests found)"
fi

echo "==> Rendered homelab-common"
fails=0
for f in argocd/apps/*/values.yaml argocd/apps/*/homelab-values.yaml argocd/apps/*/cnpg-values.yaml \
         argocd/infra/*/values.yaml argocd/infra/*/homelab-values.yaml \
         argocd/values/argocd.yaml; do
  [ -f "$f" ] || continue
  grep -qE '^homelab-common:|^global:' "$f" || continue
  if ! helm template test charts/homelab-common \
        -f argocd/values/global.yaml -f "$f" 2>/dev/null \
        | kc -; then
    echo "  FAIL: $f"
    fails=$((fails + 1))
  fi
done

if [ "$fails" -gt 0 ]; then
  echo "kubeconform: $fails rendered values file(s) failed validation"
  exit 1
fi
echo "kubeconform: clean"
