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
  # fails loudly at eval instead of silently shipping stubs built from the old
  # revision (the stub would still WORK — the recipe is self-contained — it would
  # just be a different version of the tool than the rest of the system).
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

  # Re-attach the dependency edge to a .drv path read out of stubs.lock.
  #
  # A string from a JSON file has no context, so interpolating it into the shim
  # would name a .drv that Nix never copies anywhere — and binary caches do not
  # serve .drv paths, so nothing can recover it at runtime. `path = true` is
  # opaque context: the .drv lands in the stub's inputSrcs, which drags in the
  # .drv's own store references (its input drvs and sources) — the complete
  # build recipe, and none of the build OUTPUTS.
  #
  # `builtins.storePath` produces the same context but is rejected in pure
  # evaluation mode, which is the default for flakes.
  drvRef = p: builtins.appendContext p { ${p} = { path = true; }; };

in
{
  inherit lockedInput syncErrors assertSync drvRef;

  read = asAttrs;

  # Turn stubs.lock into a nixpkgs overlay.
  #
  # For each locked package, `pkgs.<attr>` becomes a stub. No evaluation of the
  # real package happens — that is the whole point of the lock — but `prev.<attr>`
  # stays reachable through passthru, and Nix's laziness means it is never forced
  # unless something asks for it.
  mkOverlay =
    { lock
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
      entries = lock'.packages.${system} or (throw ''
        nix-stubs: ${lockPath} has no packages for system '${system}'.
        Regenerate with: nix run github:chadac/nix-stubs#gen -- --system ${system}
      '');

      pkg = if nix-stubs != null then nix-stubs else prev.callPackage ./package.nix { };
      mkStub = import ./shim.nix { pkgs = prev; nix-stubs = pkg; };

      # Keyed by the nixpkgs attribute being replaced, which is `attr` when the
      # stub is named differently from the attribute it stands in for.
      stubFor = name: entry:
        let real = prev.${entry.attr or name};
        in lib.nameValuePair (entry.attr or name) (mkStub {
          inherit name;
          drv = drvRef entry.drv;
          output = entry.output or "out";
          bins = entry.bins;
          passthru = {
            # nixpkgs routes every buildInputs/nativeBuildInputs element through
            # getDev (lib/attrsets.nix), which prefers `.dev`. Pointing it at the
            # real package keeps the stub off build inputs — a build sandbox has
            # no daemon socket and could not realise it. `passthru` is eval-only
            # and never enters the .drv, so the stub's closure is unaffected.
            dev = real;
            real = real;
          };
        });
    in
    lib.optionalAttrs synced (lib.mapAttrs' stubFor entries);
}
