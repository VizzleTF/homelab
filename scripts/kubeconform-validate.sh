#!/usr/bin/env bash
# Validate manifests with kubeconform. No args: render local charts/homelab-common
# for every values file using it (render or values-schema failure fails too) —
# the only check that sees an unpublished chart change. File args: validate only
# those (argocd-diff passes the rendered target branch; the
# .claude/hooks/validate-yaml.sh file mode needs only kubeconform).
# Raw manifests (argocd/**/manifests, argocd/standalone) get no schema check here
# (argocd-diff validates them) but a pluto pass that fails on deprecated or
# removed apiVersions (.pluto-versions.yaml).
# Shared by .forgejo/workflows/ci.yaml, `task ci:kubeconform` and that hook.
# Needs kubeconform, helm, pluto on PATH (.mise.toml locally).
# CRD schemas: datreeio/CRDs-catalog; kinds missing there are skipped.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Pinned, not read from the cluster version: yannh/kubernetes-json-schema
# publishes a new minor late, and -ignore-missing-schemas would turn a missing
# version into a silent skip of every core kind. Bump once the schemas exist.
KUBE_VERSION="${KUBE_VERSION:-1.37.0}"
CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# tuppr's catalog schema lags upstream (no maintenance/drain/parallelism), so
# -strict false-fails; the schema exists, so -ignore-missing-schemas can't help.
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

command -v pluto >/dev/null || { echo "pluto not on PATH" >&2; exit 1; }

echo "==> Rendered homelab-common"
fails=0
for f in argocd/apps/*/values.yaml argocd/apps/*/homelab-values.yaml \
         argocd/infra/*/values.yaml argocd/infra/*/homelab-values.yaml \
         argocd/values/argocd.yaml; do
  [[ -f "$f" ]] || continue
  grep -qE '^homelab-common:|^global:' "$f" || continue
  # Release and namespace as ArgoCD sets them: the vaultPath assert (2.2) checks
  # paths against the release namespace.
  cls=()
  if [[ $f == argocd/values/argocd.yaml ]]; then
    app=argocd ns=argocd
  else
    cls=(-f "argocd/values/$(cut -d/ -f2 <<<"$f").yaml")  # apps.yaml / infra.yaml
    dir=$(dirname "$f") app=$(basename "$(dirname "$f")")
    ns=$(sed -n 's/^namespace:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$dir/config.yaml")
    ns=${ns:-$app}
  fi
  if ! helm template "$app" charts/homelab-common --namespace "$ns" \
        -f argocd/values/global.yaml "${cls[@]}" -f "$f" \
        | kc -; then
    echo "  FAIL: $f"
    fails=$((fails + 1))
  fi
done

echo "==> pluto: deprecated APIs in raw manifests"
# pluto targets the cluster's k8s version (tuppr, Renovate-tracked): rules need no schemas.
K8S=$(sed -n 's/^[[:space:]]*version:[[:space:]]*\(v[^[:space:]]*\).*/\1/p' argocd/infra/tuppr/manifests/kubernetes-upgrade.yaml)
CILIUM=$(sed -n 's/^targetRevision:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' argocd/infra/cilium/config.yaml)
[[ -n "$K8S" && -n "$CILIUM" ]] || { echo "cannot read k8s/cilium version for pluto" >&2; exit 1; }
if ! pluto detect-files -d argocd -o wide -f .pluto-versions.yaml \
      -t "k8s=${K8S},cilium=v${CILIUM}"; then
  echo "  FAIL: deprecated/removed apiVersion in argocd/ (see table above)"
  fails=$((fails + 1))
fi

if [[ "$fails" -gt 0 ]]; then
  echo "kubeconform: $fails check(s) failed"
  exit 1
fi
echo "kubeconform: clean"
