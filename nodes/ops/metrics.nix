# Scraped by the cluster vmagent as a static target; cluster down = no data,
# which is the watchdog's job.
{ config, pkgs, ... }:

{
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [
      "systemd" # unit states: a failed timer becomes visible
      "textfile"
    ];
    extraFlags = [ "--collector.textfile.directory=/var/lib/node-exporter/textfile" ];
    listenAddress = "0.0.0.0";
    openFirewall = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/node-exporter/textfile 0755 root root -"
  ];

  # Backup outcome as a metric that can go stale and alert. Label `backup`, not
  # `job`: the scrape sets job="ops-node" and a textfile `job` becomes
  # `exported_job`, so alerts would name the scrape, not the failed task.
  systemd.services.forgejo-dump-offsite.postStop = ''
    d=/var/lib/node-exporter/textfile
    ok=0
    [ "$EXIT_STATUS" = "0" ] && ok=1
    printf 'homelab_ops_backup_success{backup="forgejo-dump-offsite"} %s\nhomelab_ops_backup_timestamp{backup="forgejo-dump-offsite"} %s\n' \
      "$ok" "$(date +%s)" > "$d/forgejo-dump-offsite.prom.tmp"
    mv "$d/forgejo-dump-offsite.prom.tmp" "$d/forgejo-dump-offsite.prom"
  '';

  systemd.services.etcd-snapshot.postStop = ''
    d=/var/lib/node-exporter/textfile
    ok=0
    [ "$EXIT_STATUS" = "0" ] && ok=1
    printf 'homelab_ops_backup_success{backup="etcd-snapshot"} %s\nhomelab_ops_backup_timestamp{backup="etcd-snapshot"} %s\n' \
      "$ok" "$(date +%s)" > "$d/etcd-snapshot.prom.tmp"
    mv "$d/etcd-snapshot.prom.tmp" "$d/etcd-snapshot.prom"
  '';

  # Forgejo never retries or exposes webhook failures and ArgoCD silently polls.
  # last_status: 0 none yet, 1 succeeded, 2 failed. Label the host, never the
  # url: a URL may carry a token.
  systemd.services.forgejo-webhook-status = {
    description = "Export the last delivery status of Forgejo webhooks";
    after = [ "postgresql.service" ];
    serviceConfig.Type = "oneshot";
    path = [
      config.services.postgresql.package
      pkgs.util-linux
    ];
    script = ''
      set -euo pipefail
      d=/var/lib/node-exporter/textfile
      runuser -u postgres -- psql -d git -At -F ' ' -c \
        "select id, coalesce(substring(url from '^https?://(?:[^/?#]*@)?([^/:?#]+)'), 'unknown'), coalesce(last_status, 0) from webhook where is_active" \
        | while read -r id host status; do
            printf 'homelab_forgejo_webhook_last_status{hook_id="%s",host="%s"} %s\n' "$id" "$host" "$status"
          done > "$d/forgejo-webhook.prom.tmp"
      mv "$d/forgejo-webhook.prom.tmp" "$d/forgejo-webhook.prom"
    '';
  };
  systemd.timers.forgejo-webhook-status = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;
    };
  };

}
