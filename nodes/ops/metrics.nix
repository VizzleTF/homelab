# Metrics for the node itself.
#
# The node runs the GitOps source of truth and every backup timer, and until
# now nothing collected a single number about it: not disk, not memory, and —
# worse — not whether those timers still do their job. A backup that quietly
# stops is indistinguishable from one that works until the day you need it.
#
# The exporter is scraped by the cluster's vmagent as a static target, so the
# history and the alerts live with everything else. When the cluster is down
# the data stops, which is fine: that case is the watchdog's job, not this one.
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
    # LAN only; the firewall rule below is what actually opens it.
    listenAddress = "0.0.0.0";
    openFirewall = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/node-exporter/textfile 0755 root root -"
  ];

  # The backup units write their outcome here, so "the dump stopped happening"
  # becomes a metric that can go stale and fire an alert, instead of silence.
  #
  # The label is `backup`, not `job`: the scrape sets job="ops-node" itself, and
  # a textfile metric carrying its own `job` gets renamed to `exported_job` on
  # ingest — alerts would then report the scrape name instead of the task that
  # actually failed.
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

  # Forgejo neither retries a failed webhook delivery nor exposes its result
  # (no API, no metric; non-2xx answers are logged only at Trace), and ArgoCD
  # silently falls back to polling, so a broken hook goes unnoticed for days.
  # webhook.last_status is each hook's latest outcome: 0 none yet, 1 succeeded,
  # 2 failed. The label is the host, never the url: a URL may carry a token.
  # If this unit fails, OpsNodeUnitFailed fires.
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
