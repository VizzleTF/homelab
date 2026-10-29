# Forgejo dump (db, repos, lfs, package metadata) -> restic in Garage and OVH;
# plus a push mirror to NAS Gitea. Package blobs are in Garage, not the dump.
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
      pkgs.findutils
    ];
    script = ''
      set -euo pipefail

      dump=$(ls -1t /var/lib/forgejo/dump/*.tar.zst 2>/dev/null | head -1)
      if [ -z "''${dump:-}" ]; then
        echo "no dump found in /var/lib/forgejo/dump — nothing to ship"
        exit 1
      fi
      # Dump runs at 01:30, this at 02:15: an older file means forgejo-dump failed.
      age_min=$(( ($(date +%s) - $(stat -c %Y "$dump")) / 60 ))
      if [ "$age_min" -gt 120 ]; then
        echo "newest dump $dump is $age_min min old (>120) — forgejo-dump did not produce a fresh one"
        exit 1
      fi
      echo "shipping $dump"

      # Same repo layout as the cluster's restic backups.
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
           "s3:https://s3.de.io.cloud.ovh.net/offsite-homelab/restic-apps/forgejo-ops"

      # Prune only after both copies exist (~675 MB/day fills the disk); 2 days
      # kept in case a shipped dump is unreadable.
      find /var/lib/forgejo/dump -name '*.tar.zst' -mtime +2 -delete
      echo "local dumps kept: $(ls -1 /var/lib/forgejo/dump/*.tar.zst 2>/dev/null | wc -l)"
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
