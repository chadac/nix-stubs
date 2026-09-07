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

  # A derivation the VM can build with no stdenv, for the realisation path.
  # Instantiated inside the VM so its output genuinely does not exist yet.
  #
  # Builds in the normal sandbox with store-path tools. An earlier version used
  # `__noChroot` with /bin/sh and PATH pointing at the host system; its builder
  # was killed by signal 9 on a GitHub runner (not OOM — no kill event in the
  # journal), which is the kind of thing sandbox escape hatches invite.
  dynamicTestNix = pkgs.writeText "dynamic-test.nix" ''
    derivation {
      name = "dynamic-test-tool";
      system = builtins.currentSystem;
      builder = "${pkgs.bash}/bin/bash";
      args = [
        "-c"
        "${pkgs.coreutils}/bin/mkdir -p $out/bin && printf '#!/bin/sh\necho dynamic-test-success\n' > $out/bin/dynamic-test-tool && ${pkgs.coreutils}/bin/chmod +x $out/bin/dynamic-test-tool"
      ];
    }
  '';

in pkgs.testers.nixosTest {
  name = "nix-stubs-integration";

  nodes.machine = { config, pkgs, ... }: {
    virtualisation.memorySize = 2048;

    # The stubs' own closures carry recipes, not packages. These outputs are
    # supplied separately so exec can be tested without a from-source build in
    # the VM; the closure assertions below prove they did NOT arrive via the
    # stubs.
    virtualisation.additionalPaths = [ testPkg multiPkg multiPkg.dist pkgs.bash pkgs.coreutils ];

    environment.systemPackages = [ nix-stubs testStub multiStub ];

    nix.settings = {
      experimental-features = [ "nix-command" ];
      # No cache.nixos.org DNS lookups in the VM.
      substituters = lib.mkForce [ ];
    };

    environment.etc."dynamic-test.nix".source = dynamicTestNix;
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

    # Ordered before the realisation subtest on purpose: this needs an output
    # that genuinely does not exist yet, and deleting one afterwards is not
    # reliable (it may be a GC root, and a failed delete would silently turn
    # this into a no-op that passes).
    #
    # A stub on a build input can't work — a build sandbox has no daemon socket.
    # It must say so, naming the escape hatch, rather than emitting an opaque
    # nix-store error.
    with subtest("a stub refuses to realise inside a build sandbox"):
        drv = machine.succeed("nix-instantiate /etc/dynamic-test.nix").strip()
        out = machine.succeed(f"nix-store -q --binding out {drv}").strip()
        machine.succeed(f"test ! -e {out}")

        err = machine.fail(
            f"NIX_BUILD_TOP=/build nix-stubs exec --drv-path {drv} dynamic-test-tool 2>&1"
        )
        assert "build sandbox" in err, f"expected a build-sandbox diagnostic, got: {err}"
        assert ".real" in err, f"the error should name the escape hatch, got: {err}"
        machine.succeed(f"test ! -e {out}")

    with subtest("first use realises a package that is not in the store"):
        drv = machine.succeed("nix-instantiate /etc/dynamic-test.nix").strip()
        out = machine.succeed(f"nix-store -q --binding out {drv}").strip()
        machine.succeed(f"test ! -e {out}")

        result = machine.succeed(f"nix-stubs exec --drv-path {drv} dynamic-test-tool")
        assert "dynamic-test-success" in result, f"unexpected output: {result}"
        machine.succeed(f"test -e {out}")
  '';
}
