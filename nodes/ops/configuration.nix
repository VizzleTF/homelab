# ops — the host that holds the GitOps source of truth outside the cluster.
# See docs/ops-node.md. Forgejo itself lands in a follow-up change; this is the
# base system only, so that a broken service can never cost us ssh access.
{ pkgs, ... }:

{
  networking = {
    hostName = "ops";
    # VLAN 11, address comes from the dnsmasq pool on OpenWrt (10.11.11.150-199)
    # with a static lease pinned by MAC. No static config here on purpose:
    # the router stays the single place where addresses are decided.
    useDHCP = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };

  time.timeZone = "Asia/Nicosia";

  # The board runs in legacy BIOS mode (CSM), so GRUB goes onto the bios_grub
  # partition from disko.nix. Switching the firmware to UEFI later means
  # swapping this block for systemd-boot — the partition layout already fits.
  # The root disk is NVMe, and legacy BIOS cannot boot from NVMe at all — there
  # is no legacy option ROM for it, which is why the first install produced
  # "boot device not found" despite GRUB reporting success. So GRUB is installed
  # into the ESP as well, as the removable fallback path (EFI/BOOT/BOOTX64.EFI):
  # that one needs no EFI variables, so it can be written from a legacy-booted
  # installer and still be found once the firmware is switched to UEFI.
  # The disk itself is not named here — disko already registers it in
  # boot.loader.grub.devices via its bios_grub partition, and repeating it
  # fails the "duplicated devices in mirroredBoots" assertion.
  boot.loader = {
    efi.canTouchEfiVariables = false;
    grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
  };

  # 8 GB of DDR3 — compressed swap is worth more than a swap partition here.
  zramSwap.enable = true;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  # /nix/store on a 256 GB SSD needs no babysitting, but old generations add up.
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

  environment.systemPackages = with pkgs; [
    curl
    git
    htop
    # Recovery happens by hand from this shell, and the backup runbook assumes
    # restic is here — inside the systemd unit it is not enough.
    restic
    rsync
    tmux
    vim
  ];

  system.stateVersion = "26.05";
}
