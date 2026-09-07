# The stub set — what to make lazy, and where each package comes from.
#
# `nix run .#gen` evaluates this (via the flake's `stubs.<system>` output) and
# records each package's .drv in stubs.lock. Nothing else evaluates it: the
# overlay builds stubs from the lock alone, which is what keeps a nixpkgs bump
# from re-evaluating — and re-building — every stubbed package.
#
# An entry is either a package, or an attrset:
#   package  the derivation to stub
#   bins     commands to put on PATH   (default: meta.mainProgram)
#   output   which output to exec from (default: the package's own outputName)
#   attr     nixpkgs attribute to replace (default: the entry name)
#
# This repo stubs a few cheap tools to dogfood its own lock in CI.

{ pkgs }:

{
  hello = pkgs.hello;
  tree = pkgs.tree;
  ripgrep = { package = pkgs.ripgrep; bins = [ "rg" ]; };

  # MULTI-OUTPUT on purpose (out + man). A stub inherits the real package's meta
  # so other packages can read it, and `meta.outputsToInstall` then names outputs
  # the stub does not have — which made environment.systemPackages fail with
  # "attribute 'man' missing" inside buildEnv. checks.overlay puts this on PATH in
  # a booted system, so that regression cannot come back quietly.
  ttyd = { package = pkgs.ttyd; output = "out"; };
}
