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

  # Backup outcome per target (homelab_ops_backup_{success,timestamp}{backup,target}) is
  # written by forgejo-dump-offsite and etcd-snapshot themselves. Label `backup`, not
  # `job`: the scrape sets job="ops-node" and a textfile `job` becomes `exported_job`.

  # The etcd-snapshot talosconfig has a 1-year client cert (etcd-snapshot.nix); an expired
  # one silently ends the snapshots.
  systemd.services.cert-expiry-metrics = {
    description = "Export client certificate expiry of local credentials";
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.openssl
      pkgs.gnugrep
      pkgs.gawk
      pkgs.coreutils
    ];
    script = ''
      set -euo pipefail
      d=/var/lib/node-exporter/textfile
      end=$(grep -m1 'crt:' /var/lib/secrets/talosconfig | awk '{print $2}' | base64 -d \
        | openssl x509 -noout -enddate | cut -d= -f2)
      printf 'homelab_cert_expiry_timestamp{cert="talosconfig"} %s\n' "$(date -d "$end" +%s)" > "$d/cert-expiry.prom.tmp"
      mv "$d/cert-expiry.prom.tmp" "$d/cert-expiry.prom"
    '';
  };
  systemd.timers.cert-expiry-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

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
