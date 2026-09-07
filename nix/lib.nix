{ pkgs, nix-stubs }:

let
  inherit (builtins) unsafeDiscardStringContext toString parseDrvName;
  inherit (pkgs) lib writeText;

  mkStub = import ./shim.nix { inherit pkgs nix-stubs; };
  lock = import ./lock.nix { inherit lib; };

  binsOf = pkg: [ (pkg.meta.mainProgram or (parseDrvName pkg.name).name) ];

  mkLazyPackage =
    { package
    , commands ? null
    , name ? null
    , output ? null
    }:
    let
      pkgName = if name != null then name else builtins.head (binsOf package);
    in
    mkStub {
      name = pkgName;
      # The stub must depend on the .drv so the recipe is copied along with it,
      # while NOT depending on the build outputs — that 449 MB is exactly what a
      # lazy stub exists to avoid shipping. `drvPath` carries `allOutputs`
      # context, which would pull the outputs in; discarding the OUTPUT
      # dependency drops that edge and keeps the .drv itself.
      #
      # Discarding the whole string context instead (as this did until #3) leaves
      # a stub naming a .drv that was never copied anywhere, and caches do not
      # serve .drv paths — so every invocation fails with "no substituter that
      # can build it".
      drv = builtins.unsafeDiscardOutputDependency package.drvPath;
      output = if output != null then output else package.outputName or "out";
      bins = if commands != null then commands else binsOf package;
      passthru = { dev = package; real = package; };
    };

  mkManifest = tools:
    let
      mkEntry = name: tool:
        let
          pkg = if lib.isDerivation tool then tool else tool.package;
          commands =
            if lib.isDerivation tool
            then binsOf pkg
            else tool.commands or (binsOf pkg);
        in {
          drv_path = unsafeDiscardStringContext pkg.drvPath;
          # The manifest is only ever stat'd, so it takes a context-free string
          # deliberately: a real reference here would pull the built package into
          # the manifest's closure.
          out_path = unsafeDiscardStringContext (toString pkg);
          inherit commands;
        };
    in
    writeText "nix-stubs-manifest.json" (builtins.toJSON { tools = lib.mapAttrs mkEntry tools; });

  # Eval-driven overlay: replaces nixpkgs attrs with stubs built from a live
  # `pkgs`. Prefer the lock-driven `mkOverlay` in nix/lock.nix — it builds the
  # same stubs without evaluating the packages.
  mkOverlay = tools: final: prev:
    lib.mapAttrs (name: toolCfg:
      mkLazyPackage {
        package = prev.${name};
        inherit name;
        commands = if toolCfg == { } then null else toolCfg.commands or null;
        output = if toolCfg == { } then null else toolCfg.output or null;
      }
    ) tools;

in {
  inherit mkLazyPackage mkManifest mkOverlay mkStub;
  inherit (lock) drvRef;
  mkLockOverlay = lock.mkOverlay;
}
