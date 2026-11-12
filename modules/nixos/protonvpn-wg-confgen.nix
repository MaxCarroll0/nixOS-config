# ProtonVPN WireGuard config generator, taking credentials from the environment.

{ pkgs }:

let
  apiCoreVersion = "5.8.11";
  arch =
    {
      x86_64 = "x86-64";
      aarch64 = "aarch64";
    }
    .${pkgs.stdenv.hostPlatform.parsed.cpu.name};
  constants = "protonvpn-wg-confgen/internal/constants";
in
pkgs.buildGoModule {
  pname = "protonvpn-wg-confgen";
  version = "0-unstable-2026-07-29";

  src = pkgs.fetchFromGitHub {
    owner = "hatemosphere";
    repo = "protonvpn-wg-confgen";
    rev = "3b2dd2fd6a52c65fd5aff0bb8ea9ab2a7b52e990";
    hash = "sha256-nCd8TdJn1NepZySP5MaFnWX7F+QTznbXhWIuGdQFJOw=";
  };

  patches = [ ../../patches/protonvpn-wg-confgen-env-credentials.patch ];

  vendorHash = "sha256-hm+t8Ys5G8MWxgFKaX/44+EDStfftNYSzTZdNYrHT9A=";

  env.CGO_ENABLED = "0";

  ldflags = [
    "-X ${constants}.AppVersion=linux-vpn-gui@${apiCoreVersion}+${arch}"
    "-X '${constants}.UserAgent=ProtonVPN/${apiCoreVersion} (Linux; ubuntu/26.04)'"
  ];

  meta.mainProgram = "protonvpn-wg";
}
