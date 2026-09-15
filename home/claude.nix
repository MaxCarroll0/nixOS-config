# Claude Code and its shared, encrypted account bootstrap.

{
  lib,
  pkgs,
  pkgs-unstable,
  claude-code,
  ...
}:

let
  claude-swap = pkgs-unstable.python3Packages.buildPythonApplication {
    pname = "claude-swap";
    version = "0.25.0";
    pyproject = true;
    src = pkgs.fetchFromGitHub {
      owner = "realiti4";
      repo = "claude-swap";
      rev = "v0.25.0";
      hash = "sha256-BDfwyH7h7Ii7QYaunHDnf0Epk5nUEd8OdOH3QCf1CJU=";
    };
    build-system = [ pkgs-unstable.python3Packages.hatchling ];
    dependencies = [
      pkgs-unstable.python3Packages.textual
      pkgs-unstable.python3Packages.truststore
    ];
    doCheck = false;
  };

  accountBootstrap = "/run/secrets/claude-swap-export";
in
{
  home.packages = [
    claude-code
    claude-swap
  ];

  systemd.user.services.claude-swap-auto = {
    Unit.Description = "claude-swap account auto-switching";
    Install.WantedBy = [ "default.target" ];
    Service = {
      ExecStart = "${claude-swap}/bin/claude-swap auto --model all";
      Restart = "always";
      RestartSec = 30;
    };
  };

  # The sops export is a one-time bootstrap, not continuously authoritative
  # state: OAuth refresh tokens evolve locally and can become stale after use.
  # A clean device also needs the exported active slot copied into Claude
  # Code's live credential file.
  home.activation.claudeSwapAccounts = lib.hm.dag.entryAfter [ "writeBoundary" ] /* bash */ ''
    _marker="$HOME/.local/state/claude-swap/accounts-bootstrap-v1"
    if [ ! -e "$_marker" ] && [ -r ${accountBootstrap} ]; then
      run ${claude-swap}/bin/cswap import ${accountBootstrap}
      if [ ! -s "$HOME/.claude/.credentials.json" ]; then
        _active=$(${pkgs.jq}/bin/jq -r '.activeAccountNumber // empty' ${accountBootstrap})
        if [ -n "$_active" ]; then
          run ${claude-swap}/bin/cswap switch "$_active" --force
        fi
      fi
      run mkdir -p "$(dirname "$_marker")"
      run touch "$_marker"
    elif [ ! -e "$_marker" ]; then
      echo "${accountBootstrap} not readable; skipping claude-swap account bootstrap" >&2
    fi
  '';

  # Merge declarative keys without clobbering entries Claude Code writes.
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
