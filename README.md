# nix-stubs

Lazy stubs for Nix packages — expensive tools on PATH immediately, fetched on
first use.

A stub ships the package's **build recipe** instead of the package. Typing `aws`
realises the real aws-cli and execs it; until you do, your image carries 8.4 MB
instead of 449 MB.

## Quickstart

**1. Say what to make lazy** — `stubs.nix`, at your flake root:

```nix
{ pkgs }: {
  awscli2 = pkgs.awscli2;
  code-server = pkgs.code-server;
  ripgrep = { package = pkgs.ripgrep; bins = [ "rg" ]; };
}
```

**2. Expose it as a flake output** — `gen` evaluates `.#stubs.<system>`, so the
stub set has to be an output named `stubs`, one attribute per system:

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    # ← here, a top-level output next to packages/devShells/nixosConfigurations
    stubs = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (system:
      import ./stubs.nix { pkgs = nixpkgs.legacyPackages.${system}; });
  };
}
```

Nothing here depends on nix-stubs — `gen` is self-contained, so the lock can be
generated before you add the input:

```bash
nix run github:chadac/nix-stubs#gen        # writes ./stubs.lock — commit it
```

**3. Apply the overlay** wherever you build `pkgs`. This is the step that needs
nix-stubs as an input; `./.` is your flake root, the directory holding
`stubs.nix`, `stubs.lock` and `flake.lock`:

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nix-stubs.url = "github:chadac/nix-stubs";      # ← 1. the input

  outputs = { self, nixpkgs, nix-stubs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ (nix-stubs.lib.mkOverlay ./.) ];    # ← 2. the overlay
      };
    in
    {
      # stubs = … as in step 2, from nixpkgs.legacyPackages — NOT this `pkgs`.
      # Declaring a stub set against already-stubbed packages locks the stubs'
      # own drvs instead of the real ones.

      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.awscli2 ];                     # `aws` on PATH, lazily
      };
    };
}
```

That is the whole setup. Every `pkgs.awscli2` from that `pkgs` is now a stub —
in a devShell, a package, an image builder — and the overlay is system-agnostic,
so the same call works for whatever system you instantiate.

In a NixOS or home-manager config, where the module system builds `pkgs` for
you, apply it as a module setting instead of an `import`:

```nix
{ nixpkgs.overlays = [ (nix-stubs.lib.mkOverlay ./.) ]; }
```

### Stubbing a package from another flake input

`stubs.nix` is called with the arguments it *declares*, so add `inputs` to its
signature and pass it through:

```nix
# stubs.nix
{ pkgs, inputs }: {
  uv = { package = inputs.uv-nix.packages.${pkgs.system}.uv; bins = [ "uv" "uvx" ]; };
}
```

Both call sites have to pass it — `gen` evaluates the step-2 output, the overlay
evaluates its own copy, and passing `inputs` to only one of them half-works:

```nix
# flake.nix
stubs = nixpkgs.lib.genAttrs systems (system: import ./stubs.nix {
  pkgs = nixpkgs.legacyPackages.${system};
  inputs = self.inputs;                                        # ← step 2
});

nixpkgs.overlays = [
  (nix-stubs.lib.mkOverlay { root = ./.; inputs = self.inputs; })   # ← step 3
];
```

### Overriding the defaults

Any field given explicitly wins over what `root` would have supplied, and once
all three are explicit `root` is unnecessary:

```nix
overlays = [
  (nix-stubs.lib.mkOverlay {
    stubs = pkgs: import ./nix/stubs.nix { inherit pkgs; };
    lock = ./nix/stubs.lock;
    flakeLock = ./flake.lock;
  })
];
```

## Why the recipe

A `.drv` is a complete, self-contained build recipe — builder, args, env,
sources and input derivations, recursively. Given one, `nix-store --realise`
needs **no evaluator and no nixpkgs**: it substitutes the output if a cache has
it, and builds from source if not.

| artifact | paths | on disk |
|---|---:|---:|
| `awscli2` output closure | 40 | 449 MB |
| `awscli2` recipe (`.drv` closure) | 1,508 | 8.4 MB |
| …compressed, as it ships in a layer | — | 550 KB |

Binary caches do **not** serve `.drv` paths — `cache.nixos.org` 404s them, and
only outputs get a narinfo. So the recipe has to travel with the stub; it cannot
be fetched on demand. That is the one thing this project gets right that a naive
shim does not.

It travels **packed into a single output**, not as the `.drv` files themselves.
Shipping the `.drv` graph puts unrealised build-time outputs in the stub's
closure, and every image builder walks that closure with
`exportReferencesGraph`, which requires each path to be locally valid:

```
error: path '/nix/store/…-autoreconf-hook' is not valid
```

So `nix-stubs recipe` serialises the graph into one reference-free blob, which
substitutes like any other output and enumerates as one ordinary path. The stub
names its `.drv` as plain text and imports the blob on first use.

Cost is per-**ecosystem**, not per-tool. ~764 of those paths are the stdenv
bootstrap chain shared by every derivation (`hello`, the most trivial package
that exists, carries 767). Adding tools to a store that already has one:

| cumulative | paths | on disk | marginal |
|---|---:|---:|---:|
| `awscli2` | 1,508 | 8,528 K | +8,528 K |
| + `uv` | 1,513 | 8,556 K | +28 K |
| + `ttyd` | 1,522 | 8,608 K | +52 K |
| + `tree` | 1,524 | 8,620 K | +12 K |
| + `code-server` | 2,847 | 15,500 K | +6,880 K |

