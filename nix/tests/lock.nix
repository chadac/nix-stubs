{ pkgs, nix-stubs, lockLib }:

# Eval-level properties of the overlay. Deliberately not a VM test: every claim
# here is decided at evaluation and build time. Runtime behaviour — including
# the closure guarantee in a real store — is in ./integration.nix.

let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;

  real = pkgs.writeShellScriptBin "locked-tool" ''echo locked-tool-success'';
  realDrv = builtins.unsafeDiscardStringContext real.drvPath;
  realOut = builtins.unsafeDiscardStringContext (toString real);

  # Fixtures are real files rather than writeText, so the lock is read the way a
  # consumer reads it (a path) instead of through import-from-derivation.
  fixture = ./fixtures;

  # `attr` differs from the entry name on purpose: the overlay must replace the
  # ATTRIBUTE, not the name the stub was declared under.
  stubs = _: {
    locked-tool = { package = real; attr = "hello"; };
  };

  mkOverlay = flakeLock: lockLib.mkOverlay {
    inherit stubs nix-stubs;
    lock = "${fixture}/stubs.lock";
    flakeLock = "${fixture}/${flakeLock}";
  };

  stubbed = pkgs.extend (mkOverlay "flake.lock");
  stub = stubbed.hello;

  # A lock whose nixpkgs pin no longer matches flake.lock must not evaluate.
  stale = builtins.tryEval (builtins.attrNames ((mkOverlay "flake-moved.lock") pkgs pkgs));

in

assert lib.assertMsg (!stale.success)
  "a stubs.lock whose inputs disagree with flake.lock must throw, not silently build stale stubs";

assert lib.assertMsg (stub.passthru.real == real)
  "passthru.real must be the package the stub stands in for";

assert lib.assertMsg (stub.passthru.dev == real)
  "passthru.dev must be the real package, so buildInputs never receive a stub";

# The recipe must be a real dependency of the stub. Opaque context on the .drv
# is what makes Nix copy it — and its own store references — along with the
# stub; allOutputs context would additionally drag in the built package.
assert
  let ctx = builtins.getContext (builtins.unsafeDiscardOutputDependency real.drvPath);
  in lib.assertMsg (ctx.${realDrv}.path or false)
    "the stub's drv reference must carry opaque context, or the recipe never travels with it";

assert
  let ctx = builtins.getContext (builtins.unsafeDiscardOutputDependency real.drvPath);
  in lib.assertMsg (!(ctx.${realDrv}.allOutputs or false))
    "the stub must not depend on the package's OUTPUTS — that is what it exists to avoid shipping";

# What the generated shim says. The closure itself is asserted in the VM test,
# where a real store is available to query.
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

  # The fixture lock names a drv that does not exist. The shim must carry the
  # one evaluation produced, because a drv path in a JSON file is inert — it can
  # name a recipe but it cannot make one a dependency.
  echo "--- and must NOT take its recipe from the lock's text ---"
  if grep -q 'not-a-real-recipe' "$shim"; then
    echo "FAIL: shim used the lock's drv string instead of the evaluated package"
    exit 1
  fi

  touch $out
''
