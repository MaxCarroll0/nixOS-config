{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  curd,
  claude-code,
  codex-cli,
  anipySrc,
  ...
}:

let
  anipyApiPr = pkgs-unstable.python3Packages.buildPythonPackage {
    pname = "anipy-api";
    version = "3.8.16";
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
    version = "3.8.16";
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
      cp ${../curd/zz_cf_inject.go} internal/zz_cf_inject.go
    '';
  });

  curd-cf-refresh = pkgs.writeShellApplication {
    name = "curd-cf-refresh";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
    ];
    text = builtins.readFile ../curd/cf-refresh.sh;
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
    ./base.nix
    ./emacs.nix
    ./hyprland.nix
  ];

  fonts.fontconfig.enable = true;

  home.packages = [
    curdWrapped
    curd-cf-refresh
    zoom-novpn
    google-meet
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
    ripgrep
    nixd
    lua-language-server
    shfmt
    exercism
    ghostscript
    mpv
    yt-dlp
    (pkgs-unstable.ani-cli.overrideAttrs (old: {
      version = "4.15.0-unstable-2026-08-01";
      runtimeInputs = (old.runtimeInputs or [ ]) ++ [ pkgs.botan3 ];
      src = pkgs.fetchFromGitHub {
        owner = "pystardust";
        repo = "ani-cli";
        rev = "489087b541eb1457393b997fdd3589ffe7a8d6a2";
        hash = "sha256-nl4c0ASIvoBylnk/F4AxVxQl68de9kWPwnNtiTOLzZc=";
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

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "application/epub+zip" = "emacs.desktop";
      "x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
    };
    associations.added."x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
  };
  xdg.configFile."mimeapps.list".force = true;

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
  home.activation.curdConf = lib.hm.dag.entryAfter [ "writeBoundary" ] /* bash */ ''
    run mkdir -p "$HOME/.config/curd"
    run rm -f "$HOME/.config/curd/curd.conf"
    run install -m644 ${../curd.conf} "$HOME/.config/curd/curd.conf"
  '';

  # Rendered by the system sops config with owner = max; this cannot reference
  # NixOS config, so the path is spelled out.
  home.activation.exercismConf = lib.hm.dag.entryAfter [ "writeBoundary" ] /* bash */ ''
    if [ -r /run/secrets/exercism-API ]; then
      run ${pkgs.exercism}/bin/exercism configure \
        --no-verify \
        --api "https://api.exercism.org/v1" \
        --workspace "$HOME/exercism" \
        --token "$(cat /run/secrets/exercism-API)" >/dev/null
    else
      echo "exercism-API not readable; skipping exercism configure" >&2
    fi
  '';

  # Merges declarative keys into ~/.claude/settings.json without clobbering
  # other entries claude code may write.
  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] /* bash */ ''
    _settings="$HOME/.claude/settings.json"
    run mkdir -p "$HOME/.claude"
    [ -f "$_settings" ] || echo '{}' > "$_settings"

    ${pkgs.jq}/bin/jq '. * {
      "skipAutoPermissionPrompt": true,
      "tui": "fullscreen",
      "includeCoAuthoredBy": false
    }' "$_settings" > "$_settings.tmp" && mv "$_settings.tmp" "$_settings"
  '';
}
