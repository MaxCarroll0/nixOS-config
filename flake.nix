{

  description = "Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hyprland.url = "github:hyprwm/Hyprland";
    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };
  };

  outputs = { self, nixpkgs-unstable, nixpkgs, home-manager, sops-nix, ... } @ inputs:
    let
      lib = nixpkgs.lib;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      pkgs-unstable = nixpkgs-unstable.legacyPackages.${system};
    in {
    nixosConfigurations = {
      nixos = lib.nixosSystem {
        inherit system;
        modules = [
          ./configuration.nix
          sops-nix.nixosModules.sops
        ];
        specialArgs = {
          inherit nixpkgs-unstable;
          inherit inputs;
        };
      };
    };
    homeConfigurations = {
      max = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix
          ];
        extraSpecialArgs = {
          inherit pkgs-unstable;
        };
      };
    };
  };

}
