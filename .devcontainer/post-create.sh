#!/usr/bin/env bash
# Idempotent first-run + reopen setup.
# Repos sourced from .claude/reference/helm-repos.md and argocd/{applications,infrastructure}/*-appset.yaml.
# Don't add chart-version pins here — appsets are the single source of truth.

set -euo pipefail

echo "[post-create] Adding helm repositories..."
declare -A REPOS=(
  [argo]="https://argoproj.github.io/argo-helm"
  [bitnami]="https://charts.bitnami.com/bitnami"
  [christianhuth]="https://charts.christianhuth.de"
  [cilium]="https://helm.cilium.io"
  [cnpg]="https://cloudnative-pg.github.io/charts"
  [community-charts]="https://community-charts.github.io/helm-charts"
  [descheduler]="https://kubernetes-sigs.github.io/descheduler"
  [external-dns]="https://kubernetes-sigs.github.io/external-dns"
  [external-secrets]="https://charts.external-secrets.io"
  [goauthentik]="https://charts.goauthentik.io"
  [guerzon]="https://guerzon.github.io/vaultwarden"
  [hashicorp]="https://helm.releases.hashicorp.com"
  [immich]="https://immich-app.github.io/immich-charts"
  [intel]="https://intel.github.io/helm-charts"
  [jetstack]="https://charts.jetstack.io"
  [kedacore]="https://kedacore.github.io/charts"
  [kubelet-csr-approver]="https://postfinance.github.io/kubelet-csr-approver"
  [lampac]="https://vizzletf.github.io/lampac_helm"
  [longhorn]="https://charts.longhorn.io"
  [metrics-server]="https://kubernetes-sigs.github.io/metrics-server"
  [nextcloud]="https://nextcloud.github.io/helm"
  [nfd]="https://kubernetes-sigs.github.io/node-feature-discovery/charts"
  [renovate]="https://docs.renovatebot.com/helm-charts"
  [robusta]="https://robusta-charts.storage.googleapis.com"
  [vault-autounseal]="https://pytoshka.github.io/vault-autounseal"
  [victoria-metrics]="https://victoriametrics.github.io/helm-charts"
)
for name in "${!REPOS[@]}"; do
  helm repo add "$name" "${REPOS[$name]}" --force-update >/dev/null
done
helm repo update >/dev/null
echo "[post-create] $(helm repo list | tail -n +2 | wc -l) helm repos configured."

echo "[post-create] Caching MCP server npm packages..."
# Pre-install globally so the first `claude` invocation (which uses `npx -y ...`
# under the hood) finds them in the global prefix and doesn't fetch on demand.
# `npx --help` doesn't work as a warm-up — stdio MCP servers block on stdin.
npm install -g --silent \
  @modelcontextprotocol/server-github \
  kubernetes-mcp-server \
  2>&1 | tail -3 || true

echo "[post-create] Installing pre-commit hooks..."
if [ -f /workspaces/homelab/.pre-commit-config.yaml ]; then
  (cd /workspaces/homelab && pre-commit install --install-hooks >/dev/null)
fi

echo "[post-create] Done. Run 'claude' to start."
