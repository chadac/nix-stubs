{ pkgs, nix-stubs, nixStubsLib }:

# Runtime behaviour of a stub, in a real NixOS VM with a real Nix store.
# Eval-level properties (lock sync, passthru, context) are in ./lock.nix.

let
  inherit (nixStubsLib) mkStub;
  inherit (pkgs) lib;

  recipeOf = pkg: builtins.unsafeDiscardOutputDependency pkg.drvPath;

  testPkg = pkgs.writeShellScriptBin "lazy-test-tool" ''echo "lazy-test-output-success"'';

  # Two outputs, with the REAL binary in the second one. If the dispatcher
  # picked an output by position instead of by name it would find the decoy in
  # `out` and report success — so this fails loudly on a regression.
  multiPkg = pkgs.runCommand "multi-tool" { outputs = [ "out" "dist" ]; } ''
    mkdir -p $out/bin $dist/bin
    printf '#!/bin/sh\necho WRONG-OUTPUT\n' > $out/bin/multi-tool
    printf '#!/bin/sh\necho multi-output-success\n' > $dist/bin/multi-tool
    chmod +x $out/bin/multi-tool $dist/bin/multi-tool
  '';

  testStub = mkStub {
    name = "lazy-test-tool";
    drv = recipeOf testPkg;
    bins = [ "lazy-test-tool" ];
  };

  multiStub = mkStub {
    name = "multi-tool";
    drv = recipeOf multiPkg;
    output = "dist";
    bins = [ "multi-tool" ];
  };

  testPkgOutPath = builtins.unsafeDiscardStringContext (toString testPkg);
  testPkgDrvPath = builtins.unsafeDiscardStringContext testPkg.drvPath;

  # The tool the realisation subtest fetches. It is NOT in systemPackages, so
  # nothing roots it and the test can delete it from the VM store to create the
  # "not realised yet" state honestly.
  fetchedPkg = pkgs.writeShellScriptBin "fetched-tool" ''echo fetched-tool-success'';
  fetchedStub = mkStub {
    name = "fetched-tool";
    drv = recipeOf fetchedPkg;
    bins = [ "fetched-tool" ];
  };
  fetchedOut = builtins.unsafeDiscardStringContext (toString fetchedPkg);

in pkgs.testers.nixosTest {
  name = "nix-stubs-integration";

  nodes.machine = { config, pkgs, ... }: {
    virtualisation.memorySize = 2048;

    # The stubs' own closures carry recipes, not packages. These outputs are
    # supplied separately so exec can be tested without a from-source build in
    # the VM; the closure assertions below prove they did NOT arrive via the
    # stubs.
    virtualisation.additionalPaths = [ testPkg multiPkg multiPkg.dist fetchedPkg ];

    environment.systemPackages = [ nix-stubs testStub multiStub fetchedStub ];

    nix.settings = {
      experimental-features = [ "nix-command" ];
      # The ONLY substituter is a local directory the test fills at runtime. No
      # cache.nixos.org DNS lookups, and realisation is exercised for real: the
      # tool is deleted from the store and has to come back from here.
      substituters = lib.mkForce [ "file:///var/cache/test-substituter" ];
      require-sigs = false;
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("stub executes the tool"):
        machine.succeed("test -x $(which lazy-test-tool)")
        result = machine.succeed("lazy-test-tool")
        assert "lazy-test-output-success" in result, f"unexpected output: {result}"

    # THE guarantee, in both directions. The stub must carry the package's
    # RECIPE (no cache serves .drv paths, so nothing else can recover it) and
    # must NOT carry the package's OUTPUT (awscli2: 8.4 MB against 449 MB).
    # Both directions have been broken in this repo at different times.
    with subtest("stub closure carries the recipe and excludes the package"):
        stub = machine.succeed("readlink -f $(which lazy-test-tool)").strip()
        closure = machine.succeed(f"nix-store -q --requisites {stub}")

        assert "${testPkgOutPath}" not in closure, \
            "LEAK: the stub closure contains the realised package ${testPkgOutPath}"
        assert "${testPkgDrvPath}" in closure, \
            "MISSING RECIPE: ${testPkgDrvPath} is not in the stub closure, so the tool could never be realised"

        # The recipe is only useful if its own inputs travelled with it.
        machine.succeed("nix-store -q --requisites ${testPkgDrvPath} >/dev/null")

    with subtest("multi-output packages are selected by NAME, not position"):
        result = machine.succeed("multi-tool")
        assert "multi-output-success" in result, \
            f"expected the 'dist' output's binary, got: {result}"
        assert "WRONG-OUTPUT" not in result, \
            "the dispatcher took an output by position; awscli2 has out + dist and would break"

    # Both remaining subtests need a tool that is genuinely NOT realised. The VM
    # gets there by publishing the tool to a local binary cache and then deleting
    # it from the store — rather than by BUILDING one in-VM, which is unreliable
    # on GitHub runners: a trivial builder was killed by signal 9 there, both
    # sandboxed and under __noChroot, at 2 GiB and at 4 GiB. Substituting is also
    # the path production actually takes.
    with subtest("publish the tool to a local substituter, then remove it"):
        machine.succeed(
            "nix --extra-experimental-features nix-command copy "
            "--to file:///var/cache/test-substituter ${fetchedOut}"
        )
        # Nothing roots it: fetched-tool is not in systemPackages, only its stub is.
        machine.succeed("nix-store --delete ${fetchedOut}")
        machine.succeed("test ! -e ${fetchedOut}")

    # A stub on a build input can't work — a build sandbox has no daemon socket.
    # It must say so, naming the escape hatch, rather than emitting an opaque
    # nix-store error. Ordered before the realisation subtest so it runs while
    # the tool is still absent.
    with subtest("a stub refuses to realise inside a build sandbox"):
        err = machine.fail("NIX_BUILD_TOP=/build fetched-tool 2>&1")
        assert "build sandbox" in err, f"expected a build-sandbox diagnostic, got: {err}"
        assert ".real" in err, f"the error should name the escape hatch, got: {err}"
        machine.succeed("test ! -e ${fetchedOut}")

    with subtest("first use realises a tool that is not in the store"):
        result = machine.succeed("fetched-tool")
        assert "fetched-tool-success" in result, f"unexpected output: {result}"
        machine.succeed("test -e ${fetchedOut}")
  '';
}
