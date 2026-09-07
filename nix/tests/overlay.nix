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

    # Seed the real outputs (from the UN-stubbed set) so a shim finds them
    # already realised — the VM has no network.
    system.extraDependencies = [ realHelloOut ];

    nix.settings.experimental-features = [ "nix-command" ];
  };

  testScript = ''
    machine.wait_for_unit("default.target")

    with subtest("the overlay put stubs on PATH, under the right command names"):
        hello = machine.succeed("readlink -f $(command -v hello)").strip()
        assert "stub-hello" in hello, f"hello on PATH is not a stub: {hello}"

        # `rg`, not `ripgrep`: the command name comes from stubs.nix's `bins`.
        rg = machine.succeed("readlink -f $(command -v rg)").strip()
        assert "stub-ripgrep" in rg, f"rg on PATH is not a stub: {rg}"

        # A MULTI-OUTPUT package survives systemPackages. Before the stub
        # overrode meta.outputsToInstall, buildEnv failed the whole system build
        # here with "attribute 'man' missing".
        machine.succeed("command -v ttyd")

    with subtest("the closure carries recipes, not packages"):
        closure = machine.succeed("nix-store -q --requisites /run/current-system")
        assert "${helloRecipe}" in closure, \
            "MISSING RECIPE: hello's .drv is absent, so it could never be realised"

    with subtest("a stub execs the real tool"):
        out = machine.succeed("hello")
        assert "Hello, world!" in out, f"the stub did not run the real hello: {out!r}"
  '';
}
