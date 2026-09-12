# Forgejo — the GitOps source of truth, deliberately outside the cluster.
# See docs/ops-node.md. No reverse proxy: Forgejo terminates TLS itself with a
# certificate obtained over DNS-01, and git-over-ssh rides the system sshd, so
# clone URLs stay ssh://git@git.example.com/... exactly as before the move.
{ lib, pkgs, ... }:

{
  services.postgresql.enable = true;

  security.acme = {
    acceptTerms = true;
    defaults.email = "vizzle@example.com";
    certs."git.example.com" = {
      dnsProvider = "cloudflare";
      # Same Cloudflare token as cert-manager and external-dns, kept out of git:
      # /var/lib/secrets/cloudflare-dns.env holds CF_DNS_API_TOKEN, mode 0600.
      environmentFile = "/var/lib/secrets/cloudflare-dns.env";
      # git.example.com resolves to this node only on the LAN, so the ACME client
      # must not ask the local resolver whether the TXT record has propagated.
      dnsResolver = "1.1.1.1:53";
      # Forgejo reads the certificate directly, so it owns the group.
      group = "git";
    };
  };

  services.forgejo = {
    enable = true;
    user = "git";
    group = "git";

    # Role and database share the name because the module grants ownership by
    # matching them, and the role has to match the system user for peer auth.
    database = {
      type = "postgres";
      user = "git";
      name = "git";
    };

    lfs.enable = true;

    # Carried over from the in-cluster instance during the migration. They key
    # everything the database stores encrypted — mirror credentials, OAuth
    # secrets, 2FA — so a freshly generated set would quietly invalidate all of
    # it. Files live outside git, mode 0600, owned by root.
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
        # git-over-ssh goes through the system sshd as the git user, which is
        # why clone URLs need no port and the built-in ssh server stays off.
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

      # Packages (the homelab-common chart museum and OCI images) keep their
      # blobs in Garage on the NAS — 563 MB across 211 blobs — while the
      # database only holds metadata. Pointing this anywhere else would leave
      # every package in the restored database dangling. Use the [packages]
      # section, not [storage.packages]: the latter makes bucket init hang for
      # 30s against Garage.
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

      # Push mirror to the NAS Gitea copy targets an RFC1918 address, which
      # Forgejo's SSRF protection blocks unless local networks are allowed.
      migrations.ALLOW_LOCALNETWORKS = true;

      metrics.ENABLED = true;
      log.LEVEL = "Info";
    };
  };

  # The module only creates the account when it runs under its default name,
  # so the git user is declared here. The home directory must be Forgejo's
  # state dir: that is where Forgejo maintains authorized_keys, and sshd looks
  # for it under the user's home. A real shell is required too — the default
  # nologin would refuse the forced command behind every push.
  users.users.git = {
    isSystemUser = true;
    group = "git";
    home = "/var/lib/forgejo";
    shell = pkgs.bashInteractive;
  };
  users.groups.git = { };

  # Forgejo runs unprivileged, so binding 443 needs the capability granted
  # explicitly. PrivateUsers has to go with it: inside a user namespace the
  # ambient capability does not apply to the host's privileged ports, and the
  # service just dies on "bind: permission denied". That is the price of
  # serving TLS directly instead of putting a reverse proxy in front.
  systemd.services.forgejo.serviceConfig = {
    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
    PrivateUsers = lib.mkForce false;
  };

  networking.firewall.allowedTCPPorts = [ 443 ];
}
