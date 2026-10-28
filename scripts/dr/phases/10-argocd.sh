#!/usr/bin/env bash
# Phase 10 — ArgoCD bootstrap + adoption.
# Forgejo runs on the ops node outside the cluster and must answer before ArgoCD
# starts; if not, recover it first (obsidian/113 Backups/Forgejo Recovery.md).

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

log_info "checking Forgejo on the ops node (git.example.com)"
curl -fsS --max-time 10 https://git.example.com/api/healthz >/dev/null \
  || die "git.example.com does not answer — ArgoCD has no source. Fix the ops node first: obsidian/113 Backups/Forgejo Recovery.md"
log_ok "Forgejo reachable"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

kubectl create ns argocd 2>/dev/null || true

ARGOCD_CHART_VERSION="$(chart_version standalone/argocd-application.yaml '.spec.sources[] | select(.chart == "argo-cd") | .targetRevision')"
log_info "installing ArgoCD chart with homelab values"
helm_apply argocd argo/argo-cd argocd \
  --version "$ARGOCD_CHART_VERSION" \
  -f "$REPO_ROOT/argocd/values/argocd.yaml"

wait_for "argocd-server Ready" \
  "kubectl -n argocd rollout status deploy/argocd-server --timeout=300s"
wait_for "argocd-repo-server Ready" \
  "kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s"

# The repo-creds ExternalSecret comes from the standalone argocd app, which
# cannot render without those creds ($values is the SSH monorepo): apply the
# ESO objects from a local render first; ArgoCD adopts them.
HC_VERSION="$(chart_version standalone/argocd-application.yaml '.spec.sources[] | select(.chart == "homelab-common") | .targetRevision')"
log_info "applying the argocd SecretStore + repo-creds ExternalSecret (homelab-common $HC_VERSION)"
helm template argocd homelab-common --repo https://git.example.com/api/packages/vizzle/helm \
  --version "$HC_VERSION" --namespace argocd \
  -f "$REPO_ROOT/argocd/values/global.yaml" -f "$REPO_ROOT/argocd/values/argocd.yaml" \
  | yq 'select(.kind == "ServiceAccount" or .kind == "SecretStore" or (.kind == "ExternalSecret" and .metadata.name == "argocd-repo-creds-forgejo"))' \
  | kubectl apply -f -

# The root project + Application need the Forgejo repo-creds template (all AppProjects).
wait_for "argocd-repo-creds-forgejo Secret synced" \
  "kubectl -n argocd get secret argocd-repo-creds-forgejo >/dev/null 2>&1" \
  120

# Drop the phase 03/04 bootstrap Secrets so every value comes from OpenBao with
# no DR-only label left; ESO recreates them on sync, running pods keep their env.
log_info "deleting DR bootstrap Secrets (ESO takes over)"
kubectl delete secret -A -l homelab.dr/bootstrap=true --ignore-not-found >/dev/null

log_info "applying AppProjects + standalone infra Apps + root-application"
kubectl apply -f "$REPO_ROOT/argocd/projects/root-project.yaml"
kubectl apply -f "$REPO_ROOT/argocd/projects/infrastructure-project.yaml"
kubectl apply -f "$REPO_ROOT/argocd/projects/applications-project.yaml"
kubectl apply -f "$REPO_ROOT/argocd/standalone/argocd-application.yaml"
kubectl apply -f "$REPO_ROOT/argocd/root-application.yaml"

log_info "kicking root Application sync"
kubectl -n argocd annotate app root argocd.argoproj.io/refresh=hard --overwrite >/dev/null

# ArgoCD now owns the helm-installed objects; the release records only confuse `helm list`.
log_info "deleting bootstrap helm release records (ArgoCD owns the objects)"
kubectl delete secret -A -l owner=helm --ignore-not-found >/dev/null

log_ok "phase 10 argocd complete — ApplicationSets will now render the rest of the cluster"
