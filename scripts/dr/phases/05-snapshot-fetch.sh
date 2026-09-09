#!/usr/bin/env bash
# Phase 05 — подтянуть свежий Raft-снапшот OpenBao из S3, если копия в
# DR-pack устарела.
#
# Раньше здесь ставился Velero, чтобы достать снапшот из его репозитория.
# Теперь снапшоты лежат в S3 обычными файлами (`snapshots/openbao/raft-*.snap`,
# кладёт CronJob openbao-raft-snapshot), поэтому достаточно rclone — ни
# оператора, ни CRD, ни BSL.
#
# Работает изнутри кластера (kubectl уже есть), чтобы не требовать rclone на
# машине оператора. Garage — основной источник, OVH — fallback.

set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

require_kubectl
load_bootstrap_env

SNAP="$DR_PACK_DIR/02-vault-raft-snapshot.snap"
MAX_AGE_DAYS="${SNAPSHOT_MAX_AGE_DAYS:-7}"

if [ -f "$SNAP" ] && [ -z "$(find "$SNAP" -mtime "+$MAX_AGE_DAYS" 2>/dev/null)" ]; then
  log_skip "DR pack snapshot younger than ${MAX_AGE_DAYS}d — keeping it"
  exit 0
fi

log_info "DR pack snapshot missing or older than ${MAX_AGE_DAYS}d — pulling from S3"

TARGET="${DR_RESTIC_TARGET:-garage}"
case "$TARGET" in
  garage)
    require_env GARAGE_SNAPSHOTS_ACCESS_KEY
    require_env GARAGE_SNAPSHOTS_SECRET
    ENDPOINT="https://s3.example.com"; REGION="garage"; PATH_PREFIX="snapshots/openbao"
    AK="$GARAGE_SNAPSHOTS_ACCESS_KEY"; SK="$GARAGE_SNAPSHOTS_SECRET"
    ;;
  ovh)
    require_env OVH_S3_ACCESS_KEY
    require_env OVH_S3_SECRET_KEY
    ENDPOINT="https://s3.de.io.cloud.ovh.net"; REGION="de"; PATH_PREFIX="vaka-homelab/snapshots/openbao"
    AK="$OVH_S3_ACCESS_KEY"; SK="$OVH_S3_SECRET_KEY"
    ;;
  *) die "unknown DR_RESTIC_TARGET: $TARGET (garage|ovh)" ;;
esac

kubectl create ns dr-fetch 2>/dev/null || true
kubectl -n dr-fetch delete pod snapshot-fetch --ignore-not-found >/dev/null 2>&1

kubectl -n dr-fetch run snapshot-fetch --restart=Never --image=rclone/rclone:1.75 \
  --env="RCLONE_CONFIG_S_TYPE=s3" \
  --env="RCLONE_CONFIG_S_PROVIDER=Other" \
  --env="RCLONE_CONFIG_S_ENDPOINT=$ENDPOINT" \
  --env="RCLONE_CONFIG_S_REGION=$REGION" \
  --env="RCLONE_CONFIG_S_FORCE_PATH_STYLE=true" \
  --env="RCLONE_CONFIG_S_ACCESS_KEY_ID=$AK" \
  --env="RCLONE_CONFIG_S_SECRET_ACCESS_KEY=$SK" \
  --command -- sh -c "set -eu
    latest=\$(rclone lsf s:$PATH_PREFIX | sort | tail -1)
    echo \"latest: \$latest\"
    rclone copyto \"s:$PATH_PREFIX/\$latest\" /tmp/raft.snap
    ls -lh /tmp/raft.snap
    sleep 300" >/dev/null

wait_for "snapshot-fetch pod Running" \
  "kubectl -n dr-fetch get pod snapshot-fetch -o jsonpath='{.status.phase}' | grep -q Running" 120
wait_for "snapshot downloaded" \
  "kubectl -n dr-fetch exec snapshot-fetch -- test -s /tmp/raft.snap" 300

mkdir -p "$DR_PACK_DIR"; chmod 700 "$DR_PACK_DIR"
kubectl -n dr-fetch cp snapshot-fetch:/tmp/raft.snap "$SNAP"
kubectl -n dr-fetch delete pod snapshot-fetch --wait=false >/dev/null 2>&1 || true
kubectl delete ns dr-fetch --wait=false >/dev/null 2>&1 || true

[ -s "$SNAP" ] || die "snapshot download produced an empty file"
log_ok "phase 05 snapshot-fetch complete — $(ls -lh "$SNAP" | awk '{print $5}') at $SNAP"
