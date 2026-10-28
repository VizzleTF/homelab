#!/usr/bin/env bash
# Restore one volume from its VolSync restic repository: a Secret with the repo
# coordinates, a PVC, and a ReplicationDestination with copyMethod Direct that
# fills the PVC in place; ArgoCD adopts the PVC on its next sync.
#
# volsync_restore <namespace> <repo-name> <pvc-name> <size> [access-mode] [uid] [cache]
#   repo-name = volsync[].name; cache = volsync[].cacheCapacity (default 2Gi)
# Env (01-bootstrap.env): RESTIC_PASSWORD_GARAGE, GARAGE_RESTIC_ACCESS_KEY,
# GARAGE_RESTIC_SECRET. Off-site with Garage dead:
#   DR_RESTIC_TARGET=ovh + RESTIC_PASSWORD_OVH, OVH_S3_ACCESS_KEY, OVH_S3_SECRET_KEY

volsync_restore() {
  local ns="$1" repo="$2" pvc="$3" size="$4"
  local mode="${5:-ReadWriteOnce}" uid="${6:-}" cache="${7:-2Gi}"
  local target="${DR_RESTIC_TARGET:-garage}"
  local secret="dr-restic-${repo}"
  local repo_url ak sk pw

  case "$target" in
    garage)
      require_env RESTIC_PASSWORD_GARAGE
      require_env GARAGE_RESTIC_ACCESS_KEY
      require_env GARAGE_RESTIC_SECRET
      repo_url="s3:https://s3.example.com/restic-apps/${repo}"
      ak="$GARAGE_RESTIC_ACCESS_KEY"; sk="$GARAGE_RESTIC_SECRET"; pw="$RESTIC_PASSWORD_GARAGE"
      ;;
    ovh)
      require_env RESTIC_PASSWORD_OVH
      require_env OVH_S3_ACCESS_KEY
      require_env OVH_S3_SECRET_KEY
      repo_url="s3:https://s3.de.io.cloud.ovh.net/offsite-homelab/restic-apps/${repo}"
      ak="$OVH_S3_ACCESS_KEY"; sk="$OVH_S3_SECRET_KEY"; pw="$RESTIC_PASSWORD_OVH"
      ;;
    *) die "unknown DR_RESTIC_TARGET: $target (garage|ovh)" ;;
  esac

  log_info "restore $ns/$pvc from $target:$repo"
  kubectl create ns "$ns" 2>/dev/null || true
  # Without it the mover lacks CAP_CHOWN: restic restores content, then fails
  # "lchown: operation not permitted" on the first mixed-ownership volume.
  kubectl annotate ns "$ns" volsync.backube/privileged-movers=true --overwrite >/dev/null

  kubectl -n "$ns" create secret generic "$secret" \
    --from-literal=RESTIC_REPOSITORY="$repo_url" \
    --from-literal=RESTIC_PASSWORD="$pw" \
    --from-literal=AWS_ACCESS_KEY_ID="$ak" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$sk" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # volumeName is not pinned: the PV is new every time and a pin hits an
  # immutable-field error in the SSA diff.
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
  namespace: ${ns}
spec:
  accessModes: [${mode}]
  storageClassName: longhorn
  resources:
    requests:
      storage: ${size}
EOF

  # Root by default: only root may lchown files back to other uids. A specific
  # uid suits only a volume owned entirely by one user.
  local mover_uid="${uid:-0}"
  local mover_sc="
    moverSecurityContext:
      runAsUser: ${mover_uid}
      runAsGroup: ${mover_uid}
      fsGroup: ${mover_uid}"

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: dr-${repo}
  namespace: ${ns}
spec:
  trigger:
    manual: dr-$(date +%s)
  restic:
    repository: ${secret}
    destinationPVC: ${pvc}
    copyMethod: Direct
    cacheStorageClassName: local-path
    cacheCapacity: ${cache}
    cacheAccessModes: [ReadWriteOnce]${mover_sc}
EOF

  # 1 min per Gi, never under 15 min.
  local gi=1; [[ $size == *Gi ]] && gi=${size%Gi}
  local timeout=$(( gi * 60 > 900 ? gi * 60 : 900 ))
  wait_for "$ns/$repo restored" \
    "kubectl -n $ns get replicationdestination dr-${repo} -o jsonpath='{.status.lastSyncTime}' | grep -q ." \
    "$timeout"

  log_ok "$ns/$pvc restored from $target"
  return 0
}
