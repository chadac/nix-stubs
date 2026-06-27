{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "nix-stubs";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../src
    ];
  };

  cargoLock.lockFile = ../Cargo.lock;

  meta = {
    description = "Lazy shims for Nix packages — tools available on PATH, downloaded on first use";
    mainProgram = "nix-stubs";
  };
}
