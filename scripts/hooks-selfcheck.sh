#!/usr/bin/env bash
# Self-check of the Claude Code hooks in .claude/hooks on fixtures:
#   - validate-yaml.sh: files it must pass (each one a past false failure) and
#     files it must reject;
#   - helm-repo.sh: commands that do not read the local repo index pass, a stale
#     `<repo>/<chart>` read is flagged;
#   - bash-guard.py --selftest.
# Runs in the CI kubeconform job and in `task ci:kubeconform`; needs jq,
# yamllint, kubeconform, python3 and network for the kubeconform schemas.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1
tmp=$(mktemp -d "$PWD/hooks-selfcheck.XXXXXX")  # untracked, not ignored: like a new file
trap 'rm -rf "$tmp"' EXIT
rel=${tmp#"$PWD"/}
printf 'kind: DaemonSet\nreplicaCount: 1\n' > "$tmp/values.yaml"
printf 'a: [\n' > "$tmp/broken.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\nbogus: 1\n' > "$tmp/bad-manifest.yaml"
tpl=$(git ls-files 'charts/*/templates/*.yaml' | head -n1)

fail=0
report() {  # report <got> <want> <what> <why>
  if [[ $1 -eq $2 ]]; then echo "ok   exit $1: $3"; else echo "FAIL exit $1, want $2: $3 ($4)"; fail=1; fi
}
check() {  # check <want exit> <repo-relative file> <why>
  jq -nc --arg p "$PWD/$2" '{tool_input: {file_path: $p}}' | .claude/hooks/validate-yaml.sh >/dev/null 2>&1
  report $? "$1" "$2" "$3"
}
check_helm() {  # check_helm <want exit> <command> <why>; TMPDIR=$tmp holds no freshness marker
  jq -nc --arg c "$2" '{tool_input: {command: $c}}' \
    | TMPDIR=$tmp CLAUDE_PROJECT_DIR=$PWD .claude/hooks/helm-repo.sh >/dev/null 2>&1
  report $? "$1" "helm-repo: $2" "$3"
}

check 0 argocd/values/global.yaml "Helm values have no kind (bae15fb4)"
check 0 argocd/infra/tuppr/manifests/kubernetes-upgrade.yaml "kind skipped by kubeconform-validate.sh (a25a6c73)"
check 0 "$rel/values.yaml" "values with a top-level kind are not a manifest"
check 0 "$tpl" "Helm template, ignored by .yamllint.yml"
check 2 "$rel/broken.yaml" "YAML syntax error"
check 2 "$rel/bad-manifest.yaml" "unknown field under kubeconform -strict"

check_helm 0 "helm show values cilium --repo https://helm.cilium.io" "--repo does not read the local index"
check_helm 0 "helm template x charts/homelab-common -f argocd/values/global.yaml" "a chart path does not read the local index"
check_helm 2 "helm show values cilium/cilium" "repo/chart read with no fresh helm repo update"

python3 .claude/hooks/bash-guard.py --selftest || fail=1

[[ $fail -eq 0 ]] && echo "hooks-selfcheck: clean"
exit "$fail"
