{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  agda-mcp,
  curd,
  ...
}:

let
  arxiv-to-prompt = pkgs.python3Packages.buildPythonPackage {
    pname = "arxiv-to-prompt";
    version = "0.10.0";
    pyproject = true;
    src = pkgs.fetchFromGitHub {
      owner = "takashiishida";
      repo = "arxiv-to-prompt";
      rev = "d77d75e310c0ea1208e36a63ae1d353c23a13ab0";
      hash = "sha256-+p9rZ2dxiGfb1quI5kmDuYgbbQKEYjuWINvpOUN2mZw=";
    };
    build-system = [ pkgs.python3Packages.setuptools ];
    dependencies = with pkgs.python3Packages; [
      requests
      filelock
      pyperclip
    ];
    doCheck = false;
  };

  arxiv-latex-mcp = pkgs.python3Packages.buildPythonApplication {
    pname = "arxiv-latex-mcp";
    version = "0.2.2";
    pyproject = true;
    src = pkgs.fetchFromGitHub {
      owner = "takashiishida";
      repo = "arxiv-latex-mcp";
      rev = "ac82f2662fb9d67e42ce19bd8c5b56b478235c5a";
      hash = "sha256-jzczDWUCwNLjSLHSA/xrx6B65bXzd1BNZcXFgzJZy+k=";
    };
    build-system = [ pkgs.python3Packages.setuptools ];
    dependencies = with pkgs.python3Packages; [
      httpx
      mcp
      arxiv-to-prompt
    ];
    doCheck = false;
  };

  paper-search-mcp = pkgs.python3Packages.buildPythonApplication {
    pname = "paper-search-mcp";
    version = "0.1.4";
    pyproject = true;
    src = pkgs.fetchFromGitHub {
      owner = "openags";
      repo = "paper-search-mcp";
      rev = "6d1f7ef5bcb7cfa5905d50c42fd7b8a4c1c16afd";
      hash = "sha256-P7PFynx+BZ/LuxXRjkuWhlqiYVm1+3UugFin3Qu7rmM=";
    };
    build-system = [ pkgs.python3Packages.hatchling ];
    dependencies = with pkgs.python3Packages; [
      requests
      feedparser
      fastmcp
      mcp
      pypdf2
      beautifulsoup4
      lxml
      httpx
    ];
    doCheck = false;
  };

  curdWrapped = pkgs.symlinkJoin {
    name = "curd";
    paths = [ curd ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/curd \
        --add-flags "-rod bin=${pkgs.chromium}/bin/chromium"
    '';
  };
in
{
  imports = [
    ./hyprland.nix
  ];

  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "max";
  home.homeDirectory = "/home/max";

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/home/max/.config/sops/age/keys.txt";
    secrets.exercism-API = { };
  };

  fonts.fontconfig.enable = true;

  programs.git = {
    enable = true;
    userName = "Max";
    userEmail = "mjvcarroll@gmail.com";
    ignores = [
      "*~"
      "\\#*\\#"
      ".\\#*"
      "*.swp"
      "*.swo"
      "**/.claude/settings.local.json"

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
    extraConfig = {
      init.defaultBranch = "main";
    };
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

    bashrcExtra = ''
      set -o vi
      eval "$(direnv hook bash)"
    '';
  };

  programs.emacs = {
    enable = true;
    package = (
      pkgs.emacsWithPackagesFromUsePackage {
        package = pkgs.emacs-pgtk;
        config = ./emacs/config.org;
        defaultInitFile = true;
        alwaysEnsure = true;

        extraEmacsPackages =
          epkgs:
          let
            claude-code-ide = epkgs.trivialBuild {
              pname = "claude-code-ide";
              version = "unstable";
              src = pkgs.fetchFromGitHub {
                owner = "manzaltu";
                repo = "claude-code-ide.el";
                rev = "56db02ee386d009ddb8b1482310f1f9beeefb810";
                hash = "sha256-qH1QnG5G+0UiH/v0KaS7oSpQZY+BkUMZvrjbx6kyFhg=";
              };
              packageRequires = with epkgs; [
                websocket
                web-server
                transient
              ];
              postPatch = "rm -f claude-code-ide-tests.el";
            };
            claude-code-ide-mcp-tools = epkgs.trivialBuild {
              pname = "claude-code-ide-mcp-tools";
              version = "unstable";
              src = pkgs.fetchFromGitHub {
                owner = "Kaylebor";
                repo = "claude-code-ide-mcp-tools";
                rev = "9e74701482f44090aab80f45e6e7eabce5208bd4";
                hash = "sha256-rvju/JSdsCIGZakdkQTlERi943gXDp8pKmFEAIHZHdU=";
              };
              packageRequires = [ claude-code-ide ];
            };
          in
          with epkgs;
          [
            treesit-grammars.with-all-grammars
            use-package
            meow
            nixpkgs-fmt
            apheleia
            nix-ts-mode
            magit
            agda2-mode
            direnv
            auctex
            vertico
            orderless
            corfu
            cape
            xenops
            cdlatex
            vterm
            claude-code-ide
            claude-code-ide-mcp-tools
          ];
      }
    );
  };

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "25.05"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    curdWrapped
    agda-mcp
    arxiv-latex-mcp
    paper-search-mcp
    pkgs-unstable.context7-mcp
    (lib.meta.setPrio 5 pkgs-unstable.mcp-server-sequential-thinking)
    (lib.meta.setPrio 6 pkgs-unstable.mcp-server-memory) # Note (conflict)
  ]
  ++ (with pkgs; [

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    nixfmt-rfc-style
    nixd
    exercism
    # TODO: remove isabelle, lean4, agda. Add instead on per-project level
    isabelle
    lean4
    agda
    ghostscript
    pkgs-unstable.claude-code
    mcp-nixos

    # Fonts
    rofi
    ueberzugpp

    nerd-fonts.fira-code
    nerd-fonts.mononoki
  ]);

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = { };

  xdg.configFile."curd/curd.conf" = {
    source = ./curd.conf;
    force = true;
  };

  home.activation.exercismConf = lib.hm.dag.entryAfter [ "writeBoundary" "sops-nix" ] ''
    run ${pkgs.exercism}/bin/exercism configure \
      --no-verify \
      --api "https://api.exercism.org/v1" \
      --workspace "$HOME/exercism" \
      --token "$(cat ${config.sops.secrets.exercism-API.path})"
  '';

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/max/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    EDITOR = "emacs";
  };

  # Hacky declarative configuration of Claude
  # Merges into ~/.claude.json
  # emacs-tools MCP is auto-configured by claude-code-ide.el at runtime
  home.activation.claudeMcpServers = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _claude="$HOME/.claude.json"
    [ -f "$_claude" ] || echo '{}' > "$_claude"

    # Declaratively set MCP servers and global settings (overwrites mcpServers entirely)
    ${pkgs.jq}/bin/jq '
      . * {"model": "sonnet", "env": {"MAX_THINKING_TOKENS": "10000", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "50", "CLAUDE_CODE_SUBAGENT_MODEL": "haiku"}}
      | .mcpServers = {
          "nixos": {"command": "mcp-nixos", "args": []},
          "context7": {"command": "context7-mcp", "args": []},
          "sequential-thinking": {"command": "mcp-server-sequential-thinking", "args": []},
          "memory": {"command": "mcp-server-memory", "args": []},
          "agda": {"type": "http", "url": "http://localhost:3000/mcp"},
          "arxiv-latex": {"command": "arxiv-latex-mcp", "args": []},
          "paper-search": {"command": "paper-search-mcp", "args": []}
        }
    ' "$_claude" > "$_claude.tmp" && mv "$_claude.tmp" "$_claude"
  '';

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
