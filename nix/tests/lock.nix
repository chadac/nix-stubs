{ pkgs, nix-stubs, lockLib, stubsNix, stubsLock, flakeLock }:

# Eval-level properties of the overlay, against THIS repo's real stubs.nix,
# stubs.lock and flake.lock. Runtime behaviour is in ./integration.nix and
# ./overlay.nix.
#
# Real artifacts rather than fixtures on purpose: a hand-written lock only proves
# the overlay can read a lock someone hand-wrote, and drifts silently the moment
# `gen` emits a field it does not have. These assertions are about the lock the
# repo actually ships.

let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;

  lock = lockLib.read stubsLock;
  declared = import stubsNix { inherit pkgs; };

  overlay = lockLib.mkOverlay {
    stubs = p: import stubsNix { pkgs = p; };
    lock = stubsLock;
    flakeLock = flakeLock;
    inherit nix-stubs;
  };

  stubbed = pkgs.extend overlay;

  # A flake.lock that moved without a relock. Derived from the real one so it
  # cannot drift from it, and so the assertion below is about the real pins.
  movedFlakeLock = lib.recursiveUpdate (lockLib.read flakeLock) {
    nodes.nixpkgs.locked.rev = "0000000000000000000000000000000000000000";
  };
  staleOverlay = lockLib.mkOverlay {
    stubs = p: import stubsNix { pkgs = p; };
    lock = stubsLock;
    flakeLock = movedFlakeLock;
    inherit nix-stubs;
  };
  stale = builtins.tryEval (builtins.attrNames (staleOverlay pkgs pkgs));

  entries = lock.packages.${system};

  # THE invariant tying the lock to evaluation: every drv the lock records is the
  # drv the package evaluates to right now. `nix-stubs check` enforces this in CI;
  # asserting it here means a drifted lock fails the test suite too.
  drvMatches = lib.mapAttrsToList
    (name: entry:
      let
        decl = declared.${name};
        pkg = if lib.isDerivation decl then decl else decl.package;
        actual = builtins.unsafeDiscardStringContext pkg.drvPath;
      in
      if actual == entry.drv then null else
      "${name}: lock records ${entry.drv} but stubs.nix evaluates to ${actual}")
    entries;
  drvDrift = lib.filter (e: e != null) drvMatches;

  helloOut = builtins.unsafeDiscardStringContext (toString pkgs.hello);
  helloDrv = builtins.unsafeDiscardStringContext pkgs.hello.drvPath;
in

assert lib.assertMsg (drvDrift == [ ])
  "stubs.lock disagrees with stubs.nix:\n  ${lib.concatStringsSep "\n  " drvDrift}";

assert lib.assertMsg (!stale.success)
  "a stubs.lock whose inputs disagree with flake.lock must throw, not silently build stale stubs";

assert lib.assertMsg (stubbed.hello.passthru.real == pkgs.hello)
  "passthru.real must be the package the stub stands in for";

assert lib.assertMsg (stubbed.hello.passthru.dev == pkgs.hello)
  "passthru.dev must be the real package, so buildInputs never receive a stub";

# Carried from the real package, because other packages read it — nixpkgs'
# uv-build does `inherit (pkgs.uv.meta) license`.
assert lib.assertMsg (stubbed.hello.meta.description or null == pkgs.hello.meta.description or null)
  "a stub must carry the real package's meta";

# ...except the parts that describe the stub's OWN store paths. ttyd's real
# outputsToInstall is [ "out" "man" ], and a stub has only `out`; passing it
# through makes environment.systemPackages fail inside buildEnv.
assert lib.assertMsg (stubbed.ttyd.meta.outputsToInstall == [ "out" ])
  "a stub must not claim outputs it does not have";

# The recipe must be a real dependency: opaque context on the .drv is what makes
# Nix copy it — and its own store references — along with the stub.
assert
  let ctx = builtins.getContext (builtins.unsafeDiscardOutputDependency pkgs.hello.drvPath);
  in lib.assertMsg (ctx.${helloDrv}.path or false)
    "the stub's drv reference must carry opaque context, or the recipe never travels with it";

assert
  let ctx = builtins.getContext (builtins.unsafeDiscardOutputDependency pkgs.hello.drvPath);
  in lib.assertMsg (!(ctx.${helloDrv}.allOutputs or false))
    "the stub must not depend on the package's OUTPUTS — that is what it exists to avoid shipping";

pkgs.runCommand "nix-stubs-lock-test" { } ''
  shim=${stubbed.hello}/bin/hello

  echo "--- the shim must name the recipe ---"
  grep -q '${helloDrv}' "$shim" \
    || { echo "FAIL: shim does not reference ${helloDrv}"; exit 1; }

  echo "--- and must NOT name the build output ---"
  if grep -qE '${helloOut}($|[^-])' "$shim"; then
    echo "FAIL: shim embeds ${helloOut}; the reference scanner would pull the"
    echo "      whole package into the stub's closure, defeating laziness"
    exit 1
  fi

  echo "--- and must select its output by name ---"
  grep -q -- '--output "out"' "$shim" \
    || { echo "FAIL: shim does not pass --output; multi-output packages would be a coin flip"; exit 1; }

  touch $out
''
