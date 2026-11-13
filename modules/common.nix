{ lib, pkgs, ... }:
{
  # Overridden by each host's generated hardware-configuration.nix; this lets a
  # new host evaluate before that file exists.
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    trusted-users = [ "root" "@wheel" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  time.timeZone = "Europe/Paris";
  i18n.defaultLocale = "en_US.UTF-8";

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = lib.mkDefault "no";
    };
  };

  environment.systemPackages = with pkgs; [ git vim curl htop jq ];
}
