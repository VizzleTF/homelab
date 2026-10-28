# Dead man's switch: the in-cluster alerting dies with the cluster, this does not.
# Answers only "is the homelab alive"; anything richer belongs in the cluster stack.
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

      # From /var/lib/secrets/gatus.env, same bot as other homelab notifications.
      alerting.telegram = {
        token = "\${TELEGRAM_BOT_TOKEN}";
        id = "\${TELEGRAM_CHAT_ID}";
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
          # Talos has no anonymous health endpoint: 401 = apiserver answered; a dead
          # one refuses. No SA token on the node just for /readyz; depth is the
          # ingress check's job.
          conditions = [
            "[CONNECTED] == true"
            "[STATUS] == 401"
          ];
          alerts = [ { type = "telegram"; description = "Kubernetes API is unreachable"; } ];
        }
        {
          name = "cluster ingress";
          group = "cluster";
          # Any internal-gateway app proves Cilium, the gateway and DNS.
          url = "https://argocd.example.com/healthz";
          interval = "2m";
          conditions = [ "[STATUS] == 200" ];
          alerts = [ { type = "telegram"; description = "Internal gateway or DNS is broken"; } ];
        }
        {
          name = "forgejo";
          group = "gitops";
          url = "https://git.example.com/api/healthz";
          interval = "2m";
          conditions = [ "[STATUS] == 200" ];
          alerts = [ { type = "telegram"; description = "Forgejo on the ops node is down"; } ];
        }
        {
          name = "garage s3";
          group = "storage";
          # Node and cluster backups land here.
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
