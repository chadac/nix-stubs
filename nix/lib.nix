{ pkgs, nix-stubs }:

let
  inherit (builtins) unsafeDiscardStringContext toString parseDrvName;
  inherit (pkgs) lib writeShellScriptBin symlinkJoin writeText;

  mkLazyPackage = {
    package,
    commands ? null,
    name ? null,
  }:
    let
      # The shim references the .drv so the package can be realised on first use.
      # We deliberately do NOT embed the realised OUT path: writing it into the shim
      # as a literal /nix/store/… string makes Nix's REFERENCE SCANNER treat the full
      # built package as a runtime dependency of the shim — pulling it into the
      # closure and defeating the whole point (the shim would ship the package it's
      # meant to lazily fetch). The dispatcher instead resolves the out path from the
      # .drv at runtime (`nix-store --query --outputs`, which reads the drv's declared
      # outputs WITHOUT realising them) — see resolve_out_path.
      #
      # `package.drvPath` carries context with `allOutputs = true`, which makes the
      # .drv's ENTIRE build-output closure a dependency of the shim. That's more than
      # we need (we only need the .drv file itself to query/realise it) and it's
      # actively harmful downstream: a consumer that layers the shim's closure into an
      # OCI image via `dockerTools.streamLayeredImage` enumerates every path in that
      # closure as a layer — INCLUDING build-time output paths that were never
      # realised (e.g. a bootstrap `musl-1.2.6` referenced by a build tool's
      # `stdenv-linux.drv`). The tar step then `os.lstat`s the unrealised path and the
      # whole image build dies with `FileNotFoundError: …-musl-1.2.6`.
      #
      # Even `unsafeDiscardOutputDependency` isn't enough: it drops the "all outputs"
      # dependency, but the .drv FILE stays in the closure, and a .drv file textually
      # names its (and its build tools') output paths, which Nix's scanner re-adds and
      # streamLayeredImage then tries to layer. So we embed the .drv path as a pure
      # string with NO context at all: the .drv is NOT pulled into the shim's closure,
      # and the dispatcher realises it at runtime (`nix-store --realise <drv>`), which
      # substitutes the .drv + builds the tool from the configured caches on first use.
      # This keeps the lazy shim genuinely tiny (no build-closure baked) — the whole
      # point of a lazy tool — and keeps unrealised toolchain outputs out of any image
      # that layers the shim.
      drvPath = unsafeDiscardStringContext package.drvPath;

      defaultBin = package.meta.mainProgram or (parseDrvName package.name).name;
      pkgName = if name != null then name else defaultBin;
      bins = if commands != null then commands else [ defaultBin ];

      mkShim = bin:
        writeShellScriptBin bin ''
          exec ${nix-stubs}/bin/nix-stubs exec \
            --drv-path "${drvPath}" \
            --bin "${bin}" \
            "${pkgName}" \
            -- "$@"
        '';
    in
    symlinkJoin {
      name = "lazy-${pkgName}";
      paths = map mkShim bins;
    };

  mkManifest = tools:
    let
      mkEntry = name: tool:
        let
          pkg = if lib.isDerivation tool then tool else tool.package;
          commands =
            if lib.isDerivation tool
            then [ (pkg.meta.mainProgram or (parseDrvName pkg.name).name) ]
            else tool.commands or [ (pkg.meta.mainProgram or (parseDrvName pkg.name).name) ];
        in {
          drv_path = pkg.drvPath;
          out_path = unsafeDiscardStringContext (toString pkg);
          inherit commands;
        };

      manifestData = {
        tools = lib.mapAttrs mkEntry tools;
      };
    in
    writeText "nix-stubs-manifest.json" (builtins.toJSON manifestData);

  # Overlay that replaces packages in nixpkgs with lazy stubs.
  # tools: attrset mapping nixpkgs attribute names to config.
  #   { commands = [ "rg" ]; }  — explicit command list
  #   {}                        — infer commands from meta.mainProgram
  mkOverlay = tools: final: prev:
    lib.mapAttrs (name: toolCfg:
      let
        commands = if toolCfg == {} then null else toolCfg.commands or null;
      in
      mkLazyPackage {
        package = prev.${name};
        inherit name commands;
      }
    ) tools;

in {
  inherit mkLazyPackage mkManifest mkOverlay;
}
