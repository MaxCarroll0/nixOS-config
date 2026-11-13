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

    caelestia-shell = {
      url = "github:caelestia-dots/shell";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    caelestia-dots = {
      url = "github:caelestia-dots/caelestia";
      flake = false;
    };

    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    bookshelf = {
      url = "git+ssh://git@github.com/MaxCarroll0/bookshelf?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    satisfactory = {
      url = "git+ssh://git@github.com/MaxCarroll0/SatisfactoryServer?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
      inputs.nixpkgs.follows = "nixpkgs";
    };

    ani-cli = {
      url = "github:pystardust/ani-cli";
      flake = false;
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    NixVirt = {
      url = "github:AshleyYakeley/NixVirt/v0.6.0";
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

      # autoUpgrade compares this against origin to refuse moving a host
      # backwards, so a dirty deploy must stay distinguishable from a commit.
      revision = self.rev or "${self.dirtyRev or "unknown"}";

      facts = import ./hosts/facts.nix;

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
              system.configurationRevision = revision;
            }
            module
          ]
          ++ modules;
          specialArgs = {
            pkgs-unstable = pkgsUnstableFor system;
            inherit inputs facts;
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
            { system.configurationRevision = revision; }
            module
          ]
          ++ modules;
          specialArgs = {
            pkgs-unstable = pkgsUnstableFor "aarch64-linux";
            inherit (inputs) nixos-raspberrypi;
            inherit inputs facts;
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
            aniCliSrc = inputs.ani-cli;
            inherit inputs facts;
          };
        };

      mkNode =
        name: hostname: remoteBuild:
        let
          host = self.nixosConfigurations.${name};
          system = host.config.nixpkgs.hostPlatform.system;
          deployLib = inputs.deploy-rs.lib.${system};
        in
        {
          inherit hostname remoteBuild;
          sshOpts = [
            "-A"
            "-o"
            "StrictHostKeyChecking=no"
            "-o"
            "UserKnownHostsFile=/dev/null"
          ];
          profilesOrder = [
            "system"
            "home"
          ];
          profiles = {
            system = {
              path = deployLib.activate.nixos host;
              interactiveSudo = true;
            };
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
        desktopnew = mkHost { module = ./hosts/desktopnew; };
      }
      // lib.mapAttrs (_: module: mkPi { inherit module; }) piHosts;

      homeConfigurations = {
        "max@laptop" = mkHome { module = ./home/laptop.nix; };
        "max@desktopnew" = mkHome { module = ./home/desktop.nix; };
        "max@pi" = mkHome {
          module = ./home/pi.nix;
          system = "aarch64-linux";
        };
      };

      deploy = {
        sshUser = "max";
        user = "root";
        # deploy-rs appends the activation user, so activate-detached is handed
        # "root" ahead of the activate-rs command it runs as a transient unit.
        sudo = "sudo activate-detached";
        magicRollback = true;
        autoRollback = true;
        # The pi's activation restarts local-fs.target, which waits on the NAS LUKS
        # devices; while the array is parked that wait alone ran past a 120s window and
        # failed two deploys that were otherwise fine. Rollback still arms, it just has
        # room to finish first.
        confirmTimeout = 420;
        activationTimeout = 900;

        nodes = {
          laptop = mkNode "laptop" "laptop-lan" false;
          desktopnew = mkNode "desktopnew" "desktopnew-lan" false;
          pi = mkNode "pi" "pi-lan" false;
        };
      };

      checks =
        lib.recursiveUpdate
          (lib.mapAttrs (_: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib)
          {
            x86_64-linux.nas-history = import ./tests/nas-history.nix {
              pkgs = pkgsFor "x86_64-linux";
              inherit lib;
            };
            x86_64-linux.nas-at = import ./tests/nas-at.nix {
              pkgs = pkgsFor "x86_64-linux";
              inherit lib;
            };
            x86_64-linux.nas-eval = import ./tests/nas-eval.nix {
              pkgs = pkgsFor "x86_64-linux";
              inherit lib;
            };
            x86_64-linux.nas-eval-stock = import ./tests/nas-eval.nix {
              pkgs = pkgsFor "x86_64-linux";
              inherit lib;
              variant = "stock";
            };
            x86_64-linux.build-offload = (pkgsFor "x86_64-linux").runCommand "build-offload-test" {
              nativeBuildInputs = [ (pkgsFor "x86_64-linux").python3 ];
            } ''
              python3 ${./tests/build-offload.py} ${./modules/nixos}
              python3 ${./tests/nix-observer-wake.py} ${./modules/nixos}
              touch $out
            '';
          };

      packages.x86_64-linux = {
        deploy-rs = inputs.deploy-rs.packages.x86_64-linux.default;

        zoom-us = (pkgsFor "x86_64-linux").zoom-us;

        bookshelf = inputs.bookshelf.packages.x86_64-linux.default;

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
