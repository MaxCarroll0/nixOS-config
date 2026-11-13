{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  curd,
  codex-cli,
  anipySrc,
  aniCliSrc,
  ...
}:

let
  overrides = import ../lib/overrides.nix { inherit lib; };

  anipySrcPinned =
    overrides.againstRev "anipy-cli" "95462338a48cb8910c7b783ed081b69d2147e5c2"
      (anipySrc.rev or "unknown")
      anipySrc;

  anipyApiPr = pkgs-unstable.python3Packages.buildPythonPackage {
    pname = "anipy-api";
    version = "3.8.16";
    pyproject = true;
    src = "${anipySrcPinned}/api";
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
    src = "${anipySrcPinned}/cli";
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

  aniCliUpstreamVersion = lib.pipe "${aniCliSrc}/ani-cli" [
    builtins.readFile
    (lib.splitString "\n")
    (lib.findFirst (lib.hasPrefix "version_number=") "version_number=\"unknown\"")
    (builtins.match "version_number=\"([^\"]*)\"")
    lib.head
  ];

  aniCliHianime = pkgs-unstable.ani-cli.overrideAttrs (old: {
    version = "${aniCliUpstreamVersion}-megaplay";
    src = aniCliSrc;
    patches = (old.patches or [ ]) ++ [ ./patches/ani-cli-megaplay.patch ];
    runtimeInputs = (old.runtimeInputs or [ ]) ++ [ pkgs-unstable.openssl ];
  });

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
  curdPatched = overrides.againstVersion "curd" "2.0.5" (lib.removeSuffix "\n" curd.version) (
    curd.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        cp ${../curd/zz_cf_inject.go} internal/zz_cf_inject.go
      '';
      doCheck = false;
    })
  );

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

  lazyFlake = "/home/max/.config/nix";

  # Run the call apps under the novpn group (split tunnel, see configuration.nix).
  zoomNovpnEager = pkgs.writeShellScriptBin "zoom-novpn" ''
    export ZOOM_URL="$1"
    if [ -n "$ZOOM_URL" ]; then
      exec /run/wrappers/bin/sg novpn -c '${pkgs.zoom-us}/bin/zoom "$ZOOM_URL"'
    else
      exec /run/wrappers/bin/sg novpn -c '${pkgs.zoom-us}/bin/zoom'
    fi
  '';

  zoomNovpnLazy = pkgs.writeShellScriptBin "zoom-novpn" ''
    export ZOOM_URL="$1"
    out="${lazyFlake}/result-lazy-zoom"
    if [ ! -x "$out/bin/zoom" ]; then
      ${pkgs.libnotify}/bin/notify-send "Zoom" "Preparing Zoom, the first launch takes a minute"
      if ! nix build --out-link "$out" "${lazyFlake}#zoom-us"; then
        ${pkgs.libnotify}/bin/notify-send "Zoom" "Build failed"
        exit 1
      fi
    fi
    if [ -n "$ZOOM_URL" ]; then
      exec /run/wrappers/bin/sg novpn -c "\"$out/bin/zoom\" \"\$ZOOM_URL\""
    else
      exec /run/wrappers/bin/sg novpn -c "\"$out/bin/zoom\""
    fi
  '';

  zoomNovpn = if config.local.lazy.zoom.enable then zoomNovpnLazy else zoomNovpnEager;

  # Session management is Tab Session Manager, built from source with its
  # backup defaults patched in: the extension has no managed-storage schema, so
  # a policy install would still leave the settings to be clicked in by hand.
  tabSessionManager = pkgs.callPackage ../pkgs/tab-session-manager.nix { };

  # Chromium picks the kwallet backend under Plasma and then blocks every page
  # load on a wallet this host can never unlock: autologin gives PAM no password.
  chromium = pkgs.chromium.override {
    commandLineArgs = lib.concatStringsSep " " [
      "--password-store=basic"
      "--load-extension=${tabSessionManager}"
      "--enable-features=WaylandWindowDecorations,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL"
    ];
  };

  # age takes ssh recipients directly, so both GUI hosts decrypt the store with
  # the key they already have and nothing new goes into sops.
  browser-sync = pkgs.writeShellApplication {
    name = "browser-sync";
    runtimeInputs = with pkgs; [
      age
      gnutar
      inetutils
      procps
      rsync
      tailscale
    ];
    text = ''
      recipients="${../keys/max.pub} ${../keys/max-desktopnew.pub}"
    ''
    + builtins.readFile ../scripts/browser-sync.sh;
  };

  # Edits hosts/pi/default.nix in place, so it runs from a repo checkout, not on the NAS.
  nas-user = pkgs.writeShellScriptBin "nas-user" ''
    exec ${pkgs.python3}/bin/python3 ${../modules/nixos/nas/nas-user.py} "$@"
  '';

  google-meet = pkgs.writeShellScriptBin "google-meet" ''
    exec /run/wrappers/bin/sg novpn -c '${chromium}/bin/chromium --ozone-platform=wayland --enable-features=WebRTCPipeWireCapturer --disable-features=Vulkan --no-first-run --app=https://meet.google.com'
  '';

