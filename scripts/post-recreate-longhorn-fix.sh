#!/usr/bin/env bash
# post-recreate-longhorn-fix.sh <node-name>
#
# Run after recreating a Talos node (VM destroy+create). Two jobs:
#   1. Delete stale stopped replica CRs on the node (Longhorn doesn't GC them,
#      they block rebuilds of other evictions).
#   2. Fix DiskFilesystemChanged: the recreated VM has a new /var/lib/longhorn
#      FS UUID, but the Longhorn Node CR still carries the old diskUUID →
#      disk stuck NotReady. Re-init the default disk with the new UUID.
#
# Safety: before fix, verify 0 replicas still reference the node's old disk.
# If any exist → abort with an error; operator must evict them first.
#
# Idempotent: if no DiskFilesystemChanged condition is present, the disk-fix
# section is skipped. Replica cleanup is always safe.

set -euo pipefail

NODE="${1:?usage: $0 <node-name> (e.g. talos-cp-02)}"
NS="longhorn-system"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

kubectl -n "$NS" get nodes.longhorn.io "$NODE" >/dev/null 2>&1 \
  || die "Longhorn node '$NODE' not found. Is the K8s node Ready and longhorn-manager running?"

# ---------- Step 1: cleanup stale stopped replicas ----------
log "Stale stopped replica cleanup on $NODE..."
mapfile -t STALE < <(
  kubectl -n "$NS" get replicas.longhorn.io --no-headers 2>/dev/null \
    | awk -v n="$NODE" '$3=="stopped" && $4==n {print $1}'
)

if ((${#STALE[@]} == 0)); then
  log "  no stale stopped replicas"
else
  log "  deleting ${#STALE[@]} stopped replica(s)"
  for r in "${STALE[@]}"; do
    kubectl -n "$NS" delete replica.longhorn.io "$r" --wait=false >/dev/null
  done
fi

# ---------- Step 2: detect DiskFilesystemChanged ----------
NODE_JSON=$(kubectl -n "$NS" get nodes.longhorn.io "$NODE" -o json)

# Find any disk with a DiskFilesystemChanged=True condition.
BAD_DISK=$(jq -r '
  .status.diskStatus
  | to_entries[]
  | select(.value.conditions[]?
      | select(.type=="Ready" and .status=="False" and (.reason=="DiskFilesystemChanged" or (.message // "" | contains("filesystem changed")))))
  | .key
' <<<"$NODE_JSON" | head -1)

if [[ -z "$BAD_DISK" ]]; then
  log "No DiskFilesystemChanged detected on $NODE — disk-fix step skipped."
  log "Done."
  exit 0
fi

log "Found broken disk entry: $BAD_DISK"

# Safety: any replicas still point at $NODE? If yes, operator must evict first.
REMAINING=$(kubectl -n "$NS" get replicas.longhorn.io --no-headers 2>/dev/null \
  | awk -v n="$NODE" '$4==n' | wc -l)
if ((REMAINING > 0)); then
  die "$REMAINING replica(s) still reference node $NODE. Evict/rebalance them before running this fix (data loss risk)."
fi

DISK_PATH=$(jq -r --arg d "$BAD_DISK" '.spec.disks[$d].path // "/var/lib/longhorn/"' <<<"$NODE_JSON")
STORAGE_RESERVED=$(jq -r --arg d "$BAD_DISK" '.spec.disks[$d].storageReserved // 0' <<<"$NODE_JSON")
TAGS_JSON=$(jq -c --arg d "$BAD_DISK" '.spec.disks[$d].tags // []' <<<"$NODE_JSON")

# ---------- retry helper for Longhorn admission webhook ----------
# Webhook: "spec and status of disks are being syncing" is a transient race.
# Retry the patch with backoff.
retry_patch() {
  local attempts=12
  local delay=5
  local i
  for ((i=1; i<=attempts; i++)); do
    if kubectl -n "$NS" patch nodes.longhorn.io "$NODE" "$@" 2>/tmp/.lh-patch-err.$$; then
      rm -f /tmp/.lh-patch-err.$$
      return 0
    fi
    if grep -q "being syncing\|being synced\|conflict" /tmp/.lh-patch-err.$$ 2>/dev/null; then
      warn "  webhook busy (attempt $i/$attempts), retrying in ${delay}s"
      sleep "$delay"
      continue
    fi
    cat /tmp/.lh-patch-err.$$ >&2
    rm -f /tmp/.lh-patch-err.$$
    return 1
  done
  warn "  webhook still busy after $attempts attempts"
  rm -f /tmp/.lh-patch-err.$$
  return 1
}

# ---------- Step 3: mark disk for eviction, scheduling off ----------
log "Step 1/4: evict + scheduling off on $BAD_DISK"
retry_patch --type merge -p "$(jq -cn --arg d "$BAD_DISK" --arg p "$DISK_PATH" \
  --argjson sr "$STORAGE_RESERVED" --argjson tags "$TAGS_JSON" \
  '{spec:{disks:{($d):{allowScheduling:false,evictionRequested:true,path:$p,storageReserved:$sr,tags:$tags}}}}')"

# ---------- Step 4: remove disk entry from spec ----------
log "Step 2/4: remove $BAD_DISK from spec"
retry_patch --type json -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/$BAD_DISK\"}]"

# ---------- Step 5: wipe stale longhorn-disk.cfg inside longhorn-manager ----------
log "Step 3/4: wipe stale longhorn-disk.cfg inside longhorn-manager on $NODE"
POD=$(kubectl -n "$NS" get pod -l app=longhorn-manager \
  -o jsonpath="{.items[?(@.spec.nodeName==\"$NODE\")].metadata.name}")
if [[ -z "$POD" ]]; then
  warn "  no longhorn-manager pod for $NODE; skipping cfg wipe (fresh pod will re-init anyway)"
else
  # Wait up to 60s for pod to be exec-able
  for i in {1..12}; do
    if kubectl -n "$NS" exec "$POD" -- rm -f "${DISK_PATH%/}/longhorn-disk.cfg" 2>/dev/null; then
      log "  wiped ${DISK_PATH%/}/longhorn-disk.cfg"
      break
    fi
    sleep 5
  done
fi

# ---------- Step 6: re-add disk ----------
log "Step 4/4: re-add $BAD_DISK with scheduling on"
retry_patch --type merge -p "$(jq -cn --arg d "$BAD_DISK" --arg p "$DISK_PATH" \
  --argjson sr "$STORAGE_RESERVED" --argjson tags "$TAGS_JSON" \
  '{spec:{disks:{($d):{allowScheduling:true,path:$p,storageReserved:$sr,tags:$tags}}}}')"

log "Waiting up to 60s for disk Ready=True..."
for i in {1..12}; do
  READY=$(kubectl -n "$NS" get nodes.longhorn.io "$NODE" -o json \
    | jq -r --arg d "$BAD_DISK" \
      '.status.diskStatus[$d].conditions[]? | select(.type=="Ready") | .status' 2>/dev/null || echo "")
  if [[ "$READY" == "True" ]]; then
    log "  disk Ready=True — fix complete."
    exit 0
  fi
  sleep 5
done

warn "Disk not yet Ready after 60s. Check 'kubectl -n $NS get nodes.longhorn.io $NODE -o yaml'"
exit 1
