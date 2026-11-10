# nilfs-utils 2.3.1 with the history liveness filter, plus nilfs-reclaim, nilfs-lives, stream-delta and nas-at.

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
    $CC -O2 -Wall -Wextra -Werror -DHAVE_LINUX_TYPES_H=1 -DHAVE_STDDEF_H=1 -DHAVE_SYS_SYSMACROS_H=1 -DHAVE_GETPROGNAME=1 \
      -I${final.nilfs-utils.src}/include -o $out/bin/nilfs-lives ${./nilfs-lives.c} -lnilfsgc -lnilfs
  '';

  stream-delta-lib = final.runCommand "stream-delta-lib" { } ''
    mkdir -p $out
    cp ${./stream_delta.py} $out/stream_delta.py
  '';

  stream-delta = final.writeShellApplication {
    name = "stream-delta";
    runtimeInputs = [ (final.python3.withPackages (ps: [ ps.zstandard ])) ];
    text = ''exec python3 ${final.stream-delta-lib}/stream_delta.py "$@"'';
  };

  nas-at = final.writeShellApplication {
    name = "nas-at";
    runtimeInputs = [
      final.nilfs-utils
      final.nilfs-reclaim
      final.util-linux
      final.systemd
    ];
    text = ''
      PYTHONPATH=${final.stream-delta-lib} exec ${
        final.python3.withPackages (ps: [
          ps.fusepy
          ps.zstandard
        ])
      }/bin/python3 ${./nas-at.py} "$@"
    '';
  };
}
