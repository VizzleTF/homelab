# Forgejo, outside the cluster on purpose (obsidian/111 Memory/Ops Node.md).
# No reverse proxy: Forgejo terminates TLS (DNS-01 cert); git-over-ssh uses the
# system sshd, so clone URLs stay ssh://git@git.example.com/...
{ config, lib, pkgs, ... }:

{
  services.postgresql.enable = true;

  # Admin CLI on PATH for recovery: `forgejo admin regenerate keys` after a
  # dump restore (obsidian/113 Backups/Forgejo Recovery.md, S3 step 4).
  environment.systemPackages = [ config.services.forgejo.package ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "vizzle@example.com";
    certs."git.example.com" = {
      dnsProvider = "cloudflare";
      # CF_DNS_API_TOKEN (same as cert-manager), mode 0600, outside git.
      environmentFile = "/var/lib/secrets/cloudflare-dns.env";
      # The LAN resolver answers git.example.com locally; check TXT propagation upstream.
      dnsResolver = "1.1.1.1:53";
      # Forgejo reads the cert directly.
      group = "git";
    };
  };

  services.forgejo = {
    enable = true;
    user = "git";
    group = "git";

    # Names must match: the module grants ownership by name, peer auth needs
    # role = system user.
    database = {
      type = "postgres";
      user = "git";
      name = "git";
    };

    lfs.enable = true;

    # These keys encrypt DB data (mirror creds, OAuth, 2FA): a fresh set silently
    # invalidates all of it. Files outside git, root, mode 0600.
    secrets = {
      security = {
        SECRET_KEY = lib.mkForce "/var/lib/secrets/forgejo/SECRET_KEY";
        INTERNAL_TOKEN = lib.mkForce "/var/lib/secrets/forgejo/INTERNAL_TOKEN";
      };
      oauth2.JWT_SECRET = lib.mkForce "/var/lib/secrets/forgejo/JWT_SECRET";
      server.LFS_JWT_SECRET = lib.mkForce "/var/lib/secrets/forgejo/LFS_JWT_SECRET";
      packages = {
        MINIO_ACCESS_KEY_ID = "/var/lib/secrets/forgejo/MINIO_ACCESS_KEY_ID";
        MINIO_SECRET_ACCESS_KEY = "/var/lib/secrets/forgejo/MINIO_SECRET_ACCESS_KEY";
      };
    };

    settings = {
      DEFAULT.APP_NAME = "Forgejo — example.com";

      server = {
        DOMAIN = "git.example.com";
        ROOT_URL = "https://git.example.com/";
        PROTOCOL = "https";
        HTTP_PORT = 443;
        CERT_FILE = "/var/lib/acme/git.example.com/fullchain.pem";
        KEY_FILE = "/var/lib/acme/git.example.com/key.pem";
        # git-over-ssh goes through the system sshd as the git user.
        START_SSH_SERVER = false;
        SSH_DOMAIN = "git.example.com";
        SSH_PORT = 22;
        SSH_USER = "git";
        LANDING_PAGE = "login";
        OFFLINE_MODE = true;
      };

      service = {
        DISABLE_REGISTRATION = true;
        SHOW_REGISTRATION_BUTTON = false;
        ENABLE_NOTIFY_MAIL = false;
      };

      repository = {
        DEFAULT_PRIVATE = "private";
        DISABLE_HTTP_GIT = false;
      };

      actions = {
        ENABLED = true;
        DEFAULT_ACTIONS_URL = "github";
      };

      indexer = {
        REPO_INDEXER_ENABLED = true;
        ISSUE_INDEXER_TYPE = "bleve";
      };

      # Package blobs live in Garage; the DB holds only metadata, so another
      # target leaves every restored package dangling. Use [packages], not
      # [storage.packages]: the latter hangs bucket init 30s against Garage.
      packages = {
        ENABLED = true;
        STORAGE_TYPE = "minio";
        MINIO_ENDPOINT = "s3.example.com";
        MINIO_BUCKET = "forgejo-packages";
        MINIO_LOCATION = "garage";
        MINIO_USE_SSL = true;
        MINIO_BUCKET_LOOKUP = "path";
        MINIO_BASE_PATH = "packages/";
      };

      # Push mirror to the NAS Gitea is RFC1918; SSRF protection blocks it otherwise.
      migrations.ALLOW_LOCALNETWORKS = true;

      # argocd.example.com is a LAN IP, blocked by "external"; without it ArgoCD
      # only polls (10 min).
      webhook.ALLOWED_HOST_LIST = "external,argocd.example.com";

      metrics.ENABLED = true;
      log.LEVEL = "Info";
    };
  };

  # The module creates only its default user. home = state dir: sshd reads
  # Forgejo's authorized_keys there. A real shell: nologin refuses the forced
  # command behind every push.
  users.users.git = {
    isSystemUser = true;
    group = "git";
    home = "/var/lib/forgejo";
    shell = pkgs.bashInteractive;
  };
  users.groups.git = { };

  # Unprivileged bind to 443. PrivateUsers must be off: in a user namespace the
  # ambient cap does not apply and the service dies on "bind: permission denied".
  systemd.services.forgejo.serviceConfig = {
    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
    PrivateUsers = lib.mkForce false;
  };

  networking.firewall.allowedTCPPorts = [ 443 ];
}
