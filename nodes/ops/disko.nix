# Disk layout for ops. The board boots in legacy BIOS mode (no /sys/firmware/efi),
# so GRUB needs a bios_grub partition. The ESP is created anyway: if the machine
# is ever switched to UEFI, only the bootloader setting has to change.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-KXG50ZNV256G_TOSHIBA_18NS107BTP4T";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02"; # BIOS boot partition — holds GRUB's core image
        };
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
