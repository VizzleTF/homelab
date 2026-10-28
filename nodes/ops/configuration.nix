# ops node base system (obsidian/111 Memory/Ops Node.md); services live in
# their own modules so a broken one never costs ssh access.
{ pkgs, ... }:

{
  networking = {
    hostName = "ops";
    # VLAN 11, static DHCP lease by MAC on OpenWrt: the router alone assigns addresses.
    useDHCP = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };

  time.timeZone = "Asia/Nicosia";

  # Legacy BIOS cannot boot NVMe ("boot device not found"), so GRUB also goes to
  # the ESP removable path (EFI/BOOT/BOOTX64.EFI): no EFI vars needed, found
  # after switching to UEFI. Do not name the disk: disko registers it, a repeat
  # fails "duplicated devices in mirroredBoots".
  boot.loader = {
    efi.canTouchEfiVariables = false;
    grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
  };

  # Toshiba KXG50 hangs on APST transitions (controller "dead" 2026-10-18,
  # Forgejo down until power cycle): keep the highest power state.
  boot.kernelParams = [ "nvme_core.default_ps_max_latency_us=0" ];

  zramSwap.enable = true;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  users.users = {
    root.openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCdwxojfBI3ubhX3fFrDBlcwfSaToZMp/pM3M8H+TFcjMzdDZAz8cvdLXVJpkw5ES1++vRw2N2hms9UNYYxCjlLEj2cs0r9+uW9Gef6bTfL36+IFcfTK+yJ8FVeTGyAwgWFicd/1jOZco8Ybes2jlFNUyAojV2Bqsfp66YGtQtOhoObCL3uafFUIKkG6f7UH1SRFqwwKH49Agi/2vBCPZl8ZSvlGeudBIBS1LaWh7KPneBZAYfbBnvKJBHIt2ZzGXL3o4aL7bmKHYMw6qosoTmQwSV/RgtFjX2bfL7JgKds8bEpk31pGuUD61KqHa+B8juCSH1dDn4ifkdnrOWxhgOHUj+b4pdOo8kqyjGW/I7W/loaDT44UFTAvgAoI3/i8YhmnyeD5ysfuJYFX3KG7RnEbs3sy2ILBcmLrdP80cclWQM/S+I1Uxqf8Y1MhYNOYfCq/79H//IuW+L+kTKeAftvki+Zw/ZQeVwxF/NYSja3joY+L4rUa6QMbGLV+WevNnU= ivan@macbook"
    ];

    ivan = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCdwxojfBI3ubhX3fFrDBlcwfSaToZMp/pM3M8H+TFcjMzdDZAz8cvdLXVJpkw5ES1++vRw2N2hms9UNYYxCjlLEj2cs0r9+uW9Gef6bTfL36+IFcfTK+yJ8FVeTGyAwgWFicd/1jOZco8Ybes2jlFNUyAojV2Bqsfp66YGtQtOhoObCL3uafFUIKkG6f7UH1SRFqwwKH49Agi/2vBCPZl8ZSvlGeudBIBS1LaWh7KPneBZAYfbBnvKJBHIt2ZzGXL3o4aL7bmKHYMw6qosoTmQwSV/RgtFjX2bfL7JgKds8bEpk31pGuUD61KqHa+B8juCSH1dDn4ifkdnrOWxhgOHUj+b4pdOo8kqyjGW/I7W/loaDT44UFTAvgAoI3/i8YhmnyeD5ysfuJYFX3KG7RnEbs3sy2ILBcmLrdP80cclWQM/S+I1Uxqf8Y1MhYNOYfCq/79H//IuW+L+kTKeAftvki+Zw/ZQeVwxF/NYSja3joY+L4rUa6QMbGLV+WevNnU= ivan@macbook"
      ];
    };
  };

  security.sudo.wheelNeedsPassword = false;

  # /root/ops (flake source) needs an identity, else `git commit` fails with
  # "Author identity unknown". Same identity the deploy skill passes with -c.
  programs.git = {
    enable = true;
    config.user = {
      name = "ops";
      email = "ops@example.com";
    };
  };

  # DR toolbox for scripts/dr/ and runbooks: this node is up when the cluster is not.
  environment.systemPackages = with pkgs; [
    curl
    git
    htop
    jq
    kubectl
    kubernetes-helm
    openbao # the `bao` CLI; the HashiCorp vault binary is deliberately absent
    rclone
    restic
    rsync
    talosctl
    tmux
    vim
    yq-go
  ];

  system.stateVersion = "26.05";
}
