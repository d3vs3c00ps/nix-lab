{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/server.nix
    ../../modules/disk-vm.nix
    ../../modules/k8s.nix
  ];

  networking.hostName = "k8s-01";
  lab.server.address = "192.168.64.20";
  lab.k8s.role = "master";

  system.stateVersion = "26.05";
}
