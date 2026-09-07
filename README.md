# nix-stubs

Lazy stubs for Nix packages — expensive tools on PATH immediately, fetched on
first use.

A stub ships the package's **build recipe** instead of the package. Typing `aws`
realises the real aws-cli and execs it; until you do, your image carries 8.4 MB
instead of 449 MB.

```nix
# stubs.nix — what to make lazy
{ pkgs, inputs }: {
  awscli2 = pkgs.awscli2;
  code-server = pkgs.code-server;
  uv = { package = inputs.uv-nix.packages.${pkgs.system}.uv; bins = [ "uv" "uvx" ]; };
}
```

```nix
# apply the generated lock as an overlay
overlays = [ (nix-stubs.lib.mkOverlay { lock = ./stubs.lock; flakeLock = ./flake.lock; }) ];
```

`pkgs.awscli2` is now a stub. `environment.systemPackages = [ pkgs.awscli2 ]`
puts `aws` on PATH without putting aws-cli in your image.

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

Expose it from your flake so `gen` can find it:

```nix
# flake.nix
stubs = forAllSystems (system: import ./stubs.nix {
  pkgs = nixpkgs.legacyPackages.${system};
  inputs = self.inputs;
});
```

## `stubs.lock`

```bash
nix run github:chadac/nix-stubs#gen        # writes ./stubs.lock
```

The lock records each package's `.drv`, output name and bins. It is a
**build-time artifact** — nothing reads it at runtime. Its job is to let the
overlay construct stubs *without evaluating the packages they stand for*, so
bumping nixpkgs doesn't re-evaluate every stubbed package.

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
nix-stubs exec --drv-path /nix/store/xxx.drv --output out --bin rg ripgrep -- --version

nix-stubs gen --flake . --attr stubs
nix-stubs check --fast
```

`nix-stubs.lib.mkOverlay`, `.drvRef` and `.assertSync` are system-agnostic;
`nix-stubs.lib.${system}.mkStub` builds a single stub by hand.

## Tests

```bash
nix build .#checks.x86_64-linux.lock -L          # eval-level: sync, passthru, context
nix build .#checks.x86_64-linux.integration -L   # NixOS VM: exec, closure, realisation
nix run .#check -- --fast                        # this repo's own lock
```
