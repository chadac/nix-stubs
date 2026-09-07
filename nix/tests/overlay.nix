{ pkgs, nix-stubs, lockLib, stubsNix, stubsLock, flakeLock }:

# nixosTest: the WHOLE path, in a booted system — stubs.nix -> stubs.lock ->
# overlay -> environment.systemPackages -> a tool that runs.
#
# integration.nix tests the shim mechanism with hand-built stubs; this tests the
# overlay a consumer actually uses. The difference matters: a stub built through
# the overlay inherits the real package's `meta`, and that is what broke
# `environment.systemPackages` (buildEnv reads meta.outputsToInstall, which names
# outputs a single-output stub does not have). `ttyd` is in the stub set as a
# multi-output package precisely so this test would fail if that came back.
#
# Hermetic: the VM has no network. The real outputs are pre-seeded so a shim can
# exec without building; the closure assertions need no network at all.

let
  stubbed = pkgs.extend (lockLib.mkOverlay {
    stubs = p: import stubsNix { pkgs = p; };
    lock = stubsLock;
    flakeLock = flakeLock;
    inherit nix-stubs;
  });

  # The DERIVATION, for seeding. A context-free string here would seed nothing:
  # extraDependencies needs a real dependency to copy the path into the VM store,
  # which is the same lesson this project is built on.
  realHello = pkgs.hello;
  realHelloOut = builtins.unsafeDiscardStringContext (toString pkgs.hello);
  helloRecipe = builtins.unsafeDiscardStringContext pkgs.hello.drvPath;
in
pkgs.testers.runNixOSTest {
  name = "nix-stubs-overlay";

  # The framework sets `nixpkgs.pkgs`, which conflicts with the `nixpkgs.overlays`
  # option — so the overlaid package set goes in through `node.pkgs`. mkForce
  # because runNixOSTest defines that option itself, from the outer pkgs.
  node.pkgs = pkgs.lib.mkForce stubbed;

  nodes.machine = { pkgs, ... }: {
    # Straight from the overlay: these are stubs, and nothing here says so.
    environment.systemPackages = [ pkgs.hello pkgs.ripgrep pkgs.ttyd ];

    # Seed the real output into the VM STORE so a shim finds it already realised
    # (the VM has no network) WITHOUT adding it to the system closure —
    # system.extraDependencies would, which is exactly what the closure assertion
    # below must be able to rule out.
    virtualisation.additionalPaths = [ realHello ];

    nix.settings.experimental-features = [ "nix-command" ];
  };

  testScript = ''
    machine.wait_for_unit("default.target")

    with subtest("the overlay put stubs on PATH, under the right command names"):
        # Assert on CONTENT, not on the store path name: `readlink -f` follows
        # through symlinkJoin into the per-command shim, whose derivation is named
        # for the COMMAND (…-hello), so a name check reads as "not a stub" even
        # when it is one.
        hello = machine.succeed("cat $(command -v hello)")
        assert "nix-stubs exec" in hello, f"hello on PATH is not a stub:\n{hello}"

        # `rg`, not `ripgrep`: the command name comes from stubs.nix's `bins`.
        rg = machine.succeed("cat $(command -v rg)")
        assert "nix-stubs exec" in rg, f"rg on PATH is not a stub:\n{rg}"

        # A MULTI-OUTPUT package survives systemPackages. Before the stub
        # overrode meta.outputsToInstall, buildEnv failed the whole system build
        # here with "attribute 'man' missing".
        machine.succeed("command -v ttyd")

    with subtest("the closure carries recipes, not packages"):
        closure = machine.succeed("nix-store -q --requisites /run/current-system")
        assert "${helloRecipe}" in closure, \
            "MISSING RECIPE: hello's .drv is absent, so it could never be realised"
        # The package is present in the VM store (seeded, so the shim can exec it)
        # but must NOT be part of the system — that is the whole point.
        assert "${realHelloOut}" not in closure, \
            "LEAK: hello's built output is in the system closure"

    with subtest("a stub execs the real tool"):
        out = machine.succeed("hello")
        assert "Hello, world!" in out, f"the stub did not run the real hello: {out!r}"
  '';
}
