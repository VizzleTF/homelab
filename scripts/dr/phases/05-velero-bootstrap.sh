#!/usr/bin/env bash
# Phase 05 — Velero (minimal bootstrap install) so we can pull the Raft
# snapshot from S3 if the DR pack copy is stale. After Vault restore the
# regular ESO-managed velero creds replace the manually-created Secrets.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl
load_bootstrap_env
require_env GARAGE_VELERO_ACCESS_KEY
require_env GARAGE_VELERO_SECRET

helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update vmware-tanzu >/dev/null

kubectl create ns velero 2>/dev/null || true
kubectl label ns velero pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null

log_info "creating velero-garage-creds Secret"
kubectl -n velero create secret generic velero-garage-creds \
  --from-literal=cloud="[default]
aws_access_key_id = $GARAGE_VELERO_ACCESS_KEY
aws_secret_access_key = $GARAGE_VELERO_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if [ -n "${OVH_S3_ACCESS_KEY:-}" ] && [ -n "${OVH_S3_SECRET_KEY:-}" ]; then
  log_info "creating velero-ovh-creds Secret (secondary BSL)"
  kubectl -n velero create secret generic velero-ovh-creds \
    --from-literal=cloud="[default]
aws_access_key_id = $OVH_S3_ACCESS_KEY
aws_secret_access_key = $OVH_S3_SECRET_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

log_info "applying node-agent-config (drop loadAffinity — all nodes CP)"
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: {name: node-agent-config, namespace: velero}
data:
  node-agent-config: |
    {"loadConcurrency":{"globalConfig":2}}
EOF

log_info "installing Velero"
helm_apply velero vmware-tanzu/velero velero \
  --version 12.0.1 \
  -f "$REPO_ROOT/argocd/infra/velero/values.yaml" \
  --set 'nodeAgent.nodeSelector=null' \
  --set metrics.serviceMonitor.enabled=false

wait_for "velero deployment Ready" \
  "kubectl -n velero rollout status deploy/velero --timeout=180s"

wait_for "BSL garage-default Available" \
  "kubectl -n velero get backupstoragelocation garage-default -o jsonpath='{.status.phase}' | grep -q Available" \
  120

log_ok "phase 05 velero-bootstrap complete"
