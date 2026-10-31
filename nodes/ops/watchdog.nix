# Dead man's switch: the in-cluster alerting dies with the cluster, this does not.
# Answers only "is the homelab alive"; anything richer belongs in the cluster stack.
# It shares power and ISP with the cluster, so it reports to the outside Gatus on vps-fi
# (status.example.com) and watches that one back: homelab docs/monitoring-architecture.md.
{ pkgs, ... }:

{
  services.gatus = {
    enable = true;
    settings = {
      web.port = 8080;

      storage = {
        type = "sqlite";
        path = "/var/lib/gatus/data.db";
      };

      ui = {
        title = "homelab watchdog";
        header = "homelab watchdog";
      };

      # From /var/lib/secrets/gatus.env, same bot as other homelab notifications. Bot API through
      # the custom provider: the built-in telegram one opens trigger and resolve with the same
      # "Gatus" header. Descriptions must stay free of double quotes.
      alerting.custom = {
        url = "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage";
        method = "POST";
        headers."Content-Type" = "application/json";
        body = ''{"chat_id": "''${TELEGRAM_CHAT_ID}", "text": "[ALERT_TRIGGERED_OR_RESOLVED] [ENDPOINT_GROUP]/[ENDPOINT_NAME]\n[ALERT_DESCRIPTION]"}'';
        placeholders.ALERT_TRIGGERED_OR_RESOLVED = {
          TRIGGERED = "🔴 FIRING";
          RESOLVED = "✅ RESOLVED";
        };
        default-alert = {
          # Rides out a probe missed during a node reboot.
          failure-threshold = 3;
          success-threshold = 2;
          send-on-resolved = true;
        };
      };

      endpoints = [
        {
          name = "kube-apiserver";
          group = "cluster";
          # VIP: up while any control plane node serves.
          url = "https://10.11.11.100:6443/readyz";
          interval = "2m";
          client.insecure = true; # kube CA is not in the node trust store
          # /readyz is readable anonymously (system:public-info-viewer): 200 "ok"
          # once the apiserver is ready; depth is the ingress check's job.
          conditions = [
            "[CONNECTED] == true"
            "[STATUS] == 200"
            "[BODY] == ok"
          ];
          alerts = [ { type = "custom"; description = "Kubernetes API is unreachable"; } ];
        }
        {
          name = "cluster ingress";
          group = "cluster";
          # Any internal-gateway app proves Cilium, the gateway and DNS.
          url = "https://argocd.example.com/healthz";
          interval = "2m";
          conditions = [ "[STATUS] == 200" ];
          alerts = [ { type = "custom"; description = "Internal gateway or DNS is broken"; } ];
        }
        {
          name = "forgejo";
          group = "gitops";
          url = "https://git.example.com/api/healthz";
          interval = "2m";
          conditions = [ "[STATUS] == 200" ];
          alerts = [ { type = "custom"; description = "Forgejo on the ops node is down"; } ];
        }
        {
          name = "garage s3";
          group = "storage";
          # Node and cluster backups land here.
          url = "https://s3.example.com";
          interval = "5m";
          conditions = [ "[STATUS] < 500" ];
          alerts = [ { type = "custom"; description = "Garage S3 on the NAS is unreachable"; } ];
        }
        {
          name = "s3 certificate";
          group = "storage";
          # acme.sh cron on the NAS; when it breaks, every restic, rclone and barman copy fails.
          url = "https://s3.example.com";
          interval = "1h";
          conditions = [ "[CERTIFICATE_EXPIRATION] > 240h" ];
          alerts = [ { type = "custom"; description = "s3.example.com certificate expires in under 10 days (acme.sh on the NAS)"; } ];
        }
        {
          name = "wildcard certificate";
          group = "cluster";
          # cert-manager wildcard-tls: a renewal stuck in pending is Progressing, not Degraded,
          # so ArgoCD notifications stay quiet (internal.example incident).
          url = "https://argocd.example.com/healthz";
          interval = "1h";
          conditions = [ "[CERTIFICATE_EXPIRATION] > 240h" ];
          alerts = [ { type = "custom"; description = "*.example.com certificate expires in under 10 days (cert-manager)"; } ];
        }
        {
          name = "wazuh-manager lb";
          group = "cluster";
          # LB IPs live on BGP routes; this one lost its route once and agents went silent.
          url = "tcp://10.11.10.140:1514";
          interval = "5m";
          conditions = [ "[CONNECTED] == true" ];
          alerts = [ { type = "custom"; description = "Wazuh manager LB 10.11.10.140 unreachable (BGP route?)"; } ];
        }
        {
          name = "outside watchdog";
          group = "watchdog";
          # Gatus on vps-fi: if it dies, a dead house goes unreported.
          url = "https://status.example.com/health";
          interval = "5m";
          conditions = [
            "[STATUS] == 200"
            "[BODY].status == UP"
          ];
          alerts = [ { type = "custom"; description = "Outside watchdog on vps-fi is down: ssh vps-fi 'cd /opt/gatus && docker compose ps'"; } ];
        }
      ];
    };
  };

  systemd.services.gatus.serviceConfig.EnvironmentFile = "/var/lib/secrets/gatus.env";

  # Heartbeat to the outside Gatus while this one runs. OPS_HEARTBEAT_TOKEN in gatus.env,
  # source OpenBao homelab/k8s/shared/gatus-heartbeat (ops_token).
  systemd.services.gatus-heartbeat = {
    description = "Report the inside watchdog alive to Gatus on vps-fi";
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = "/var/lib/secrets/gatus.env";
      ExecCondition = "${pkgs.systemd}/bin/systemctl is-active --quiet gatus";
    };
    path = [ pkgs.curl ];
    script = ''
      curl -fsS -o /dev/null -m 10 --retry 3 -X POST \
        -H "Authorization: Bearer $OPS_HEARTBEAT_TOKEN" \
        "https://status.example.com/api/v1/endpoints/homelab_ops-gatus/external?success=true"
    '';
  };
  systemd.timers.gatus-heartbeat = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      Persistent = true;
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
