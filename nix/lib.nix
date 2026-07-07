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
      # drvPath WITH context — ensures the .drv (and its build inputs) are in the
      # shim's closure, so the package can be realised on first use. We deliberately
      # do NOT embed the realised OUT path: writing it into the shim as a literal
      # /nix/store/… string makes Nix's REFERENCE SCANNER treat the full built
      # package as a runtime dependency of the shim — pulling it into the closure
      # and defeating the whole point (the shim would ship the package it's meant to
      # lazily fetch). unsafeDiscardStringContext drops the BUILD-time context but
      # NOT the scanner's textual match. Instead the dispatcher resolves the out
      # path from the .drv at runtime (`nix-store --query --outputs`, which reads the
      # drv's declared outputs WITHOUT realising them) — see resolve_out_path.
      drvPath = package.drvPath;

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
