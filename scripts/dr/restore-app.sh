#!/usr/bin/env bash
# scripts/dr/restore-app.sh — restore a single application from its latest
# Velero backup, handling known gotchas (nodeAffinity, PVC volumeName drift,
# DB ownership, kopia helper pod fallback).
#
# Usage:
#   scripts/dr/restore-app.sh <app-name> [backup-name]

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

APP="${1:-}"
BACKUP_NAME="${2:-}"
[ -n "$APP" ] || die "usage: $0 <app-name> [backup-name]"

require_kubectl

# 1. Find latest Completed backup if not supplied
if [ -z "$BACKUP_NAME" ]; then
  BACKUP_NAME=$(kubectl -n velero exec deploy/velero -- /velero backup get 2>/dev/null \
    | awk -v app="${APP}-daily-" '$1 ~ "^"app && $2 == "Completed" {print $1}' \
    | sort | tail -1)
  [ -n "$BACKUP_NAME" ] || die "no Completed ${APP}-daily-* backup found"
fi
log_info "$APP <- $BACKUP_NAME"

# 2. Ensure namespace exists + privileged label
kubectl create ns "$APP" 2>/dev/null || true
kubectl label ns "$APP" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null

# 3. Some app Pods carry nodeAffinity for `node-role.kubernetes.io/worker`.
# In a homelab without dedicated workers, label all CP nodes so PodVolumeRestore can attach.
log_info "labeling CP nodes with node-role.kubernetes.io/worker (idempotent)"
kubectl get nodes -o name | xargs -I {} kubectl label {} node-role.kubernetes.io/worker= --overwrite >/dev/null

# 4. Apply global PVC volumeName-strip ResourceModifier (creates if missing)
kubectl -n velero get cm strip-pvc-volumename >/dev/null 2>&1 || cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: {name: strip-pvc-volumename, namespace: velero}
data:
  sub.yml: |
    version: v1
    resourceModifierRules:
      - conditions:
          groupResource: persistentvolumeclaims
        patches:
          - operation: remove
            path: /spec/volumeName
EOF

# 5. Create the restore.
RESTORE_NAME="${APP}-restore-$(date +%s)"
log_info "creating Velero restore: $RESTORE_NAME"
kubectl -n velero exec deploy/velero -- /velero restore create "$RESTORE_NAME" \
  --from-backup "$BACKUP_NAME" \
  --include-namespaces "$APP" \
  --include-resources pods,persistentvolumeclaims,serviceaccounts \
  --resource-modifier-configmap strip-pvc-volumename \
  --wait || log_warn "velero restore exit non-zero — inspect $RESTORE_NAME"

# 6. App-specific post-fixes.
case "$APP" in
  nextcloud)
    log_info "fix: update nextcloud config.php dbpassword to match ESO Secret"
    PODN=$(kubectl -n nextcloud get pod -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$PODN" ]; then
      kubectl -n nextcloud exec "$PODN" -- bash -c '
        sed -i "s/'\''dbpassword'\'' =>.*$/'\''dbpassword'\'' => '\''$POSTGRES_PASSWORD'\'',/" /var/www/html/config/config.php
      ' || log_warn "nextcloud sed-fix failed"
      kubectl -n nextcloud delete pod "$PODN" --force --grace-period=0 >/dev/null 2>&1 || true
    fi
    ;;
  immich)
    log_info "fix: REASSIGN OWNED on immich DB if old owner exists"
    kubectl -n immich exec immich-cluster-1 -c postgres -- psql -U postgres -d immich \
      -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='immich_user') THEN
          EXECUTE 'REASSIGN OWNED BY immich_user TO immich';
          EXECUTE 'ALTER DATABASE immich OWNER TO immich';
        END IF; END \$\$;" 2>&1 | tail -3 || log_warn "immich REASSIGN skipped"
    ;;
  forgejo)
    log_info "fix: patch forgejo-init Secret email to non-conflicting value"
    SCRIPT=$(kubectl -n forgejo get secret forgejo-init -o jsonpath='{.data.configure_gitea\.sh}' 2>/dev/null | base64 -d \
      | sed 's|gitea@local\.domain|argocd-temp@example.com|g' | base64 -w0)
    if [ -n "$SCRIPT" ]; then
      kubectl -n forgejo patch secret forgejo-init --type=json \
        -p="[{\"op\":\"replace\",\"path\":\"/data/configure_gitea.sh\",\"value\":\"$SCRIPT\"}]" >/dev/null || true
    fi
    ;;
esac

log_ok "restore-app $APP complete"
