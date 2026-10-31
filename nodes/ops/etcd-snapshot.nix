# Outside the cluster: works when the control plane is degraded.
# talosconfig has only os:etcd:backup (`talosctl config new --roles
# os:etcd:backup`, 1-year cert, expires 2027-10-17; copy in OpenBao
# k8s/kube-system/talos-etcd-backup). An admin config would let this node wipe the cluster.
{ pkgs, ... }:

{
  systemd.services.etcd-snapshot = {
    description = "Take an etcd snapshot from a control plane node and ship it";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = "/var/lib/secrets/etcd-snapshot.env";
      PrivateTmp = true;
    };
    # The OVH copy goes through rclone crypt; the env file adds
    # RCLONE_CONFIG_OVHCRYPT_PASSWORD{,2} (rclone-obscured, OpenBao shared/ovh-crypt).
    # Same remote as the openbao and tfstate-mirror CronJobs.
    environment = {
      RCLONE_CONFIG_OVHCRYPT_TYPE = "crypt";
      RCLONE_CONFIG_OVHCRYPT_REMOTE = "ovh:offsite-homelab/crypt";
      RCLONE_CONFIG_OVHCRYPT_FILENAME_ENCRYPTION = "off";
      RCLONE_CONFIG_OVHCRYPT_DIRECTORY_NAME_ENCRYPTION = "false";
    };
    path = [
      pkgs.talosctl
      pkgs.rclone
      pkgs.coreutils
      pkgs.gnused
    ];
    script = ''
      set -euo pipefail

      # Per-target result for node_exporter (alerts: vmrule-ops-node.yaml). A target that
      # fails keeps its last success time, so staleness still alerts. Same as vps-backup.sh.
      prom=/var/lib/node-exporter/textfile/etcd-snapshot.prom
      declare -A OK TS
      for t in garage ovh; do
        OK[$t]=0
        TS[$t]=$(sed -n "s/^homelab_ops_backup_timestamp{backup=\"etcd-snapshot\",target=\"$t\"} //p" "$prom" 2>/dev/null || true)
        TS[$t]=''${TS[$t]:-0}
      done
      write_prom() {
        for t in garage ovh; do
          echo "homelab_ops_backup_success{backup=\"etcd-snapshot\",target=\"$t\"} ''${OK[$t]}"
          echo "homelab_ops_backup_timestamp{backup=\"etcd-snapshot\",target=\"$t\"} ''${TS[$t]}"
        done > "$prom.tmp" && mv "$prom.tmp" "$prom"
      }
      trap write_prom EXIT

      ts=$(date -u +%Y-%m-%dT%H%M)
      snap="/tmp/etcd-''${ts}.snap"

      # Any control plane node can serve the snapshot; take the first that answers.
      taken=0
      for node in 10.11.11.101 10.11.11.102 10.11.11.103; do
        echo "trying $node"
        if talosctl --talosconfig=/var/lib/secrets/talosconfig -n "$node" -e "$node" \
             etcd snapshot "$snap"; then
          echo "snapshot taken from $node"
          taken=1
          break
        fi
        echo "node $node did not answer, next"
      done
      [ "$taken" = "1" ] || { echo "no control plane node produced a snapshot"; exit 1; }

      # talosctl validates while writing; non-empty is enough.
      test -s "$snap"
      ls -lh "$snap"

      # Each target on its own: a dead NAS must not stop the OVH copy.
      rc=0
      for t in garage ovh; do
        dst=garage:snapshots/etcd
        [ "$t" = ovh ] && dst=ovhcrypt:snapshots/etcd
        echo "=== copy -> $dst"
        if rclone copy "$snap" "$dst" && rclone delete "$dst" --min-age 30d && rclone size "$dst"; then
          OK[$t]=1
          TS[$t]=$(date +%s)
        else
          echo "$t: failed"; rc=1
        fi
      done
      exit $rc
    '';
  };

  systemd.timers.etcd-snapshot = {
    description = "Daily etcd snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Node-local time (Asia/Nicosia) = 01:15 UTC.
      OnCalendar = "04:15";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}