in
{
  imports = [
    ./base.nix
    ./claude.nix
    ./emacs.nix
    ./theme.nix
    ./hyprland.nix
    ./workspaces.nix
    ./nas-alerts.nix
    ./lazy.nix
  ];

  fonts.fontconfig.enable = true;

  home.packages = [
    browser-sync
    nas-user
    chromium
    curdWrapped
    curd-cf-refresh
    zoomNovpn
    google-meet
    pkgs.discord
    arxiv-latex-mcp
    paper-search-mcp
    anipyCliPr
    pkgs-unstable.context7-mcp
    (lib.meta.setPrio 5 pkgs-unstable.mcp-server-sequential-thinking)
    (lib.meta.setPrio 6 pkgs-unstable.mcp-server-memory) # Note (conflict)
  ]
  ++ (with pkgs; [
    nixfmt-rfc-style
    ripgrep
    nixd
    lua-language-server
    shfmt
    exercism
    ghostscript
    mpv
    yt-dlp
    aniCliHianime
    codex-cli
    pkgs-unstable.codecrafters-cli
    mcp-nixos

    # Fonts
    rofi
    ueberzugpp

    nerd-fonts.fira-code
    nerd-fonts.mononoki
  ]);

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
      "text/html" = "chromium-browser.desktop";
      "x-scheme-handler/http" = "chromium-browser.desktop";
      "x-scheme-handler/https" = "chromium-browser.desktop";
      "x-scheme-handler/about" = "chromium-browser.desktop";
      "x-scheme-handler/unknown" = "chromium-browser.desktop";
    };
    associations.added."x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
  };
  xdg.configFile."mimeapps.list".force = true;

  # Nothing can unlock the wallet on an autologin host, so kwalletd only ever
  # prompts; disabled, it fails the request instead.
  xdg.configFile."kwalletrc" = {
    force = true;
    text = ''
      [Wallet]
      Enabled=false
    '';
  };

  xdg.configFile."mpv/mpv.conf" = {
    force = true;
    text = ''
      fullscreen=yes
      screenshot-format=png
      screenshot-png-compression=7
    '';
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

  home.activation.kdeWalkThroughWindows = lib.hm.dag.entryAfter [ "writeBoundary" ] /* bash */ ''
    _shortcuts="$HOME/.config/kglobalshortcutsrc"
    if [ -f "$_shortcuts" ]; then
      run ${pkgs.gnused}/bin/sed -i \
        -e 's|^Walk Through Windows=Alt+Tab,|Walk Through Windows=Meta+Tab,|' \
        -e 's|^Walk Through Windows (Reverse)=Alt+Shift+Tab,|Walk Through Windows (Reverse)=Meta+Shift+Tab,|' \
        "$_shortcuts"
    fi
  '';
}
