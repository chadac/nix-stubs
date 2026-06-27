flake:

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.nix-stubs;
  system = pkgs.system;
  nixStubsPkg = cfg.package;
  lazyLib = import ./lib.nix { inherit pkgs; nix-stubs = nixStubsPkg; };

  toolType = lib.types.either lib.types.package (lib.types.submodule {
    options = {
      package = lib.mkOption {
        type = lib.types.package;
        description = "The package to create lazy shims for.";
      };
      commands = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "List of command names to create shims for. Defaults to mainProgram.";
      };
    };
  });

  manifest = lazyLib.mkManifest cfg.tools;

  shimPackages = lib.mapAttrsToList (name: tool:
    let
      normalized = if lib.isDerivation tool then { package = tool; commands = []; } else tool;
      commands = if normalized.commands == [] then null else normalized.commands;
    in
    lazyLib.mkLazyPackage {
      package = normalized.package;
      inherit name commands;
    }
  ) cfg.tools;

  # Collect all shims into one directory for the shim-dir path
  shimDir = pkgs.symlinkJoin {
    name = "nix-stubs-shims";
    paths = shimPackages;
  };

in {
  options.programs.nix-stubs = {
    enable = lib.mkEnableOption "nix-stubs lazy tool loader";

    package = lib.mkOption {
      type = lib.types.package;
      default = flake.packages.${system}.nix-stubs;
      description = "The nix-stubs package to use.";
    };

    tools = lib.mkOption {
      type = lib.types.attrsOf toolType;
      default = { };
      description = ''
        Tools to create lazy shims for.
        Can be a package directly or an attrset with `package` and `commands`.

        Example:
          tools = {
            uv = pkgs.uv;
            ripgrep = { package = pkgs.ripgrep; commands = [ "rg" ]; };
          };
      '';
    };

    enableShellIntegration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable shell integration (prompt hook for PATH updates).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = shimPackages ++ [ nixStubsPkg ];

    # Shell integration — activate hook for dynamic PATH updates
    programs.bash.initExtra = lib.mkIf cfg.enableShellIntegration ''
      eval "$(${nixStubsPkg}/bin/nix-stubs activate bash --manifest "${manifest}" --shim-dir "${shimDir}/bin")"
    '';

    programs.zsh.initExtra = lib.mkIf cfg.enableShellIntegration ''
      eval "$(${nixStubsPkg}/bin/nix-stubs activate zsh --manifest "${manifest}" --shim-dir "${shimDir}/bin")"
    '';

    programs.fish.interactiveShellInit = lib.mkIf cfg.enableShellIntegration ''
      eval (${nixStubsPkg}/bin/nix-stubs activate fish --manifest "${manifest}" --shim-dir "${shimDir}/bin")
    '';
  };
}
