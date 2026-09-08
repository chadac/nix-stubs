{ pkgs, nix-stubs }:

# Pack build graphs into a single reference-free OUTPUT.
#
# The .drv paths are inputs HERE (so nix mounts their closures for the packer,
# and substitutes any build-time outputs they name), but the result references
# nothing: unsafeDiscardReferences means a consumer walking a stub's closure —
# closureInfo, nix2container, dockerTools — sees one ordinary file instead of a
# .drv graph full of paths no binary cache serves. See nix/tests/closure.nix.
#
# Pack a SET of packages together where you can. A recipe closure is ~764 paths
# of stdenv bootstrap that every derivation shares, and a blob is opaque to the
# store's deduplication — so one blob per tool re-ships that chain per tool
# (+51 MB across six tools in scooter, the regression this signature exists to
# prevent), while one blob for the set pays it once.

{ name, drvs }:

pkgs.runCommand "recipe-${name}"
{
  __structuredAttrs = true;
  unsafeDiscardReferences.out = true;
}
  ''
    ${nix-stubs}/bin/nix-stubs recipe --out "$out" ${
      pkgs.lib.concatMapStringsSep " " (d: ''"${d}"'') drvs
    }
  ''
