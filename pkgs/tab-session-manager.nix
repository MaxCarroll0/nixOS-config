# Tab Session Manager, built from source so its settings are config, not clicks.

{
  buildNpmPackage,
  fetchFromGitHub,
}:

buildNpmPackage {
  pname = "tab-session-manager";
  version = "7.4.0";

  src = fetchFromGitHub {
    owner = "sienori";
    repo = "Tab-Session-Manager";
    rev = "7.4.0";
    hash = "sha256-d4tSaA9IlPEBi+kLGtplogui/RdCvpOzP3wMxuyWRZM=";
  };

  npmDepsHash = "sha256-Xwwekhwog9EBFzi33Bm4K0+vQOG4Sew9DWPegZF3hFI=";

  # browser-sync ships whatever TSM writes to disk, and the extension exposes no
  # managed-storage schema, so the only way to set this without clicking is here.
  postPatch = ''
    # Upstream keeps its Google Drive OAuth credentials out of the repo; we sync
    # through the pi instead, so a stub is enough to let the bundle build.
    printf 'export const clientId = "";\nexport const clientSecret = "";\n' > src/credentials.js

    sed -i '/id: "ifBackup"/,/default:/ s/default: false/default: true/' \
      src/settings/defaultSettings.js
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r temp/chrome/. $out/
    runHook postInstall
  '';
}
