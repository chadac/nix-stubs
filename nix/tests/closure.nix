{ pkgs, nix-stubs, lockLib, stubsNix, stubsLock, flakeLock }:

# A stub must survive having its closure ENUMERATED, because that is what every
# image builder does: closureInfo (NixOS store images, scooter's sandbox image),
# nix2container, dockerTools.streamLayeredImage. They walk the graph with
# exportReferencesGraph and require every path in it to be locally valid.
#
# This is currently RED, and deliberately so. A stub carries the package's .drv,
# and a .drv's closure contains unrealised build-time OUTPUT paths — for
# `hello`, 10 of its 179 non-.drv paths have a deriver (an autoreconf-hook, a
# fetchpatch result). On a machine that does not already have them:
#
#     error: path '/nix/store/…-expr-strcmp.patch' is not valid
#
# Found by migrating scooter (chadac/scooter#502), where it took down the image
# build, the image-size benchmark and the k3d boot — not just a test. It is the
# hazard the pre-refactor comment in this repo warned about, which I wrongly
# dismissed: the closure is only "all valid" on a machine that happened to build
# the inputs.
#
# The fix is to stop shipping .drv files in the closure and ship the recipe as a
# derivation OUTPUT instead — one ordinary path, nothing unusual to walk.

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
