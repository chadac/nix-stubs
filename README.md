# nix-stubs

Lazy shims for Nix packages — tools available on PATH immediately,
downloaded on first use.

Nix ensures reproducibility but requires packages to be built or
downloaded before use. For rarely-used tools, this is
wasteful. nix-stubs makes tools available on PATH right away, only
downloading them on first invocation — like mise's shimming model, but
for Nix packages.

## How it works

Two-layer approach:

1. **Shim scripts** — lightweight wrappers always on PATH that call `nix-store --realise` on first use, then `exec` the real binary. Works everywhere: IDEs, cron, scripts.
2. **Shell hook** — on each prompt, checks which packages have been realized and prepends their real `bin/` dirs to PATH. This gives you tab completion, correct `which` output, and zero shim overhead for already-installed tools.

### What a stub actually carries

A stub depends on the package's **`.drv`** — the complete build recipe — and not on
its build outputs. That distinction is the whole design:

| | paths | on disk |
|---|---|---|
| `awscli2` output closure | 40 | 449 MB |
| `awscli2` recipe (`.drv` closure) | 1,508 | 8.4 MB (550 KB compressed) |

A `.drv` names its builder, args, env, sources and input derivations recursively, so
`nix-store --realise` on it needs **no evaluator and no nixpkgs** — it substitutes the
output if a cache has it, and builds from source if not. Binary caches do *not* serve
`.drv` paths, which is why the recipe has to travel with the stub rather than being
fetched on demand.

The cost is per-**ecosystem**, not per-tool: ~764 of those paths are the stdenv
bootstrap chain that every derivation shares. Once one tool is stubbed, a second from
the same ecosystem costs tens of KB.

## Quick start (Home Manager)

Add the flake input:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    nix-stubs.url = "github:chadac/nix-lazy-tools";
  };

  outputs = { nixpkgs, home-manager, nix-stubs, ... }: {
    # ... your config
  };
}
```

Import the module and configure tools:

```nix
# home.nix (or wherever your home-manager config lives)
{ pkgs, ... }: {
  imports = [ nix-stubs.homeManagerModules.default ];

  programs.nix-stubs = {
    enable = true;
    tools = {
      # Simple: just pass the package (binary name inferred from meta.mainProgram)
      uv = pkgs.uv;

      # Explicit: specify which commands to shim
      ripgrep = { package = pkgs.ripgrep; commands = [ "rg" ]; };
    };
  };
}
```

That's it. After `home-manager switch`:

- `uv` and `rg` are immediately on your PATH as shims
- First run downloads/builds the package, then execs the real binary
- Subsequent runs go through the shim (fast path: ~4ms overhead) or directly to the real binary (zero overhead, after the shell hook fires)

## Module options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable nix-stubs |
| `package` | package | `nix-stubs` from flake | The nix-stubs binary to use |
| `tools` | attrsOf (package or { package, commands }) | `{}` | Tools to create lazy shims for |
| `enableShellIntegration` | bool | `true` | Add prompt hook for PATH updates |
| `overlay` | overlay (read-only) | — | Generated nixpkgs overlay from configured tools |

## `stubs.nix` + `stubs.lock` (recommended)

For anything bigger than a personal config — an image build, a system flake — declare
stubs in a **`stubs.nix`** and commit a generated **`stubs.lock`**. The lock lets the
overlay build stubs *without evaluating the packages they stand for*, so bumping
nixpkgs doesn't re-evaluate (or rebuild) every stubbed tool.

**1. Declare the stub set:**

```nix
# stubs.nix
{ pkgs, inputs }:
{
  awscli2 = pkgs.awscli2;
  code-server = pkgs.code-server;
  ripgrep = { package = pkgs.ripgrep; bins = [ "rg" ]; };
  uv = { package = inputs.uv-nix.packages.${pkgs.system}.uv; bins = [ "uv" "uvx" ]; };
}
```

Fields: `package`, `bins` (default `meta.mainProgram`), `output` (default the
package's own `outputName`), `attr` (the nixpkgs attribute to replace, if it differs
from the entry name).

**2. Expose it from your flake so `gen` can find it**, then generate the lock:

```nix
# flake.nix
stubs = forAllSystems (system: import ./stubs.nix {
  pkgs = nixpkgs.legacyPackages.${system};
  inputs = self.inputs;
});
```

```bash
nix run github:chadac/nix-stubs#gen        # writes ./stubs.lock
```

**3. Apply the overlay:**

```nix
pkgs = import nixpkgs {
  inherit system;
  overlays = [
    (nix-stubs.lib.mkOverlay { lock = ./stubs.lock; flakeLock = ./flake.lock; })
  ];
};
```

`pkgs.awscli2` is now a stub; `environment.systemPackages = [ pkgs.awscli2 ]` ships
8.4 MB of recipe instead of 449 MB of aws-cli.

### The lock is synced to `flake.lock`

`stubs.lock` records the `locked` node of each flake input it was generated from.
If `flake.lock` moves and the lock isn't regenerated, **the overlay throws** — a
stale stub can never ship silently:

```
nix-stubs: stubs.lock is out of sync with flake.lock

  input 'nixpkgs'
    flake.lock  github:NixOS/nixpkgs @ 6a3f0e1b2c4d
    stubs.lock  github:NixOS/nixpkgs @ 1c2d9a8b7e6f
