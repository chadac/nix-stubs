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
      # drvPath WITH context — ensures .drv file is in the store
      drvPath = package.drvPath;
      # outPath WITHOUT context — just a string, doesn't force building
      outPath = unsafeDiscardStringContext (toString package);

      defaultBin = package.meta.mainProgram or (parseDrvName package.name).name;
      pkgName = if name != null then name else defaultBin;
      bins = if commands != null then commands else [ defaultBin ];

      mkShim = bin:
        writeShellScriptBin bin ''
          exec ${nix-stubs}/bin/nix-stubs exec \
            --drv-path "${drvPath}" \
            --out-path "${outPath}" \
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
