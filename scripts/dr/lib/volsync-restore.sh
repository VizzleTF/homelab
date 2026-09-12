#!/usr/bin/env bash
# Общая функция восстановления одного тома из restic-репозитория VolSync.
#
# Заменяет velero restore: создаём Secret с координатами репозитория (из
# DR-pack: пароль restic + ключ S3), PVC нужного размера и
# ReplicationDestination с copyMethod Direct — mover наливает данные прямо
# в этот PVC. ArgoCD потом усыновляет PVC как свой.
#
# volsync_restore <namespace> <repo-name> <pvc-name> <size> [access-mode] [uid]
#   repo-name — имя репозитория внутри бакета (= volsync[].name в values)
#
# Требует в окружении (из 01-bootstrap.env):
#   RESTIC_PASSWORD_GARAGE, GARAGE_RESTIC_ACCESS_KEY, GARAGE_RESTIC_SECRET
# Опционально (fallback на off-site, если Garage мёртв):
#   DR_RESTIC_TARGET=ovh + RESTIC_PASSWORD_OVH, OVH_S3_ACCESS_KEY, OVH_S3_SECRET_KEY

volsync_restore() {
  local ns="$1" repo="$2" pvc="$3" size="$4"
  local mode="${5:-ReadWriteOnce}" uid="${6:-}"
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
      repo_url="s3:https://s3.de.io.cloud.ovh.net/vaka-homelab/restic-apps/${repo}"
      ak="$OVH_S3_ACCESS_KEY"; sk="$OVH_S3_SECRET_KEY"; pw="$RESTIC_PASSWORD_OVH"
      ;;
    *) die "unknown DR_RESTIC_TARGET: $target (garage|ovh)" ;;
  esac

  log_info "restore $ns/$pvc from $target:$repo"
  kubectl create ns "$ns" 2>/dev/null || true
  # Без этой аннотации mover не имеет CAP_CHOWN и не может вернуть файлам их
  # владельцев: restic восстановит содержимое, но свалится с "lchown: operation
  # not permitted" на первом же томе со смешанным владением.
  kubectl annotate ns "$ns" volsync.backube/privileged-movers=true --overwrite >/dev/null

  kubectl -n "$ns" create secret generic "$secret" \
    --from-literal=RESTIC_REPOSITORY="$repo_url" \
    --from-literal=RESTIC_PASSWORD="$pw" \
    --from-literal=AWS_ACCESS_KEY_ID="$ak" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$sk" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # PVC создаём сами: ArgoCD усыновит его при синке приложения. volumeName не
  # пиним — PV каждый раз новый, а pin ловил бы immutable-ошибку на SSA-diff.
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

  # По умолчанию mover работает от root: восстановление возвращает файлам
  # исходных владельцев, а lchown в чужой uid непривилегированному процессу
  # запрещён (VolSync падает с "operation not permitted"). Конкретный uid имеет
  # смысл только для тома, где всё принадлежит одному пользователю.
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
    cacheCapacity: 2Gi
    cacheAccessModes: [ReadWriteOnce]${mover_sc}
EOF

  wait_for "$ns/$repo restored" \
    "kubectl -n $ns get replicationdestination dr-${repo} -o jsonpath='{.status.lastSyncTime}' | grep -q ." \
    900

  log_ok "$ns/$pvc restored from $target"
  return 0
}
