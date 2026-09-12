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
{ ... }:

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
  systemd.services.forgejo-dump-offsite.postStop = ''
    d=/var/lib/node-exporter/textfile
    ok=0
    [ "$EXIT_STATUS" = "0" ] && ok=1
    printf 'homelab_ops_backup_success{job="forgejo-dump-offsite"} %s\nhomelab_ops_backup_timestamp{job="forgejo-dump-offsite"} %s\n' \
      "$ok" "$(date +%s)" > "$d/forgejo-dump-offsite.prom.tmp"
    mv "$d/forgejo-dump-offsite.prom.tmp" "$d/forgejo-dump-offsite.prom"
  '';

  systemd.services.etcd-snapshot.postStop = ''
    d=/var/lib/node-exporter/textfile
    ok=0
    [ "$EXIT_STATUS" = "0" ] && ok=1
    printf 'homelab_ops_backup_success{job="etcd-snapshot"} %s\nhomelab_ops_backup_timestamp{job="etcd-snapshot"} %s\n' \
      "$ok" "$(date +%s)" > "$d/etcd-snapshot.prom.tmp"
    mv "$d/etcd-snapshot.prom.tmp" "$d/etcd-snapshot.prom"
  '';

}
