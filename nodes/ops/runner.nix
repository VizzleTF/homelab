# Second runner so the required `CI / gitleaks (pull_request)` check can pass
# while the cluster is down (else runbook S3a: disable the check by hand).
# Same labels as the cluster runner; capacity 1 to spare Forgejo.
{ ... }:

{
  virtualisation.podman = {
    enable = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  services.gitea-actions-runner.instances.ops = {
    enable = true;
    name = "ops-node-runner";
    url = "https://git.example.com";
    tokenFile = "/var/lib/secrets/forgejo-runner.token";
    labels = [
      # Keep in step with argocd/apps/forgejo-runner/values.yaml (same images).
      "ubuntu-latest:docker://node:24-bookworm"
      "ubuntu-24.04:docker://node:24-bookworm"
      "ubuntu-22.04:docker://node:22-bookworm"
      "ubuntu-20.04:docker://node:20-bookworm"
    ];
    settings = {
      runner.capacity = 1;
      container.network = "host";
    };
  };
}
