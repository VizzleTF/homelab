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
    ];
    script = ''
      set -euo pipefail

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

      for dst in garage:snapshots/etcd ovhcrypt:snapshots/etcd; do
        echo "=== copy -> $dst"
        rclone copy "$snap" "$dst"
        echo "=== prune >30d in $dst"
        rclone delete "$dst" --min-age 30d
      done

      rclone size garage:snapshots/etcd
      rclone size ovhcrypt:snapshots/etcd
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
