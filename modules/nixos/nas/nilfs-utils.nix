# nilfs-utils 2.3.1 with the history liveness filter, plus nilfs-reclaim.

{ lib }:

let
  overrides = import ../../../lib/overrides.nix { inherit lib; };
in
final: prev: {
  nilfs-utils = overrides.againstVersion "nilfs-utils" "2.2.12" prev.nilfs-utils.version (
    prev.nilfs-utils.overrideAttrs (old: rec {
      version = "2.3.1";
      src = final.fetchFromGitHub {
        owner = "nilfs-dev";
        repo = "nilfs-utils";
        tag = "v${version}";
        hash = "sha256-Sqg1pERzxc6H7eMJGv3XTgiC3/KXu/hqqZzl1vxM6E8=";
      };
      patches = (old.patches or [ ]) ++ [ ./nilfs-history.patch ];
      postPatch = builtins.replaceStrings [ "sbin/mkfs/mkfs.c" ] [ "sbin/mkfs.c" ] (
        overrides.containing "nilfs-utils" "sbin/mkfs/mkfs.c" old.postPatch
      );
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.pkg-config ];
      buildInputs = (old.buildInputs or [ ]) ++ [
        final.libuuid
        final.util-linux
      ];
      installFlags = (old.installFlags or [ ]) ++ [
        "core_sbindir=${placeholder "out"}/sbin"
      ];
    })
  );

  nilfs-reclaim = final.runCommandCC "nilfs-reclaim" { buildInputs = [ final.nilfs-utils ]; } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -Wextra -Werror -o $out/bin/nilfs-reclaim ${./nilfs-reclaim.c} -lnilfsgc -lnilfs
  '';
}
