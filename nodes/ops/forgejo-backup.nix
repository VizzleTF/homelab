# Backups for the Forgejo instance on this node.
#
# The node holds the GitOps source of truth, so losing it must never mean
# losing history. Three independent copies exist, in increasing cost to use:
#
#   1. push mirror to NAS Gitea       — plain git, another machine, minutes old
#   2. restic in Garage on the NAS    — full dump: db, repos, lfs, packages meta
#   3. restic in OVH                  — the same dump, off-site
#
# What restic stores is Forgejo's own dump, which is consistent by construction:
# it drains queues and snapshots the database itself. Package blobs are not in
# it — they live in Garage and are backed up as part of that bucket.
#
# Recovery runbook: obsidian/113 Backups/Forgejo Recovery.md
{ pkgs, ... }:

{
  services.forgejo.dump = {
    enable = true;
    type = "tar.zst";
    interval = "01:30";
  };

  systemd.services.forgejo-dump-offsite = {
    description = "Ship the latest Forgejo dump to Garage and OVH";
    after = [ "forgejo-dump.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = "/var/lib/secrets/forgejo-backup.env";
    };
    path = [
      pkgs.restic
      pkgs.coreutils
    ];
    script = ''
      set -euo pipefail

      dump=$(ls -1t /var/lib/forgejo/dump/*.tar.zst 2>/dev/null | head -1)
      if [ -z "''${dump:-}" ]; then
        echo "no dump found in /var/lib/forgejo/dump — nothing to ship"
        exit 1
      fi
      echo "shipping $dump"

      # Same repository layout the cluster uses for its own restic backups, so
      # a human looking for this data finds it where everything else lives.
      ship() {
        export AWS_ACCESS_KEY_ID="$1"
        export AWS_SECRET_ACCESS_KEY="$2"
        export RESTIC_PASSWORD="$3"
        export RESTIC_REPOSITORY="$4"

        restic snapshots >/dev/null 2>&1 || restic init
        restic backup --tag forgejo-ops "$dump"
        restic forget --tag forgejo-ops --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
      }

      ship "$GARAGE_KEY" "$GARAGE_SECRET" "$GARAGE_RESTIC_PASSWORD" \
           "s3:https://s3.example.com/restic-apps/forgejo-ops"

      ship "$OVH_KEY" "$OVH_SECRET" "$OVH_RESTIC_PASSWORD" \
           "s3:https://s3.de.io.cloud.ovh.net/vaka-homelab/restic-apps/forgejo-ops"
    '';
  };

  systemd.timers.forgejo-dump-offsite = {
    description = "Daily off-node copy of the Forgejo dump";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "02:15";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}
