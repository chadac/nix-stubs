{ lib }:

let
  readJSON = f: builtins.fromJSON (builtins.readFile f);

  # Accepts a path (the normal case — ./stubs.lock), or an already-parsed
  # attrset. A path keeps this out of import-from-derivation territory.
  asAttrs = v: if builtins.isAttrs v && !(lib.isDerivation v) then v else readJSON v;

  # Resolve a root-level input of a flake.lock to its `locked` node.
  # flake.lock nodes reference each other by name; a root input is either a node
  # name (a string) or a "follows" path (a list), which we don't resolve.
  lockedInput = flakeLock: name:
    let
      root = flakeLock.nodes.${flakeLock.root};
      ref = root.inputs.${name} or (throw ''
        nix-stubs: input '${name}' is recorded in stubs.lock but is not an input
        of this flake. Either add it to flake.nix or regenerate stubs.lock.
      '');
    in
    if builtins.isString ref
    then flakeLock.nodes.${ref}.locked
    else throw ''
      nix-stubs: input '${name}' is a 'follows' input, which stubs.lock cannot
      pin. Depend on it directly, or drop it from the locked input set.
    '';

  fmtInput = l:
    let rev = l.rev or l.narHash or "?";
    in "${l.type or "?"}:${l.owner or ""}/${l.repo or l.url or l.path or ""} @ ${rev}";

  # stubs.lock is synced to flake.lock: every input it pins must still be pinned
  # to the same revision by the consumer's flake.lock. A nixpkgs bump therefore
  # fails loudly instead of silently shipping stubs recorded against the old
  # revision.
  syncErrors = { lock, flakeLock }:
    lib.filter (e: e != null) (lib.mapAttrsToList
      (name: pinned:
        let actual = lockedInput flakeLock name;
        in if actual == pinned then null else ''
            input '${name}'
              flake.lock  ${fmtInput actual}
              stubs.lock  ${fmtInput pinned}'')
      lock.inputs);

  assertSync = { lock, flakeLock, lockPath ? "stubs.lock" }:
    let errs = syncErrors { inherit lock flakeLock; };
    in
    if errs == [ ] then true else throw ''

      nix-stubs: ${lockPath} is out of sync with flake.lock

      ${lib.concatStringsSep "\n\n  " errs}

      Regenerate the lock:  nix run github:chadac/nix-stubs#gen
      Check it in CI with:  nix run github:chadac/nix-stubs#check
    '';

  defaultBin = pkg: pkg.meta.mainProgram or (builtins.parseDrvName pkg.name).name;

  normalize = name: decl:
    if lib.isDerivation decl
    then { package = decl; attr = name; bins = null; output = null; }
    else {
      inherit (decl) package;
      attr = decl.attr or name;
      bins = decl.bins or null;
      output = decl.output or null;
    };

in
{
  inherit lockedInput syncErrors assertSync defaultBin;

  read = asAttrs;

  # Turn a stub set into a nixpkgs overlay, replacing each declared attribute
  # with a stub that carries the package's RECIPE and not the package.
  #
  # The drv comes from evaluating the package, not from stubs.lock. A drv path
  # in a JSON file is inert: to be usable it has to be a dependency, and the
  # only ways to make it one are eval-time context (builtins.appendContext and
  # builtins.storePath both call ensurePath, so they require the .drv to already
  # be in the evaluating machine's store — and no binary cache serves .drv
  # paths) or shipping the recipe out of band. So the lock cannot replace
  # evaluation; it records what the evaluation is expected to produce, and
  # `nix-stubs check` enforces that in CI.
  #
  #   stubs      pkgs -> attrset of declarations (usually `import ./stubs.nix`)
  #   lock       ./stubs.lock — supplies discovered bins/output, and the pins
  #   flakeLock  ./flake.lock — the lock must still agree with it
  mkOverlay =
    { stubs
    , lock
    , flakeLock
    , lockPath ? "stubs.lock"
    , nix-stubs ? null
    }:
    final: prev:
    let
      lock' = asAttrs lock;
      flakeLock' = asAttrs flakeLock;
      synced = assertSync { lock = lock'; flakeLock = flakeLock'; inherit lockPath; };

      system = prev.stdenv.hostPlatform.system;
      locked = lock'.packages.${system} or (throw "nix-stubs: ${lockPath} has no packages for system ${system}");

      # `prev`, not `final`: a stub set that reached for the stubbed attributes
      # would be its own input.
      decls = stubs prev;

      declFor = name:
        normalize name (decls.${name} or (throw ''
          nix-stubs: ${lockPath} has an entry for '${name}', but stubs.nix does
          not declare it. Regenerate the lock: nix run github:chadac/nix-stubs#gen
        ''));

      pkg = if nix-stubs != null then nix-stubs else prev.callPackage ./package.nix { };
      mkStub = import ./shim.nix { pkgs = prev; nix-stubs = pkg; };

      # The recipe for the WHOLE set, packed once. Per-stub blobs would each
      # carry the stdenv bootstrap chain the others already have — a blob is one
      # opaque file, so the store cannot share it the way it shares .drv paths.
      recipeDrv = name:
        builtins.unsafeDiscardOutputDependency (declFor name).package.drvPath;

      sharedRecipe = import ./recipe.nix { pkgs = prev; nix-stubs = pkg; } {
        name = "stub-set";
        drvs = map recipeDrv (builtins.attrNames locked);
      };

      # Iterating the LOCK rather than the declarations is what keeps this
      # terminating. The overlay's attribute names have to be known before the
      # package set is complete, and the lock supplies them as plain strings.
      # Deriving a name from a declaration instead means forcing `prev.<attr>`
      # mid-construction, which is an infinite recursion.
      stubFor = name: entry:
        let
          d = declFor name;
          real = d.package;
          # The lock wins over the declaration: it is where `--discover-bins`
          # results are recorded, and `check` keeps the two from disagreeing.
          #
          # Spelled out rather than chained with `or`: that operator is attribute
          # selection with a default, so an attribute that exists and is null
          # wins over the fallback instead of deferring to it.
          output =
            if entry ? output then entry.output
            else if d.output != null then d.output
            else real.outputName or "out";
        in
        lib.nameValuePair (entry.attr or d.attr) (mkStub {
          inherit name output sharedRecipe;
          # Carried over so the stub still looks like the package it replaces to
          # everything else in the set — nixpkgs' uv-build reads pkgs.uv.meta.license,
          # and a stub with invented meta breaks that package's eval outright.
          meta = real.meta or { };
          pname = real.pname or null;
          version = real.version or null;
          # Context matters: `drvPath` carries an allOutputs edge that would drag
          # the built package in. Discarding the OUTPUT dependency drops that
          # edge and keeps the .drv — and its own input closure — as a real
          # dependency, so the recipe travels with the stub.
          drv = builtins.unsafeDiscardOutputDependency real.drvPath;
          bins =
            if entry ? bins then entry.bins
            else if d.bins != null then d.bins
            else [ (defaultBin real) ];
          passthru = {
            # nixpkgs routes every buildInputs/nativeBuildInputs element through
            # getDev (lib/attrsets.nix), which prefers `.dev`. Pointing it at the
            # real package keeps stubs off build inputs — a build sandbox has no
            # daemon socket and could not realise one. `passthru` is eval-only
            # and never enters the .drv, so the stub's closure is unaffected.
            dev = real;
            real = real;
          };
        });
    in
    lib.optionalAttrs synced (lib.mapAttrs' stubFor locked);
}
