{
  description = "Lazy shims for Nix packages — tools available on PATH, downloaded on first use";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit system;
      });

      lockLib = import ./nix/lock.nix { inherit (nixpkgs) lib; };

      # `nix run .#gen` / `.#check` — apps append the user's args, so the
      # subcommand has to be baked in.
      wrap = pkgs: system: sub: pkgs.writeShellScriptBin "nix-stubs-${sub}" ''
        exec ${self.packages.${system}.nix-stubs}/bin/nix-stubs ${sub} "$@"
      '';
    in
    {
      packages = forAllSystems ({ pkgs, system, ... }: {
        nix-stubs = pkgs.callPackage ./nix/package.nix { };
        default = self.packages.${system}.nix-stubs;
      });

      apps = forAllSystems ({ pkgs, system, ... }: {
        gen = {
          type = "app";
          program = "${wrap pkgs system "gen"}/bin/nix-stubs-gen";
        };
        check = {
          type = "app";
          program = "${wrap pkgs system "check"}/bin/nix-stubs-check";
        };
      });

      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          packages = with pkgs; [ cargo rustc clippy rustfmt ];
        };
      });

      lib = {
        # The stub overlay. System-agnostic: it picks the entries for whatever
        # pkgs it is applied to.
        #
        #   nixpkgs.overlays = [
        #     (nix-stubs.lib.mkOverlay {
        #       stubs = pkgs: import ./stubs.nix { inherit pkgs; };
        #       lock = ./stubs.lock;
        #       flakeLock = ./flake.lock;
        #     })
        #   ];
        inherit (lockLib) mkOverlay assertSync read defaultBin;
      } // forAllSystems ({ pkgs, system, ... }:
        import ./nix/lib.nix {
          inherit pkgs;
          nix-stubs = self.packages.${system}.nix-stubs;
        }
      );

      # This repo dogfoods its own lock; see stubs.nix.
      stubs = forAllSystems ({ pkgs, ... }: import ./stubs.nix { inherit pkgs; });

      checks = forAllSystems ({ pkgs, system, ... }: {
        integration = import ./nix/tests/integration.nix {
          inherit pkgs;
          nix-stubs = self.packages.${system}.nix-stubs;
          nixStubsLib = self.lib.${system};
        };

        lock = import ./nix/tests/lock.nix {
          inherit pkgs lockLib;
          nix-stubs = self.packages.${system}.nix-stubs;
          stubsNix = ./stubs.nix;
          stubsLock = ./stubs.lock;
          flakeLock = ./flake.lock;
        };

        # Enumerating a stub's closure, the way every image builder does.
        # RED: see nix/tests/closure.nix.
        closure = import ./nix/tests/closure.nix {
          inherit pkgs lockLib;
          nix-stubs = self.packages.${system}.nix-stubs;
          stubsNix = ./stubs.nix;
          stubsLock = ./stubs.lock;
          flakeLock = ./flake.lock;
        };

        # The overlay end-to-end in a booted system, against this repo's own
        # stubs.nix/stubs.lock.
        overlay = import ./nix/tests/overlay.nix {
          inherit pkgs lockLib;
          nix-stubs = self.packages.${system}.nix-stubs;
          stubsNix = ./stubs.nix;
          stubsLock = ./stubs.lock;
          flakeLock = ./flake.lock;
        };
      });
    };
}
