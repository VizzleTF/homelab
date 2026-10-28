# Remote access that survives a cluster outage. Routes live in the NetBird
# dashboard; enabling LAN routes here makes two peers announce the same subnets.
{ pkgs, ... }:

{
  services.netbird.enable = true;

  # Safe to leave on: after first join the setup key is ignored; re-registers
  # if /var/lib/netbird is lost.
  systemd.services.netbird-join = {
    description = "Join the NetBird mesh if this peer is not registered yet";
    after = [
      "network-online.target"
      "netbird.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.netbird ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = "/var/lib/secrets/netbird.env";
    };
    script = ''
      if netbird status 2>/dev/null | grep -qi "management: connected"; then
        echo "already connected to the mesh"
        exit 0
      fi

      netbird up \
        --setup-key "$NB_SETUP_KEY" \
        --management-url https://netbird.example.com \
        --hostname ops
    '';
  };
}
