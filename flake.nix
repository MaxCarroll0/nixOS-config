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

    nixos-hardware.url = "github:NixOS/nixos-hardware";
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
          modules ? [ ],
          module,
          system ? "x86_64-linux",
        }:
        lib.nixosSystem {
          inherit system;
          modules = [
            sops-nix.nixosModules.sops
            { nixpkgs.overlays = [ emacs-overlay.overlay ]; nixpkgs.config.allowUnfree = true; }
            module
          ]
          ++ modules;
          specialArgs = {
            pkgs-unstable = pkgsUnstableFor system;
            inherit inputs;
          };
        };

      mkHome =
        {
          module,
          system ? "x86_64-linux",
        }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = pkgsFor system;
          modules = [ module ];
          extraSpecialArgs = {
            pkgs-unstable = pkgsUnstableFor system;
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
        pi = mkHost {
          module = ./hosts/pi;
          system = "aarch64-linux";
        };
        # Retire once both machines have switched to the per-host names.
        nixos = mkHost { module = ./hosts/laptop; };
      };

      homeConfigurations = {
        "max@laptop" = mkHome { module = ./home/laptop.nix; };
        "max@desktop" = mkHome { module = ./home/desktop.nix; };
        "max@pi" = mkHome {
          module = ./home/pi.nix;
          system = "aarch64-linux";
        };
        max = mkHome { module = ./home/laptop.nix; };
      };

      packages.aarch64-linux.pi-image =
        (mkHost {
          module = ./hosts/pi;
          modules = [ ./hosts/pi/image.nix ];
          system = "aarch64-linux";
        }).config.system.build.sdImage;
    };

}
