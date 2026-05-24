#!/usr/bin/env bash
# Phase 10 — ArgoCD bootstrap + adoption.
# Vault now holds the Forgejo SSH key + every repo cred ArgoCD needs, so
# ArgoCD can be installed straight against the internal Forgejo URL.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

kubectl create ns argocd 2>/dev/null || true

log_info "installing ArgoCD chart with homelab values"
helm_apply argocd argo/argo-cd argocd \
  --version 9.5.15 \
  -f "$REPO_ROOT/argocd/values/infrastructure/argocd.yaml"

wait_for "argocd-server Ready" \
  "kubectl -n argocd rollout status deploy/argocd-server --timeout=300s"
wait_for "argocd-repo-server Ready" \
  "kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s"

# We need a brief wait for ESO to populate argocd-repo-ssh-forgejo-* Secrets
# before applying the root project + Application.
wait_for "argocd-repo-ssh-forgejo-root Secret synced" \
  "kubectl -n argocd get secret argocd-repo-ssh-forgejo-root >/dev/null 2>&1" \
  120

log_info "applying AppProjects + standalone infra Apps + root-application"
kubectl apply -f "$REPO_ROOT/argocd/infrastructure/root-project.yaml"
kubectl apply -f "$REPO_ROOT/argocd/infrastructure/infrastructure-project.yaml"
kubectl apply -f "$REPO_ROOT/argocd/applications/applications-project.yaml"
kubectl apply -f "$REPO_ROOT/argocd/infrastructure/argocd-application.yaml"
kubectl apply -f "$REPO_ROOT/argocd/root-application.yaml"

log_info "kicking root Application sync"
kubectl -n argocd annotate app root argocd.argoproj.io/refresh=hard --overwrite >/dev/null

log_ok "phase 10 argocd complete — ApplicationSets will now render the rest of the cluster"
