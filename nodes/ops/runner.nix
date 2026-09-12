# A second Forgejo Actions runner, here for one specific dead end.
#
# Branch protection requires a green `CI / gitleaks (pull_request)`, and the
# only runner lives in the cluster. So when the cluster is down, the PR that
# would fix it cannot be merged — the break-glass in the recovery runbook (S3a)
# is to disable the check by hand, which is exactly the kind of step nobody
# wants to improvise during an outage.
#
# This runner has no such dependency. It is the same instance-wide
# registration and the same labels as the cluster one, so jobs land on
# whichever is free; capacity 1 keeps it from competing with Forgejo for the
# machine.
#
# Podman rather than Docker: the jobs need a container runtime, and the
# docker-compatible socket is enough for act_runner without a second daemon.
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
      # Kept in step with argocd/apps/forgejo-runner/values.yaml: a job that
      # lands here must run in the same image it would in the cluster.
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
