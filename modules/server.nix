# Base for every headless lab server: static IP, key-only root SSH for
# deployment from the Mac, public DNS, no desktop.
{ config, lib, ... }:
let
  cfg = config.lab.server;
in
{
  options.lab.server = {
    address = lib.mkOption {
      type = lib.types.str;
      example = "192.168.64.10";
      description = "Static IPv4 address on the vfkit NAT network.";
    };
  };

  config = {
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # networkd matches by type: the virtio NIC name differs between hypervisors.
    networking.useDHCP = false;
    networking.useNetworkd = true;
    systemd.network.networks."10-lab" = {
      matchConfig.Type = "ether";
      address = [ "${cfg.address}/24" ];
      gateway = [ "192.168.64.1" ];
    };
    # Public resolvers: the NAT DNS proxy of some hypervisors breaks EDNS queries.
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
    networking.firewall.enable = true;

    # nixos-rebuild --target-host and nixos-anywhere connect as root.
    services.openssh.settings.PermitRootLogin = "prohibit-password";
    users.users.root.openssh.authorizedKeys.keys = [ (builtins.readFile ../keys/id_nix_lab.pub) ];
    users.mutableUsers = false;
  };
}
