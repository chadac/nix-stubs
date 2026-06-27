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
    in
    {
      packages = forAllSystems ({ pkgs, ... }: {
        nix-stubs = pkgs.callPackage ./nix/package.nix { };
        default = self.packages.${pkgs.system}.nix-stubs;
      });

      lib = forAllSystems ({ pkgs, ... }:
        import ./nix/lib.nix {
          inherit pkgs;
          nix-stubs = self.packages.${pkgs.system}.nix-stubs;
        }
      );

      checks = forAllSystems ({ pkgs, system, ... }: {
        integration = import ./nix/tests/integration.nix {
          inherit pkgs;
          nix-stubs = self.packages.${system}.nix-stubs;
          nixStubsLib = self.lib.${system};
        };
      });

      homeManagerModules.default = import ./nix/module.nix self;
    };
}
