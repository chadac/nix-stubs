{ pkgs, nix-stubs }:

let
  inherit (pkgs) lib writeShellScriptBin symlinkJoin;
in

# Build the stub package for one tool.
#
# Both entry points funnel through here — the eval-driven `mkLazyPackage` (you
# have a real package) and the lock-driven overlay (you have a drv path from
# stubs.lock) — so a stub is identical whichever way it was declared. They
# differ only in how `drv` acquired its string context; see nix/lock.nix.
#
#   drv     string naming the .drv, WITH context — the recipe derivation needs
#           it as a real input to pack it. The shim itself names it context-free;
#           what travels with the stub is the packed blob (nix/recipe.nix).
#   sharedRecipe
#           a blob packed for SEVERAL stubs at once. Prefer it: a blob is opaque
#           to store deduplication, so one per tool re-ships the stdenv chain
#           they all share (nix/recipe.nix).
#   output  which output to exec from, BY NAME (awscli2 has out + dist). Resolved
#           at RUN time, not baked in: naming the out path here would put it in
#           the shim's text, and the reference scanner would then pull the whole
#           package into the stub's closure (nix/tests/lock.nix guards this).
#   meta/pname/version
#           carried over from the real package. A stub stands in for it inside a
#           package set, and other packages read those attributes: nixpkgs'
#           `uv-build` does `inherit (pkgs.uv.meta) license`, which fails with
#           "attribute 'license' missing" against a stub that invented its own
#           meta. None of this enters the .drv, so the closure is unaffected.
{ name
, drv
, output ? "out"
, sharedRecipe ? null
, bins
, passthru ? { }
, meta ? { }
, pname ? null
, version ? null
}:

let
  # One blob for the whole stub set when the caller has one (the lock-driven
  # overlay does); otherwise this stub packs its own.
  recipe =
    if sharedRecipe != null then sharedRecipe
    else import ./recipe.nix { inherit pkgs nix-stubs; } { inherit name; drvs = [ drv ]; };

  # Context-FREE: the shim names the .drv but must not depend on it, or the
  # closure carries a .drv graph again and enumeration breaks. The recipe blob
  # is the dependency that makes the path recoverable at first use.
  drvPath = builtins.unsafeDiscardStringContext drv;

  mkShim = bin: writeShellScriptBin bin ''
    exec ${nix-stubs}/bin/nix-stubs exec \
      --drv-path "${drvPath}" \
      --recipe "${recipe}" \
      --output "${output}" \
      --bin "${bin}" \
      "${name}" \
      -- "$@"
  '';
in
symlinkJoin ({
  name = "stub-${name}";
  paths = map mkShim bins;
  inherit passthru;
  # `outputsToInstall` is overridden, not inherited: it names the real package's
  # outputs (ttyd's is [ "out" "man" ]) and a stub has only `out`, so passing it
  # through makes environment.systemPackages fail with "attribute 'man' missing"
  # inside buildEnv. mainProgram is likewise the stub's own.
  meta = meta // {
    mainProgram = builtins.head bins;
    outputsToInstall = [ "out" ];
  };
}
// lib.optionalAttrs (pname != null) { inherit pname; }
// lib.optionalAttrs (version != null) { inherit version; })
