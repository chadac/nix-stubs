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
#   drv     string naming the .drv, WITH context, so Nix's reference scanner
#           makes the recipe a dependency of the stub. A context-free string
#           would produce a stub naming a .drv that was never copied anywhere.
#   output  which output to exec from, BY NAME (awscli2 has out + dist).
#   meta/pname/version
#           carried over from the real package. A stub stands in for it inside a
#           package set, and other packages read those attributes: nixpkgs'
#           `uv-build` does `inherit (pkgs.uv.meta) license`, which fails with
#           "attribute 'license' missing" against a stub that invented its own
#           meta. None of this enters the .drv, so the closure is unaffected.
{ name, drv, output ? "out", bins, passthru ? { }, meta ? { }, pname ? null, version ? null }:

let
  mkShim = bin: writeShellScriptBin bin ''
    exec ${nix-stubs}/bin/nix-stubs exec \
      --drv-path "${drv}" \
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
