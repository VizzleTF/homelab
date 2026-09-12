# NetBird peer on the node.
#
# The mesh peer that reaches the home LAN lives in the cluster, which means
# remote access disappears exactly when it is needed: the cluster is down and
# someone has to get in and fix it. This peer has no such dependency.
#
# Routes themselves are declared in the NetBird dashboard (Network Routes), not
# here — same as for the in-cluster peer. This node only joins the mesh; making
# it advertise the LAN subnets is a click in the UI, and worth doing only once
# it proves stable, otherwise two peers announce the same subnets.
{ pkgs, ... }:

{
  services.netbird.enable = true;

  # First contact only: netbird keeps its identity under /var/lib/netbird and
  # ignores the setup key afterwards, so leaving this enabled is safe — it
  # re-registers by itself if that state is ever lost.
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
