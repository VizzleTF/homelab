#!/usr/bin/env bash
# Phase 01 — CNI + Gateway API CRDs + Cilium + LB IPAM + BGP + Cilium Gateways.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl

GW_API_VERSION="v1.4.1"

log_info "applying Gateway API experimental CRDs ($GW_API_VERSION)"
kubectl apply --server-side --force-conflicts \
  -k "https://github.com/kubernetes-sigs/gateway-api/config/crd/experimental?ref=$GW_API_VERSION"

log_info "adding Cilium helm repo"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

log_info "installing/upgrading Cilium"
helm_apply cilium cilium/cilium kube-system \
  --version 1.19.4 \
  -f "$REPO_ROOT/argocd/infra/cilium/values.yaml"

wait_for "cilium DaemonSet Ready" \
  "kubectl -n kube-system rollout status ds/cilium --timeout=120s"

log_info "applying CiliumLoadBalancerIPPool"
kubectl apply -f "$REPO_ROOT/argocd/infra/cilium/manifests/cilium-lb-ippool.yaml"

log_info "applying CiliumBGP {ClusterConfig,PeerConfig,Advertisement}"
kubectl apply -f "$REPO_ROOT/argocd/infra/cilium/manifests/cilium-bgp.yaml"

log_info "applying Cilium Gateways (external + internal + tls-passthrough)"
kubectl apply -f "$REPO_ROOT/argocd/infra/cilium/manifests/cilium-gateway.yaml"
kubectl apply -f "$REPO_ROOT/argocd/infra/cilium/manifests/cilium-gateway-internal.yaml"
kubectl apply -f "$REPO_ROOT/argocd/infra/cilium/manifests/cilium-gateway-tls.yaml"

for gw in cilium-gateway cilium-gateway-internal cilium-gateway-tls; do
  wait_for "$gw Programmed" \
    "kubectl -n kube-system get gateway $gw -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' | grep -q True"
done

log_info "verifying BGP session established with OpenWrt"
cilium_pod=$(kubectl -n kube-system get pod -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
wait_for "BGP peer established" \
  "kubectl -n kube-system exec $cilium_pod -- cilium bgp peers 2>&1 | grep -q established" \
  60

log_ok "phase 01 network complete"
