{ pkgs, nix-stubs }:

let
  inherit (pkgs) writeShellScriptBin symlinkJoin;
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
{ name, drv, output ? "out", bins, passthru ? { }, meta ? { } }:

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
symlinkJoin {
  name = "stub-${name}";
  paths = map mkShim bins;
  inherit passthru;
  meta = { mainProgram = builtins.head bins; } // meta;
}
