{ pkgs, nix-stubs, lockLib, stubsNix, stubsLock, flakeLock }:

# A stub must survive having its closure ENUMERATED: image builders (closureInfo,
# nix2container, dockerTools.streamLayeredImage) walk it with
# exportReferencesGraph, which requires every path in the graph to be locally
# valid. A stub ships the package's .drv, so its closure includes the .drv's own
# unrealised build-time outputs — paths a store that cannot substitute them will
# reject with "path '…' is not valid" (chadac/scooter#502).

let
  stubbed = pkgs.extend (lockLib.mkOverlay {
    stubs = p: import stubsNix { pkgs = p; };
    lock = stubsLock;
    flakeLock = flakeLock;
    inherit nix-stubs;
  });

  # The thing under test: enumerating a stub's closure the way an image build does.
  closure = pkgs.closureInfo { rootPaths = [ stubbed.hello ]; };
in
pkgs.runCommand "nix-stubs-closure-test" { } ''
  echo "--- the closure must enumerate, and must name the stub ---"
  grep -q '${stubbed.hello}' ${closure}/store-paths \
    || { echo "FAIL: the stub is not in its own closure listing"; exit 1; }
  touch $out
''
