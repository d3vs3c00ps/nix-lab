# disko layout for a lab VM: GPT, EFI system partition, ext4 root.
# nixos-anywhere ERASES this disk during install.
{ lib, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    # vfkit VMs have one virtio disk. by-id paths are not stable across VMs.
    device = lib.mkDefault "/dev/vda";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "512M";
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
