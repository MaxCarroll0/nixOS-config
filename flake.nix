{

  description = "Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
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

    emacs-overlay.url = "github:nix-community/emacs-overlay";

    curd = {
      url = "github:Wraient/curd";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    claude-code = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    codex-cli = {
      url = "github:sadjow/codex-cli-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    anipy-cli = {
      url = "github:sdaqo/anipy-cli/v3.8.16";
    };
  };

  outputs =
    {
      self,
      nixpkgs-unstable,
      nixpkgs,
      home-manager,
      sops-nix,
      curd,
      emacs-overlay,
      ...
    }@inputs:
    let
      lib = nixpkgs.lib;
      system = "x86_64-linux";

      pkgsFor =
        s:
        import nixpkgs {
          system = s;
          overlays = [ emacs-overlay.overlay ];
          config = {
            allowUnfree = true;
            permittedInsecurePackages = [
              "python3.13-pypdf2-3.0.1"
            ];
          };
        };

      pkgsUnstableFor =
        s:
        import nixpkgs-unstable {
          system = s;
          overlays = [ emacs-overlay.overlay ];
          config.allowUnfree = true;
        };

      pkgs = pkgsFor system;
      pkgs-unstable = pkgsUnstableFor system;

      mkHost =
        {
          module,
          system ? "x86_64-linux",
        }:
        lib.nixosSystem {
          inherit system;
          modules = [
            sops-nix.nixosModules.sops
            module
          ];
          specialArgs = {
            pkgs-unstable = pkgsUnstableFor system;
            inherit inputs;
          };
        };

      mkHome =
        homeModule:
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [ homeModule ];
          extraSpecialArgs = {
            inherit pkgs-unstable;
            curd = curd.packages.${system}.default;
            claude-code = inputs.claude-code.packages.${system}.default;
            codex-cli = inputs.codex-cli.packages.${system}.default;
            anipySrc = inputs.anipy-cli;
          };
        };
    in
    {
      nixosConfigurations = {
        laptop = mkHost { module = ./hosts/laptop; };
        desktop = mkHost { module = ./hosts/desktop; };
        # Retire once both machines have switched to the per-host names.
        nixos = mkHost { module = ./hosts/laptop; };
      };

      homeConfigurations = {
        "max@laptop" = mkHome ./home/laptop.nix;
        "max@desktop" = mkHome ./home/desktop.nix;
        max = mkHome ./home/laptop.nix;
      };
    };

}
