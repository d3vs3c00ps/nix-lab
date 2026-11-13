{
  description = "NixOS home lab on a Mac (vfkit)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Pinned by flake.lock; lab/lab.sh runs it with `nix run --inputs-from . nixos-anywhere`.
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }@inputs:
    let
      # Every installed host gets the same base modules, so none can forget them.
      mkHost = name: nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          ./modules/common.nix
          ./modules/lab-hosts.nix
          ./hosts/${name}
          # Shown by nixos-rebuild list-generations: which commit runs here.
          { system.configurationRevision = self.rev or self.dirtyRev or null; }
        ];
      };
    in
    {
      nixosConfigurations = {
        gitea = mkHost "gitea";
        woodpecker = mkHost "woodpecker";
        k8s-01 = mkHost "k8s-01";
        k8s-02 = mkHost "k8s-02";
        k8s-03 = mkHost "k8s-03";

        # Boot medium only: not installed, so it skips the common modules.
        installer = nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [ ./hosts/installer ];
        };
      };
    };
}
