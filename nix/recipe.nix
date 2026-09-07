{ pkgs, nix-stubs }:

# Pack a package's build graph into a single reference-free OUTPUT.
#
# The .drv is an input HERE (so nix mounts its closure for the packer, and
# substitutes any build-time output paths it names), but the result references
# nothing: unsafeDiscardReferences means a consumer walking a stub's closure —
# closureInfo, nix2container, dockerTools — sees one ordinary file instead of a
# .drv graph full of paths no binary cache serves. See nix/tests/closure.nix.

{ name, drv }:

pkgs.runCommand "recipe-${name}"
{
  __structuredAttrs = true;
  unsafeDiscardReferences.out = true;
}
  ''
    ${nix-stubs}/bin/nix-stubs recipe --out "$out" "${drv}"
  ''
