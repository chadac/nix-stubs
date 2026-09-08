{ pkgs, nix-stubs }:

# Per-system helpers. The lock-driven overlay lives in nix/lock.nix and is
# system-agnostic; this is only for building a stub by hand.

{
  mkStub = import ./shim.nix { inherit pkgs nix-stubs; };
}
