# etcd snapshots, taken from outside the cluster.
#
# This used to be a CronJob inside the very cluster whose etcd it snapshots —
# which works right up to the moment it matters. A degraded control plane is
# exactly when a fresh snapshot is wanted and exactly when an in-cluster job
# will not run. The node has no such dependency.
#
# The talosconfig here is the same one the CronJob used, carried over from
# OpenBao (k8s/kube-system/talos-etcd-backup). Destinations are unchanged, so
# old and new snapshots land side by side and the retention keeps applying.
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

      # talosctl validates the snapshot as it writes it, so a non-empty file is
      # the check that matters here.
      test -s "$snap"
      ls -lh "$snap"

      for dst in garage:snapshots/etcd ovh:vaka-homelab/snapshots/etcd; do
        echo "=== copy -> $dst"
        rclone copy "$snap" "$dst"
        echo "=== prune >30d in $dst"
        rclone delete "$dst" --min-age 30d
      done

      rclone size garage:snapshots/etcd
      rclone size ovh:vaka-homelab/snapshots/etcd
    '';
  };

  systemd.timers.etcd-snapshot = {
    description = "Daily etcd snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Same slot the CronJob used (04:15 UTC), kept so the retention window
      # does not shift when the two overlap during the switch.
      OnCalendar = "04:15";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}
