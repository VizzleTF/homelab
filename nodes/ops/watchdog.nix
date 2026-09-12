# Dead man's switch.
#
# Everything that could tell you the homelab is down lives inside the homelab:
# VictoriaMetrics, Alertmanager and Robusta all stop together with the cluster,
# and the `Watchdog` rule that would catch that is disabled. The in-cluster
# Gatus is a dashboard — it has no alerting section at all.
#
# So this is the one observer that survives the thing it observes. It does not
# store or aggregate anything; it answers one question — is the house alive —
# and writes to the same Telegram bot as ArgoCD notifications and Forgejo
# Actions. Anything richer belongs in the cluster stack.
{ ... }:

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

      # Token and chat id come from /var/lib/secrets/gatus.env, same bot as the
      # rest of the homelab notifications.
      alerting.telegram = {
        token = "\${TELEGRAM_BOT_TOKEN}";
        id = "\${TELEGRAM_CHAT_ID}";
        default-alert = {
          # Three failures before shouting: a single missed probe during a node
          # reboot or a sync is not news.
          failure-threshold = 3;
          success-threshold = 2;
          send-on-resolved = true;
        };
      };

      endpoints = [
        {
          name = "kube-apiserver";
          group = "cluster";
          # The VIP, so this stays true as long as any control plane node serves.
          url = "https://10.11.11.100:6443/readyz";
          interval = "2m";
          client.insecure = true; # kube CA is not in the node trust store
          # Talos serves no health endpoint anonymously, so 401 is the honest
          # signal here: the API server accepted the connection and answered.
          # A dead control plane refuses the connection instead. Depth beyond
          # "it answers" is what the ingress check below is for — going further
          # would mean keeping a ServiceAccount token on the node just to read
          # /readyz, which is a worse trade for a dead man's switch.
          conditions = [
            "[CONNECTED] == true"
            "[STATUS] == 401"
          ];
          alerts = [ { type = "telegram"; description = "Kubernetes API is unreachable"; } ];
        }
        {
          name = "cluster ingress";
          group = "cluster";
          # Any app behind the internal gateway proves Cilium, the gateway and
          # DNS are all still doing their job.
          url = "https://argocd.example.com/healthz";
          interval = "2m";
          conditions = [ "[STATUS] == 200" ];
          alerts = [ { type = "telegram"; description = "Internal gateway or DNS is broken"; } ];
        }
        {
          name = "forgejo";
          group = "gitops";
          # Local service, but worth watching: if this is down, GitOps is blind
          # and so is every recovery procedure that starts with a git clone.
          url = "https://git.example.com/api/healthz";
          interval = "2m";
          conditions = [ "[STATUS] == 200" ];
          alerts = [ { type = "telegram"; description = "Forgejo on the ops node is down"; } ];
        }
        {
          name = "garage s3";
          group = "storage";
          # Backups from both the node and the cluster land here; losing it
          # silently would mean backups stop without anyone noticing.
          url = "https://s3.example.com";
          interval = "5m";
          conditions = [ "[STATUS] < 500" ];
          alerts = [ { type = "telegram"; description = "Garage S3 on the NAS is unreachable"; } ];
        }
      ];
    };
  };

  systemd.services.gatus.serviceConfig.EnvironmentFile = "/var/lib/secrets/gatus.env";

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
