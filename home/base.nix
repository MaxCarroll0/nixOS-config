# Shared home config for every host: shell, git, emacs, core CLI tools.

{ pkgs, ... }:

{
  imports = [ ./emacs.nix ];

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

      # home.sessionVariables only reaches login shells; sudo's PAM key auth needs this everywhere.
      # An agent forwarded by ssh -A must win, or remote sudo (deploy-rs) loses the key.
      export SSH_AUTH_SOCK="''${SSH_AUTH_SOCK:-''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent}"
    '';
  };

  home.packages = with pkgs; [
    ripgrep
    nixfmt-rfc-style
    nixd
    shfmt
    jq
  ];

  home.sessionVariables = {
    EDITOR = "emacs";
    SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/ssh-agent";
  };

  services.home-manager.autoUpgrade = {
    enable = true;
    useFlake = true;
    flakeDir = "/home/max/.config/nix";
    frequency = "weekly";
    preSwitchCommands = [ "nix flake update nixpkgs-unstable" ];
  };

  services.ssh-agent.enable = true;

  programs.home-manager.enable = true;

  home.stateVersion = "25.05";
}
