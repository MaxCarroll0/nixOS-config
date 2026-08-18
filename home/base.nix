# Shared home config for every host: shell, git, core CLI tools.

{ lib, pkgs, ... }:

{
  home.username = "max";
  home.homeDirectory = "/home/max";

  programs.git = {
    enable = true;
    settings.user.name = "Max";
    settings.user.email = "mjvcarroll@gmail.com";
    ignores = [
      "*~"
      "\\#*\\#"
      ".\\#*"
      "*.swp"
      "*.swo"
      "**/.claude/settings.local.json"
      "AGENTS.md"
      "CLAUDE.md"

      # Editor / OS / local state
      ".direnv/"
      "result"
      "result-*"
      ".DS_Store"
      ".vscode/"
      ".idea/"

      # Exercism
      ".exercism/"

      # Rust
      "target/"

      # TypeScript / Node / Bun
      "node_modules/"
      "dist/"
      "build/"
      ".next/"
      "*.tsbuildinfo"

      # Python
      "__pycache__/"
      "*.pyc"
      "*.pyo"
      ".venv/"
      "*.egg-info/"

      # OCaml
      "_build/"
      "*.install"

      # Haskell
      "dist-newstyle/"
      ".stack-work/"
      "*.hi"
      "*.o"

      # Scala
      ".bloop/"
      ".metals/"

      # F# / .NET
      "bin/"
      "obj/"

      # Clojure
      ".cpcache/"
      ".lsp/"
      ".clj-kondo/"

      # Common Lisp
      "*.fasl"

      # Idris
      "*.ibc"
      "*.ttc"

      # Agda
      "*.agdai"

      # Lean4
      ".lake/"
      "*.olean"
    ];
    settings.init.defaultBranch = "main";
  };

  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "https";
      aliases.co = "pr checkout";
    };

    hosts."github.com" = {
      git_protocol = "https";
      user = "MaxCarroll0";
      users.MaxCarroll0 = { };
    };
  };

  #programs.opam = {
  #    enable = true;
  #  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.bash = {
    enable = true;

    bashrcExtra = /* bash */ ''
      set -o vi
      if [ -z "''${SSH_CONNECTION:-}" ] && [ "''${REBUILD_SSH_AGENT_SUDO:-0}" != 1 ]; then
        unset SSH_AUTH_SOCK
      fi
    '';
  };

  home.packages = with pkgs; [
    ripgrep
    nixfmt-rfc-style
    nixd
    shfmt
    jq
    just
  ];

  home.sessionVariables = {
    EDITOR = lib.mkDefault "nano";
  };

  services.home-manager.autoUpgrade = {
    enable = true;
    useFlake = true;
    flakeDir = "/home/max/.config/nix";
    frequency = "weekly";
    preSwitchCommands = [ "nix flake update nixpkgs-unstable" ];
  };

  systemd.user.services.sudo-agent = {
    Unit = {
      Description = "SSH agent for explicit sudo grants";
    };
    Service = {
      ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a %t/sudo-agent";
      SuccessExitStatus = 2;
    };
    Install.WantedBy = [ "default.target" ];
  };

  programs.home-manager.enable = true;

  home.stateVersion = "25.05";
}
