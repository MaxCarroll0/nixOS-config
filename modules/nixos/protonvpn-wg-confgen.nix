# ProtonVPN WireGuard config generator, taking credentials from the environment.

{ pkgs }:

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

  meta.mainProgram = "protonvpn-wg";
}
