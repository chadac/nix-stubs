{ pkgs, nix-stubs, lockLib }:

# Eval-level properties of the lock-driven overlay. Deliberately not a VM test:
# every claim here is decided at evaluation and build time — what a stub's
# closure contains, and when the sync check fires.

let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;

  real = pkgs.writeShellScriptBin "locked-tool" ''echo locked-tool-success'';
  realDrv = builtins.unsafeDiscardStringContext real.drvPath;
  realOut = builtins.unsafeDiscardStringContext (toString real);

  # Fixtures are real files rather than writeText, so the lock is read the way a
  # consumer reads it (a path) instead of through import-from-derivation.
  fixture = ./fixtures;

  mkLock = drv: {
    version = 1;
    inputs.nixpkgs = (lockLib.read "${fixture}/stubs.lock").inputs.nixpkgs;
    packages.${system}.locked-tool = {
      # `attr` differs from the entry name on purpose: the overlay must replace
      # the ATTRIBUTE, not the name the stub was declared under.
      attr = "hello";
      inherit drv;
      output = "out";
      bins = [ "locked-tool" ];
      name = "locked-tool";
    };
  };

  overlay = lockLib.mkOverlay {
    lock = mkLock realDrv;
    flakeLock = "${fixture}/flake.lock";
    inherit nix-stubs;
  };

  stubbed = pkgs.extend overlay;
  stub = stubbed.hello;

  # A lock whose nixpkgs pin no longer matches flake.lock must not evaluate.
  staleOverlay = lockLib.mkOverlay {
    lock = mkLock realDrv;
    flakeLock = "${fixture}/flake-moved.lock";
    inherit nix-stubs;
  };
  stale = builtins.tryEval (builtins.attrNames (staleOverlay pkgs pkgs));

  # The dependency edge, asserted directly. `path = true` is opaque context: it
  # puts the .drv in the stub's inputSrcs, which is what makes Nix copy the
  # recipe (and its own store references) along with the stub. A context-free
  # string here is the failure mode this project exists to avoid — a stub naming
  # a .drv that was never copied anywhere and that no cache will serve.
  drvContext = builtins.getContext (lockLib.drvRef realDrv);

in

assert lib.assertMsg (drvContext.${realDrv}.path or false)
  "a drv path read from stubs.lock must carry opaque context, or the recipe never travels with the stub";

assert lib.assertMsg (!(drvContext.${realDrv}.allOutputs or false))
  "the stub must not depend on the package's OUTPUTS — that is the 449 MB it exists to avoid";

assert lib.assertMsg (!stale.success)
  "a stubs.lock whose inputs disagree with flake.lock must throw, not silently build stale stubs";

assert lib.assertMsg (stub.passthru.real == pkgs.hello)
  "passthru.real must be the package the stub stands in for";

assert lib.assertMsg (stub.passthru.dev == pkgs.hello)
  "passthru.dev must be the real package, so buildInputs never receive a stub";

# What the generated shim says. The closure itself is asserted in the VM test
# (integration.nix, "shim closure EXCLUDES the realised package"), where a real
# store is available to query.
pkgs.runCommand "nix-stubs-lock-test" { } ''
  shim=${stub}/bin/locked-tool

  echo "--- the shim must name the recipe ---"
  grep -q '${realDrv}' "$shim" \
    || { echo "FAIL: shim does not reference ${realDrv}"; exit 1; }

  echo "--- and must NOT name the build output ---"
  if grep -qE '${realOut}($|[^-])' "$shim"; then
    echo "FAIL: shim embeds ${realOut}; the reference scanner would pull the"
    echo "      whole package into the stub's closure, defeating laziness"
    exit 1
  fi

  echo "--- and must select its output by name ---"
  grep -q -- '--output "out"' "$shim" \
    || { echo "FAIL: shim does not pass --output; multi-output packages would be a coin flip"; exit 1; }

  touch $out
''
