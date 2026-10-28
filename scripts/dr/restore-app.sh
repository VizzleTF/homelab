#!/usr/bin/env bash
# Restore one data volume from its VolSync restic repository
# (DR_RESTIC_TARGET=garage|ovh). Only the volume: pods, SAs and namespaces come
# from git through ArgoCD.
#
# Volumes are the homelab-common.volsync[] entries in argocd/{apps,infra}/*/values.yaml:
#   name          restic repository (and this script's key)
#   claim         PVC name (default: name)
#   accessMode    else the claim's persistentVolumeClaims[] accessModes[0]
#   cacheCapacity restic cache (default 2Gi)
#   namespace     config.yaml namespace, else the folder name
#   size          the claim's persistentVolumeClaims[] size, else VCT_SIZE
# The mover runs as root so restic can lchown files back (opencloud-data failed
# as uid 1000, 41d8e3d8); volsync[].moverSecurityContext is ignored here.
#
# Usage: scripts/dr/restore-app.sh <volsync-name>     restore one volume
#        scripts/dr/restore-app.sh --list             print the resolved table
#        scripts/dr/restore-app.sh <name> <repo> <pvc> <size> [mode] [uid]   explicit

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/volsync-restore.sh
source "$(dirname "$0")/lib/volsync-restore.sh"

# Claims created by an upstream chart's volumeClaimTemplate are not in
# persistentVolumeClaims[]; their size comes from that chart's values.
declare -A VCT_SIZE=(
  [database-storage-obsidian-livesync-couchdb-0]=5Gi   # obsidian-livesync persistentVolume.size
  [wazuh-data-wazuh-manager-master-0]=20Gi             # wazuh cluster.spec.manager.master.storageSize
)
# Old keys of the hand-written table, for existing runbooks.
declare -A ALIAS=(
  [rsstt]=rss-to-telegram-bot [immich]=immich-library
  [opencloud]=opencloud-data [trek]=trek-uploads
)

# Print "name|namespace|claim|size|accessMode|cache" for every volsync entry.
volume_table() {
  local f dir ns
  for f in "$REPO_ROOT"/argocd/{apps,infra}/*/values.yaml; do
    dir=$(dirname "$f")
    ns=$(yq -r '.namespace // ""' "$dir/config.yaml"); ns=${ns:-$(basename "$dir")}
    yq -o json '.["homelab-common"] // {}' "$f" 2>/dev/null | jq -r --arg ns "$ns" '
      (.persistentVolumeClaims // []) as $pvcs
      | (.volsync // [])[]
      | (.claim // .name) as $claim
      | ([$pvcs[] | select(.name == $claim)][0] // {}) as $pvc
      | [.name, $ns, $claim, ($pvc.size // ""),
         (.accessMode // ($pvc.accessModes // [])[0] // "ReadWriteOnce"),
         (.cacheCapacity // "2Gi")] | join("|")'
  done | while IFS='|' read -r name ns claim size mode cache; do
    [[ -n $size ]] || size=${VCT_SIZE[$claim]:-}
    echo "$name|$ns|$claim|$size|$mode|$cache"
  done
}

if [[ "${1:-}" == --list ]]; then
  volume_table | column -t -s'|' -N NAME,NAMESPACE,PVC,SIZE,MODE,CACHE
  exit 0
fi

APP="${1:-}"
[[ -n "$APP" ]] || die "usage: $0 <volsync-name> | --list | <name> <repo> <pvc> <size> [mode] [uid]"
APP=${ALIAS[$APP]:-$APP}

if [[ -n "${2:-}" ]]; then
  REPO="$2"; PVC="${3:?pvc required}"; SIZE="${4:?size required}"
  MODE="${5:-ReadWriteOnce}"; UID_="${6:-}"; CACHE=2Gi
  NS="${DR_NAMESPACE:?set DR_NAMESPACE for an explicit restore}"
else
  ROW=$(volume_table | grep "^${APP}|" || true)
  [[ -n "$ROW" ]] || die "no homelab-common.volsync entry named '$APP' (see $0 --list)"
  IFS='|' read -r REPO NS PVC SIZE MODE CACHE <<<"$ROW"; UID_=""
  [[ -n "$SIZE" ]] || die "$APP: no size for claim $PVC (add it to persistentVolumeClaims or VCT_SIZE)"
fi

require_kubectl
load_bootstrap_env

# Refuse a live cluster: this creates a PVC with the production name and
# namespace and fills it from the repo, overwriting a live volume.
if kubectl -n "$NS" get pvc "$PVC" >/dev/null 2>&1 && [[ "${DR_FORCE:-0}" != "1" ]]; then
  MOUNTED=$(kubectl -n "$NS" get pods -o json 2>/dev/null \
    | grep -c "\"claimName\": *\"$PVC\"" || true)
  die "PVC $NS/$PVC already exists (pods using it: $MOUNTED).
  This script restores onto an empty cluster. To restore over an existing
  volume, stop its consumers and run with DR_FORCE=1, or restore into a
  separate namespace by hand with lib/volsync-restore.sh."
fi

volsync_restore "$NS" "$REPO" "$PVC" "$SIZE" "$MODE" "$UID_" "$CACHE"

# App-state post-fixes. In a full DR (phase 09, before ArgoCD) immich-cluster
# does not exist yet: skipped with a warning; run by hand once it is up.
case "$APP" in
  immich-library)
    log_info "fix: REASSIGN OWNED if the DB still has the old owner immich_user"
    kubectl -n immich exec immich-cluster-1 -c postgres -- psql -U postgres -d immich \
      -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='immich_user') THEN
          EXECUTE 'REASSIGN OWNED BY immich_user TO immich';
          EXECUTE 'ALTER DATABASE immich OWNER TO immich';
        END IF; END \$\$;" 2>&1 | tail -3 || log_warn "immich REASSIGN skipped"
    ;;
esac

log_ok "restore-app $APP complete"
