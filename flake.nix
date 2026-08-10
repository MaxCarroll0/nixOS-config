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

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # No nixpkgs follows: its cached kernel is keyed to its own revision.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
  };

  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
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
            {
              nixpkgs.overlays = [ emacs-overlay.overlay ];
              nixpkgs.config.allowUnfree = true;
            }
            module
          ]
          ++ modules;
          specialArgs = {
            pkgs-unstable = pkgsUnstableFor system;
            inherit inputs;
          };
        };

      mkPi =
        {
          module,
          modules ? [ ],
        }:
        inputs.nixos-raspberrypi.lib.nixosSystem {
          modules = [
            sops-nix.nixosModules.sops
            module
          ]
          ++ modules;
          specialArgs = {
            pkgs-unstable = pkgsUnstableFor "aarch64-linux";
            inherit (inputs) nixos-raspberrypi;
            inherit inputs;
          };
        };

      piHosts = {
        pi = ./hosts/pi;
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

      mkNode =
        name: hostname:
        let
          host = self.nixosConfigurations.${name};
          system = host.config.nixpkgs.hostPlatform.system;
          deployLib = inputs.deploy-rs.lib.${system};
        in
        {
          inherit hostname;
          sshOpts = [
            "-A"
            "-p"
            (toString host.config.local.server.ssh.port)
          ];
          profilesOrder = [
            "system"
            "home"
          ];
          profiles = {
            system.path = deployLib.activate.nixos host;
            home = {
              user = "max";
              path = deployLib.activate.home-manager self.homeConfigurations."max@${name}";
            };
          };
        };
    in
    {
      nixosConfigurations = {
        laptop = mkHost { module = ./hosts/laptop; };
        desktop = mkHost { module = ./hosts/desktop; };
      }
      // lib.mapAttrs (_: module: mkPi { inherit module; }) piHosts
      // {
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

      deploy = {
        sshUser = "max";
        user = "root";
        interactiveSudo = true;
        magicRollback = true;
        autoRollback = true;
        confirmTimeout = 120;
        activationTimeout = 300;

        nodes = {
          laptop = mkNode "laptop" "100.112.109.20";
          desktop = mkNode "desktop" "100.106.140.88";
          pi = mkNode "pi" "100.117.13.66";
        };
      };

      checks = lib.mapAttrs (_: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;

      packages.x86_64-linux = {
        deploy-rs = inputs.deploy-rs.packages.x86_64-linux.default;

        installer-iso =
          (lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
              {
                services.openssh.enable = true;
                services.openssh.settings.PermitRootLogin = "prohibit-password";
                users.users.root.openssh.authorizedKeys.keyFiles = [ ./keys/max.pub ];
                users.users.nixos.openssh.authorizedKeys.keyFiles = [ ./keys/max.pub ];
              }
            ];
          }).config.system.build.isoImage;
      };

      packages.aarch64-linux = lib.mapAttrs' (
        name: module:
        lib.nameValuePair "${name}-image"
          (mkPi {
            inherit module;
            modules = [ inputs.nixos-raspberrypi.nixosModules.sd-image ];
          }).config.system.build.sdImage
      ) piHosts;
    };

}
