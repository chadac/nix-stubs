{ lib }:

let
  readJSON = f: builtins.fromJSON (builtins.readFile f);

  # Accepts a path (the normal case — ./stubs.lock), or an already-parsed
  # attrset. A path keeps this out of import-from-derivation territory.
  asAttrs = v: if builtins.isAttrs v && !(lib.isDerivation v) then v else readJSON v;

  # Resolve a root-level input of a flake.lock to its `locked` node.
  # An input is a node name, or a `follows` path from root.
  lockedInput = flakeLock: name:
    let
      nodes = flakeLock.nodes;
      inputOf = node: input: nodes.${node}.inputs.${input} or (throw ''
        nix-stubs: input '${name}' follows '${input}' of '${node}', which
        flake.lock does not have. Run `nix flake lock`.
      '');
      resolve = ref:
        if builtins.isString ref then ref
        else lib.foldl' (node: input: resolve (inputOf node input)) flakeLock.root ref;
      root = nodes.${flakeLock.root};
      ref = root.inputs.${name} or (throw ''
        nix-stubs: input '${name}' is recorded in stubs.lock but is not an input
        of this flake. Either add it to flake.nix or regenerate stubs.lock.
      '');
    in
    nodes.${resolve ref}.locked;

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

  # A stubs.nix is a function of an attrset. Call it with only the arguments it
  # declares, so `{ pkgs }:` and `{ pkgs, inputs }:` both work under the path
  # shorthand without the caller hand-writing a `stubs` lambda.
  callStubs = file: extra: pkgs:
    let
      f = import file;
      avail = { inherit pkgs; } // extra;
    in
    if builtins.isFunction f
    then f (builtins.intersectAttrs (builtins.functionArgs f) avail)
    else throw ''
      nix-stubs: ${toString file} must be a function of an attrset, e.g.
      `{ pkgs }: { hello = pkgs.hello; }`.
    '';

  # `mkOverlay ./.` == `mkOverlay { root = ./.; }`. A flake root already fixes
  # where all three files live, so requiring them spelled out was boilerplate
  # with exactly one correct answer. Anything passed explicitly still wins, and
  # `root` is only forced by the defaults that need it — so the explicit form
  # never has to supply it.
  overlayArgs = arg:
    let
      args = if builtins.isAttrs arg then arg else { root = arg; };
      root = args.root or null;
      inRoot = attr: file:
        if root != null then root + file else throw ''
          nix-stubs: mkOverlay needs '${attr}'. Pass it, or pass `root` — your
          flake directory, usually ./. — and it defaults to ${file} in there.
        '';
      # `inputs` is the one extra argument a stubs.nix conventionally takes (to
      # reach a package from another flake input). Anything beyond that wants
      # the explicit `stubs` lambda rather than more magic here.
      extra = lib.optionalAttrs (args ? inputs) { inherit (args) inputs; };
    in
    {
      stubs = args.stubs or (callStubs (inRoot "stubs" "/stubs.nix") extra);
      lock = args.lock or (inRoot "lock" "/stubs.lock");
      flakeLock = args.flakeLock or (inRoot "flakeLock" "/flake.lock");
      lockPath = args.lockPath or "stubs.lock";
      nix-stubs = args.nix-stubs or null;
    };

  normalize = name: decl:
    if lib.isDerivation decl
    then { package = decl; attr = name; bins = null; output = null; }
    else {
      inherit (decl) package;
      attr = decl.attr or name;
      bins = decl.bins or null;
      output = decl.output or null;
    };

  # mkOverlay's sets by name; a lone set is `default`.
  setsOf = arg:
    if builtins.isAttrs arg && arg ? sets
    then lib.mapAttrs (_: overlayArgs) arg.sets
    else { default = overlayArgs arg; };

  # Error label: names the set once there are several.
  labelFor = multi: name: lockPath:
    if multi then "set '${name}' (${lockPath})" else lockPath;

  # Attributes that more than one set stubs.
  duplicateErrors = sets:
    let
      owners = lib.foldlAttrs
        (acc: set: s:
          lib.foldlAttrs
            (acc': name: entry:
              let attr = entry.attr or name;
              in acc' // { ${attr} = (acc'.${attr} or [ ]) ++ [ set ]; })
            acc
            s.locked)
        { }
        sets;
    in
    lib.mapAttrsToList (attr: from: "'${attr}' is stubbed by ${lib.concatMapStringsSep " and " (s: "'${s}'") from}")
      (lib.filterAttrs (_: from: builtins.length from > 1) owners);

  # Inputs two sets pin differently; every stub builds from one nixpkgs.
  inputErrors = sets:
    let
      pins = lib.foldlAttrs
        (acc: set: s:
          lib.foldlAttrs
            (acc': input: pinned: acc' // { ${input} = (acc'.${input} or [ ]) ++ [ { inherit set pinned; } ]; })
            acc
            s.lock.inputs)
        { }
        sets;
      disagree = lib.filterAttrs (_: ps: lib.any (p: p.pinned != (builtins.head ps).pinned) ps) pins;
    in
    lib.mapAttrsToList
      (input: ps: ''
        input '${input}'
            ${lib.concatMapStringsSep "\n    " (p: "${p.set}  ${fmtInput p.pinned}") ps}'')
      disagree;

in
{
  inherit lockedInput syncErrors assertSync defaultBin;

  read = asAttrs;

  # Turn stub sets into a nixpkgs overlay, replacing each declared attribute
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
  # Takes your flake root — `mkOverlay ./.` — or an attrset:
  #
  #   root       ./. — defaults stubs to ./stubs.nix, lock to ./stubs.lock and
  #              flakeLock to ./flake.lock inside it
  #   stubs      pkgs -> attrset of declarations (usually `import ./stubs.nix`)
  #   lock       ./stubs.lock — supplies discovered bins/output, and the pins
  #   flakeLock  ./flake.lock — the lock must still agree with it
  #   inputs     passed to ./stubs.nix if it declares that argument
  #
  # Or several sets composed into one overlay, each in either form above:
  #
  #   mkOverlay { sets = { base = ./.; aws = { root = ./aws; flakeLock = ./flake.lock; }; }; }
  #
  # Sets share one recipe blob and never see each other's stubs.
  mkOverlay = arg:
    let
      sets = setsOf arg;
      multi = builtins.isAttrs arg && arg ? sets;
      nix-stubs = if builtins.isAttrs arg then arg.nix-stubs or null else null;
    in
    final: prev:
    let
      system = prev.stdenv.hostPlatform.system;

      loaded = lib.mapAttrs
        (setName: s:
          let
            label = labelFor multi setName s.lockPath;
            lock = asAttrs s.lock;
          in
          {
            inherit label lock;
            synced = assertSync { inherit lock; flakeLock = asAttrs s.flakeLock; lockPath = label; };
            locked = lock.packages.${system} or (throw "nix-stubs: ${label} has no packages for system ${system}");
            # `prev`, not `final`: a stub set that reached for the stubbed
            # attributes would be its own input.
            decls = s.stubs prev;
          })
        sets;

      dupErrs = duplicateErrors loaded;
      noDuplicates = dupErrs == [ ] || throw ''

        nix-stubs: two stub sets replace the same attribute

          ${lib.concatStringsSep "\n  " dupErrs}

        Keep each attribute in one set.
      '';

      inputErrs = inputErrors loaded;
      inputsAgree = inputErrs == [ ] || throw ''

        nix-stubs: stub sets were locked against different inputs

          ${lib.concatStringsSep "\n\n  " inputErrs}

        Relock them against the same flake.lock pins.
      '';

      ok = lib.all (s: s.synced) (lib.attrValues loaded) && noDuplicates && inputsAgree;

      declFor = s: name:
        normalize name (s.decls.${name} or (throw ''
          nix-stubs: ${s.label} has an entry for '${name}', but its stubs.nix
          does not declare it. Regenerate the lock: nix run github:chadac/nix-stubs#gen
        ''));

      pkg = if nix-stubs != null then nix-stubs else prev.callPackage ./package.nix { };
      mkStub = import ./shim.nix { pkgs = prev; nix-stubs = pkg; };

      # The recipe for EVERY set, packed once. Per-stub (or per-set) blobs would
      # each carry the stdenv bootstrap chain the others already have — a blob
      # is one opaque file, so the store cannot share it the way it shares .drv
      # paths.
      recipeDrv = s: name:
        builtins.unsafeDiscardOutputDependency (declFor s name).package.drvPath;

      sharedRecipe = import ./recipe.nix { pkgs = prev; nix-stubs = pkg; } {
        name = "stub-set";
        # Sorted and unique, so splitting sets never changes the blob.
        drvs = lib.unique (lib.sort builtins.lessThan
          (lib.concatMap (s: map (recipeDrv s) (builtins.attrNames s.locked)) (lib.attrValues loaded)));
      };

      # Iterating the LOCK rather than the declarations is what keeps this
      # terminating. The overlay's attribute names have to be known before the
      # package set is complete, and the lock supplies them as plain strings.
      # Deriving a name from a declaration instead means forcing `prev.<attr>`
      # mid-construction, which is an infinite recursion.
      stubFor = s: name: entry:
        let
          d = declFor s name;
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
    lib.optionalAttrs ok
      (lib.foldl' (acc: s: acc // lib.mapAttrs' (stubFor s) s.locked) { } (lib.attrValues loaded));
}
