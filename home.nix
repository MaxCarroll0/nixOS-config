{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  agda-mcp,
  curd,
  claude-code,
  codex-cli,
  anipySrc,
  ...
}:

let
  anipyApiPr = pkgs-unstable.python3Packages.buildPythonPackage {
    pname = "anipy-api";
    version = "3.8.12-pr332";
    pyproject = true;
    src = "${anipySrc}/api";
    build-system = [ pkgs-unstable.python3Packages.poetry-core ];
    dependencies = with pkgs-unstable.python3Packages; [
      python-ffmpeg
      pycryptodomex
      requests
      m3u8
      beautifulsoup4
      mpv
      dataclasses-json
      levenshtein
      simpleeval
      pycountry
      rapidfuzz
      urllib3
    ];
    doCheck = false;
    dontCheckRuntimeDeps = true;
  };

  anipyCliPr = pkgs-unstable.python3Packages.buildPythonApplication {
    pname = "anipy-cli";
    version = "3.8.12-pr332";
    pyproject = true;
    src = "${anipySrc}/cli";
    build-system = [ pkgs-unstable.python3Packages.poetry-core ];
    dependencies = with pkgs-unstable.python3Packages; [
      pyyaml
      yaspin
      inquirerpy
      appdirs
      pypresence
      anipyApiPr
    ];
    doCheck = false;
    dontCheckRuntimeDeps = true;
  };

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

  # Both curd providers (allanime, animepahe) are Cloudflare-gated; curd's plain
  # Go client can't pass the challenge. FlareSolverr solves it once, this patch
  # makes curd replay the cf_clearance + matching UA on every provider request.
  curdPatched = curd.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      cp ${./curd/zz_cf_inject.go} internal/zz_cf_inject.go
    '';
  });

  curd-cf-refresh = pkgs.writeShellApplication {
    name = "curd-cf-refresh";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
    ];
    text = builtins.readFile ./curd/cf-refresh.sh;
  };

  curdWrapped = pkgs.symlinkJoin {
    name = "curd";
    paths = [ curdPatched ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/curd \
        --run "${curd-cf-refresh}/bin/curd-cf-refresh || true"
    '';
  };

  # Run the call apps under the novpn group (split tunnel, see configuration.nix).
  # Firejail breaks the screencast portal's app identity check on KDE.

  zoom-novpn = pkgs.writeShellScriptBin "zoom-novpn" ''
    export ZOOM_URL="$1"
    if [ -n "$ZOOM_URL" ]; then
      exec /run/wrappers/bin/sg novpn -c '${pkgs.zoom-us}/bin/zoom "$ZOOM_URL"'
    else
      exec /run/wrappers/bin/sg novpn -c '${pkgs.zoom-us}/bin/zoom'
    fi
  '';

  google-meet = pkgs.writeShellScriptBin "google-meet" ''
    exec /run/wrappers/bin/sg novpn -c '${pkgs.chromium}/bin/chromium --ozone-platform=wayland --enable-features=WebRTCPipeWireCapturer --disable-features=Vulkan --no-first-run --app=https://meet.google.com'
  '';
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
            claude-code-ide-extras = epkgs.trivialBuild {
              pname = "claude-code-ide-extras";
              version = "unstable";
              src = pkgs.fetchFromGitHub {
                owner = "acmorrow";
                repo = "claude-code-ide-extras";
                rev = "56ad113f7206378ce23238dd7932737513a01748";
                hash = "sha256-A7iKmotKWOyHd8jbeY2n5/t5sE8wQobiDePp5sWJoNM=";
              };
              packageRequires = with epkgs; [
                claude-code-ide
                lsp-mode
              ];
              postPatch = ''
                rm -f claude-code-ide-extras-projectile.el
                sed -i "/extras-projectile/d" claude-code-ide-extras.el
              '';
            };
            llm-tool-collection = epkgs.trivialBuild {
              pname = "llm-tool-collection";
              version = "0-unstable-2026-02-26";
              src = pkgs.fetchFromGitHub {
                owner = "skissue";
                repo = "llm-tool-collection";
                rev = "b9fd45bedf3e0fb07d289730991199ae18785157";
                hash = "sha256-40BSMoM25tdgXeH5+labLYqCPCK4SEuAWovOeJxnzNo=";
              };
            };
            # Drop this override once nixpkgs envrc includes async processing.
            envrc = epkgs.envrc.overrideAttrs (_old: {
              version = "0-unstable-2025-01-11";
              src = pkgs.fetchFromGitHub {
                owner = "Grimpper";
                repo = "envrc";
                rev = "71f67971bc5eb2974ae2f738512c8f09f0822527";
                hash = "sha256-Zfu+yWY+POMnrWbmP6HWOjgFsASNU3HcCowNo8BIzpk=";
              };
            });
            lean4-mode = epkgs.trivialBuild {
              pname = "lean4-mode";
              version = "unstable";
              src = pkgs.fetchFromGitHub {
                owner = "leanprover-community";
                repo = "lean4-mode";
                rev = "1388f9d1429e38a39ab913c6daae55f6ce799479";
                hash = "sha256-6XFcyqSTx1CwNWqQvIc25cuQMwh3YXnbgr5cDiOCxBk=";
              };
              packageRequires = with epkgs; [
                compat
                dash
                magit-section
                lsp-mode
              ];
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
            envrc
            auctex
            vertico
            orderless
            corfu
            cape
            xenops
            cdlatex
            org-fragtog
            eat
            embrace
            claude-code-ide
            claude-code-ide-mcp-tools
            claude-code-ide-extras
            gptel
            llm-tool-collection
            ellama
            clojure-ts-mode
            sly
            fsharp-mode
            haskell-mode
            idris2-mode
            tuareg
            dune
            ocamlformat
            scala-mode
            sweeprolog
            lean4-mode
            proof-general
            company-coq
            fstar-mode
            markdown-ts-mode
            jq-mode
            ligature
            dired-narrow
            yasnippet
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
    curd-cf-refresh
    zoom-novpn
    google-meet
    agda-mcp
    arxiv-latex-mcp
    paper-search-mcp
    anipyCliPr
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
    lua-language-server
    shfmt
    exercism
    # TODO: lean4, agda. Add instead on per-project level
    lean4
    agda
    ghostscript
    mpv
    yt-dlp
    (pkgs-unstable.ani-cli.overrideAttrs (old: {
      version = "4.14.1-unstable-2026-07-07";
      src = pkgs.fetchFromGitHub {
        owner = "pystardust";
        repo = "ani-cli";
        rev = "89ec9314eba7b66c894bf8bbf3b2b25a3b80743a";
        hash = "sha256-wU25uSikLbuzQ/nAZzWz3ilpM1Ewac4ZuICRCwUn/fQ=";
      };
    }))
    claude-code
    codex-cli
    pkgs-unstable.codecrafters-cli
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

  xdg.desktopEntries.zoom-novpn = {
    name = "Zoom (no VPN)";
    genericName = "Video Conferencing";
    exec = "zoom-novpn %u";
    icon = "Zoom";
    categories = [
      "Network"
      "AudioVideo"
    ];
    mimeType = [
      "x-scheme-handler/zoommtg"
      "x-scheme-handler/zoomus"
      "x-scheme-handler/tel"
      "x-scheme-handler/zoomphonecall"
      "application/x-zoom"
    ];
  };

  xdg.desktopEntries.google-meet = {
    name = "Google Meet";
    genericName = "Video Conferencing";
    exec = "google-meet";
    icon = "google-chrome";
    categories = [
      "Network"
      "AudioVideo"
    ];
  };

  # Local Cloudflare solver curd-cf-refresh talks to; bundles its own chromium.
  systemd.user.services.flaresolverr = {
    Unit.Description = "FlareSolverr Cloudflare challenge solver";
    Install.WantedBy = [ "default.target" ];
    Service = {
      ExecStart = "${pkgs.flaresolverr}/bin/flaresolverr";
      Environment = [
        "HOST=127.0.0.1"
        "PORT=8191"
        "LOG_LEVEL=warning"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Writable copy (not a store symlink) so curd can rewrite it at runtime;
  # replaced on every switch so the repo file stays the source of truth.
  home.activation.curdConf = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "$HOME/.config/curd"
    run rm -f "$HOME/.config/curd/curd.conf"
    run install -m644 ${./curd.conf} "$HOME/.config/curd/curd.conf"
  '';

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

  services.home-manager.autoUpgrade = {
    enable = true;
    useFlake = true;
    flakeDir = "/home/max/.config/nix";
    frequency = "weekly";
    preSwitchCommands = [ "nix flake update nixpkgs-unstable" ];
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

  # Merges declarative keys into ~/.claude/settings.json without clobbering
  # other entries claude code may write.
  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _settings="$HOME/.claude/settings.json"
    run mkdir -p "$HOME/.claude"
    [ -f "$_settings" ] || echo '{}' > "$_settings"

    ${pkgs.jq}/bin/jq '. * {
      "skipAutoPermissionPrompt": true,
      "tui": "fullscreen",
      "includeCoAuthoredBy": false
    }' "$_settings" > "$_settings.tmp" && mv "$_settings.tmp" "$_settings"
  '';

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
