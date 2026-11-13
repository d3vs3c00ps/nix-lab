{ config, pkgs, inputs, ... }:
let
  domain = "woodpecker.lab.home.arpa";
  giteaUrl = "http://gitea.lab.home.arpa:3000";
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/server.nix
    ../../modules/disk-vm.nix
    inputs.sops-nix.nixosModules.sops
  ];

  networking.hostName = "woodpecker";
  lab.server.address = "192.168.64.11";

  # Decrypted at activation with this host's SSH key, into /run/secrets (tmpfs).
  # The key is generated before the install and sent with --extra-files.
  sops = {
    defaultSopsFile = ../../secrets/woodpecker.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets.server_env = { };
    secrets.agent_env = { };
  };

  services.woodpecker-server = {
    enable = true;
    environment = {
      WOODPECKER_HOST = "http://${domain}:8000";
      WOODPECKER_SERVER_ADDR = ":8000";
      WOODPECKER_GRPC_ADDR = "127.0.0.1:9000";
      WOODPECKER_OPEN = "false";
      WOODPECKER_ADMIN = "lab_admin";
      WOODPECKER_GITEA = "true";
      WOODPECKER_GITEA_URL = giteaUrl;
    };
    # WOODPECKER_AGENT_SECRET, WOODPECKER_GITEA_CLIENT, WOODPECKER_GITEA_SECRET
    environmentFile = [ config.sops.secrets.server_env.path ];
  };

  # Local backend: pipeline steps run as shell commands on this host, so they can
  # call nix directly. The systemd sandbox still applies; the nix daemon does the
  # actual builds.
  services.woodpecker-agents.agents.local = {
    enable = true;
    environment = {
      WOODPECKER_SERVER = "127.0.0.1:9000";
      WOODPECKER_BACKEND = "local";
      WOODPECKER_MAX_WORKFLOWS = "1";
      # Keeps the agent ID across restarts; the default /etc path is read-only.
      WOODPECKER_AGENT_CONFIG_FILE = "/var/lib/woodpecker-agent-local/agent.conf";
    };
    # WOODPECKER_AGENT_SECRET
    environmentFile = [ config.sops.secrets.agent_env.path ];
    path = with pkgs; [ git git-lfs woodpecker-plugin-git bash coreutils nix ];
  };

  systemd.services.woodpecker-agent-local.serviceConfig.StateDirectory = "woodpecker-agent-local";

  networking.firewall.allowedTCPPorts = [ 8000 ];

  system.stateVersion = "26.05";
}
