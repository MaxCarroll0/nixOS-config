# Rust disk ledger daemon and collector.

{
  lib,
  rustPlatform,
  git,
}:

let
  root = ../modules/nixos/disk-ledger;
in
rustPlatform.buildRustPackage {
  pname = "disk-ledger";
  version = "0.1.0";
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/Cargo.toml")
      (root + "/Cargo.lock")
      (root + "/src")
    ];
  };
  cargoLock.lockFile = root + "/Cargo.lock";
  nativeCheckInputs = [ git ];
  meta.mainProgram = "disk-ledger";
}