```

Wire the same check into CI, where it's a two-file JSON comparison that runs
instantly and needs no evaluation:

```bash
nix run github:chadac/nix-stubs#check -- --fast   # inputs only
nix run github:chadac/nix-stubs#check             # also re-evaluates stubs.nix
```

### `gen` options

| Flag | Default | Description |
|------|---------|-------------|
| `--flake` | `.` | Flake holding the stub set |
| `--attr` | `stubs` | Flake output attribute to read |
| `--system` | current | Repeatable; other systems in the lock are preserved |
| `--input` | those already locked, else `nixpkgs` | Flake inputs to pin |
| `--discover-bins` | off | Build each package and enumerate `$out/bin` instead of trusting `stubs.nix`. Off by default so a relock never builds anything. |

### Build inputs still get the real package

An overlay that swaps `pkgs.awscli2` for a stub would otherwise break any derivation
using it as a build input — a build sandbox has no daemon socket and can't realise
anything. nixpkgs routes every `buildInputs` element through `getDev`, so the stub
sets `passthru.dev` (and `passthru.real`) to the real package:

```nix
buildInputs = [ pkgs.awscli2 ];               # the real package
environment.systemPackages = [ pkgs.awscli2 ]; # the stub
```

`passthru` is evaluation-level only — it never enters the `.drv`, so the stub's
closure is unaffected, and laziness means the real package is never evaluated unless
something reaches for it. A stub invoked inside a build sandbox anyway fails with a
message naming `.real` rather than an opaque `nix-store` error.

> **Scope:** stubs are for PATH-facing, expensive-to-fetch tools (`uv`, `awscli2`,
> `code-server`). Libraries can't be stubbed — a dependent resolves the real store
> path at link time and nothing ever `exec`s them, so there's no first-use hook.

## Overlay (from module config)

The module exposes a read-only `overlay` option generated from your
`tools` config. Apply it to nixpkgs so that any reference to the
package (e.g. `pkgs.ripgrep`) gets the lazy stub automatically:

```nix
{ config, pkgs, ... }: {
  programs.nix-stubs = {
    enable = true;
    tools = {
      ripgrep = { package = pkgs.ripgrep; commands = [ "rg" ]; };
      uv = pkgs.uv;
    };
  };

  # Apply the generated overlay — pkgs.ripgrep and pkgs.uv are now lazy stubs
  nixpkgs.overlays = [ config.programs.nix-stubs.overlay ];
}
```

Tool names must match nixpkgs attribute names for the overlay to work.

### Standalone `mkOverlay`

You can also use `mkOverlay` directly without the module:

```nix
# flake.nix
{
  outputs = { nixpkgs, nix-stubs, ... }:
    let
      lazyOverlay = nix-stubs.lib.x86_64-linux.mkOverlay {
        ripgrep = { commands = [ "rg" ]; };
        uv = {};  # infer commands from meta.mainProgram
      };
    in {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        modules = [{
          nixpkgs.overlays = [ lazyOverlay ];
          # Now pkgs.ripgrep and pkgs.uv are lazy stubs everywhere
          environment.systemPackages = [ pkgs.ripgrep pkgs.uv ];
        }];
      };
    };
}
```

> **Note:** The overlay is intended for end-user CLI tools. Don't overlay
> packages used as build inputs by other derivations — builds need the
> real package, not a shim.

## Standalone usage

You can also use `nix-stubs` directly without the module:

```bash
# Run a tool lazily — realizes the .drv if needed, then execs the binary.
# --output selects a multi-output package's output BY NAME (awscli2 has out + dist).
nix-stubs exec --drv-path /nix/store/xxx.drv --output out --bin rg ripgrep -- --version

# Generate / verify the lock
nix-stubs gen --flake . --attr stubs
nix-stubs check --fast

# Generate shell activation hooks
eval "$(nix-stubs activate bash --manifest manifest.json --shim-dir /path/to/shims)"

# Check realized packages and output PATH updates (called by the shell hook)
nix-stubs hook-env --manifest manifest.json
```

The Nix library functions `mkLazyPackage` and `mkManifest` are available at `nix-stubs.lib.${system}` for building custom integrations.

## Cache misses

First use tries to **substitute** the output (`--max-jobs 0`). If no configured cache
has it, nix-stubs says so before falling back to a source build, so a stub never
appears to hang:

```
nix-stubs: awscli2 is not in any binary cache — building it from source.
nix-stubs: this can take a while. Set NIX_STUBS_NO_BUILD=1 to fail instead.
```

Set `NIX_STUBS_NO_BUILD=1` where a source build would be worse than a clean failure
(a small CI runner, a resource-capped container).

## Shell support

Shell integration is supported for **bash**, **zsh**, and **fish**. When enabled, a prompt hook runs `nix-stubs hook-env` on each prompt to prepend realized package dirs to PATH. This means:

- Tab completions work after first use
- `which tool` returns the real binary path
- No shim overhead for realized packages

## Performance

Measured in NixOS VM tests (single-core QEMU):

| Path | Latency |
|------|---------|
| Direct binary | ~4ms |
| Shim (fast path, already realized) | ~8ms |
| `hook-env` per prompt | ~2ms |

On real hardware, expect these to be faster.

## Running tests

```bash
nix build .#checks.x86_64-linux.integration -L
```

<!-- TODO: Home Manager flake module setup with detailed examples -->
<!-- TODO: Standalone / non-flake setup instructions -->