Your first Python tool is expensive; your fifth is free. `code-server` is the
shape of the exception — node/npm is a toolchain graph nothing else touches. A
first Go or Haskell tool would cost the same way. There is no per-tool budget to
manage.

**Stubs are for expensive, PATH-facing tools.** A stub of something small isn't a
win — the stub itself carries bash and the dispatcher. Libraries can't be stubbed
at all: a dependent resolves the real store path at link time and nothing ever
`exec`s them, so there's no first-use hook to hang a stub on.

## `stubs.nix`

An entry is a package, or an attrset:

| field | default | meaning |
|---|---|---|
| `package` | — | the derivation to stub |
| `bins` | `meta.mainProgram` | commands to put on PATH |
| `output` | the package's `outputName` | which output to exec from |
| `attr` | the entry name | nixpkgs attribute to replace |

It must be a flake output for `gen` to read it (quickstart step 2); `--attr`
selects a different one.

## `stubs.lock`

```bash
nix run github:chadac/nix-stubs#gen        # writes ./stubs.lock
```

The lock records each package's `.drv`, output name and bins. It is a
**build-time artifact** — nothing reads it at runtime.

It records what evaluation is expected to produce; it does not replace
evaluation. A `.drv` path in a JSON file is inert — to be usable it has to be a
*dependency*, and the only ways to make one are eval-time context
(`builtins.appendContext` and `builtins.storePath` both call `ensurePath`, so
they need the `.drv` already in the evaluating machine's store, and no cache
serves `.drv` paths) or shipping the recipe out of band. So the overlay
evaluates `stubs.nix` for the drv, and the lock's job is to pin the inputs, carry
`--discover-bins` results, and let `nix-stubs check` catch drift in CI.

| flag | default | |
|---|---|---|
| `--flake` | `.` | flake holding the stub set |
| `--attr` | `stubs` | flake output to read |
| `--system` | current | repeatable; other systems in the lock are preserved |
| `--input` | those already locked, else `nixpkgs` | flake inputs to pin |
| `--discover-bins` | off | build each package and enumerate `$out/bin` instead of trusting `stubs.nix`. Off by default so a relock never builds anything. |

### It is synced to `flake.lock`

`stubs.lock` records the `locked` node of every input it was generated from. If
`flake.lock` moves and the lock isn't regenerated, **the overlay throws** — a
stale stub can never ship silently:

```
nix-stubs: stubs.lock is out of sync with flake.lock

  input 'nixpkgs'
    flake.lock  github:NixOS/nixpkgs @ 6a3f0e1b2c4d
    stubs.lock  github:NixOS/nixpkgs @ 1c2d9a8b7e6f
```

In CI, the same comparison — two JSON files, no evaluation, instant:

```bash
nix run github:chadac/nix-stubs#check -- --fast   # inputs only
nix run github:chadac/nix-stubs#check             # also re-evaluates stubs.nix
```

## Build inputs still get the real package

Swapping `pkgs.awscli2` for a stub would otherwise break any derivation using it
as a build input — a build sandbox has no daemon socket and can't realise
anything. nixpkgs routes every `buildInputs` element through `getDev`, so a stub
points that at the real package:

```nix
buildInputs = [ pkgs.awscli2 ];                 # the real package
environment.systemPackages = [ pkgs.awscli2 ];  # the stub
```

`passthru.real` is the explicit escape hatch. `passthru` is evaluation-level only
— it never enters the `.drv` — so the stub's closure is unaffected, and laziness
means the real package is never evaluated unless something reaches for it.

A stub invoked inside a build sandbox anyway fails with a message naming
`.real`, rather than an opaque `nix-store` error.

## Cache misses

First use substitutes (`--max-jobs 0`). If no configured cache has the output,
nix-stubs says so before falling back to a source build, so a stub never appears
to hang:

```
nix-stubs: awscli2 is not in any binary cache — building it from source.
nix-stubs: this can take a while. Set NIX_STUBS_NO_BUILD=1 to fail instead.
```

Set `NIX_STUBS_NO_BUILD=1` where a source build would be worse than a clean
failure (a small CI runner, a resource-capped container).

## Standalone usage

```bash
# --output selects a multi-output package's output BY NAME (awscli2 has out + dist)
# --recipe is the packed build graph, imported if the .drv is not in the store
nix-stubs exec --drv-path /nix/store/xxx.drv --recipe /nix/store/yyy-recipe-ripgrep \
  --output out --bin rg ripgrep -- --version

# pack a .drv's build graph (what nix/recipe.nix builds); --list prints it instead
nix-stubs recipe --out ./recipe.blob /nix/store/xxx.drv

nix-stubs gen --flake . --attr stubs
nix-stubs check --fast
```

`nix-stubs.lib.mkOverlay` and `.assertSync` are system-agnostic;
`nix-stubs.lib.${system}.mkStub` builds a single stub by hand.

## Tests

```bash
nix build .#checks.x86_64-linux.lock -L          # eval-level: sync, passthru, context
nix build .#checks.x86_64-linux.closure -L       # a stub's closure has no .drv in it
nix build .#checks.x86_64-linux.integration -L   # NixOS VM: exec, closure, realisation
nix build .#checks.x86_64-linux.overlay -L       # NixOS VM: the overlay, from this repo's lock
nix run .#check -- --fast                        # this repo's own lock
```
