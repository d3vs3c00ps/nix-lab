{ config, ... }:
let
  domain = "gitea.lab.home.arpa";
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/server.nix
    ../../modules/disk-vm.nix
  ];

  networking.hostName = "gitea";
  lab.server.address = "192.168.64.10";

  services.gitea = {
    enable = true;
    database.type = "sqlite3";
    settings = {
      server = {
        DOMAIN = domain;
        ROOT_URL = "http://${domain}:3000/";
        HTTP_PORT = 3000;
        SSH_DOMAIN = domain;
      };
      # Accounts are created by the admin only.
      service.DISABLE_REGISTRATION = true;
      session.COOKIE_SECURE = false;   # plain HTTP inside the lab
      # Webhooks to private addresses are blocked by default; Woodpecker is one.
      security.ALLOWED_HOST_LIST = "private";
    };
  };

  networking.firewall.allowedTCPPorts = [ 3000 ];

  # The service has gitea in its own PATH only; this adds the CLI for admin tasks.
  environment.systemPackages = [ config.services.gitea.package ];

  # Release of the first install. Never bump it on upgrade.
  system.stateVersion = "26.05";
}
