{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/server.nix
    ../../modules/disk-vm.nix
    ../../modules/k8s.nix
  ];

  networking.hostName = "k8s-03";
  lab.server.address = "192.168.64.22";
  lab.k8s.role = "node";

  system.stateVersion = "26.05";
}
