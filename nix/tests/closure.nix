{ pkgs, nix-stubs, lockLib, stubsNix, stubsLock, flakeLock }:

# A stub must survive having its closure ENUMERATED: image builders (closureInfo,
# nix2container, dockerTools.streamLayeredImage) walk it with
# exportReferencesGraph, which requires every path in the graph to be locally
# valid.
#
# So the invariant is structural, and asserted as such below: NO .drv in a stub's
# closure. Enumerating alone is too weak a check — a .drv's closure names
# build-time outputs (`autoreconf-hook`), and any store that can substitute them
# enumerates happily, which is why this passed here while it broke a consumer's
# image build with "path '…' is not valid" (chadac/scooter#502).

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

  echo "--- and must contain no .drv, which is what an image build chokes on ---"
  if grep '\.drv$' ${closure}/store-paths; then
    echo "FAIL: the stub closure ships store derivations (listed above)."
    echo "They drag in unrealised build-time outputs that no cache serves."
    exit 1
  fi

  echo "--- the recipe travels as an ordinary output instead ---"
  grep -q -- '-recipe-hello$' ${closure}/store-paths \
    || { echo "FAIL: no recipe blob in the closure; the tool could never be realised"; exit 1; }
  touch $out
''
