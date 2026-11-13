# Generic lab installer ISO: boot a new VM on it once, then run nixos-anywhere
# from the Mac. It holds no host config, so one ISO serves every host.
{ lib, modulesPath, ... }:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  nixpkgs.hostPlatform = "aarch64-linux";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "lab-installer";

  # The lab uses ext4 only; dropping ZFS makes the ISO smaller and silences
  # the boot.zfs.forceImportRoot warning.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # Key only: the ISO has no root password, so nobody else can log in.
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
  users.users.root.openssh.authorizedKeys.keys = [ (builtins.readFile ../../keys/id_nix_lab.pub) ];
}
