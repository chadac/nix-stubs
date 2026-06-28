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

## Overlay

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
# Run a tool lazily — realizes the .drv if needed, then execs the binary
nix-stubs exec --drv-path /nix/store/xxx.drv --out-path /nix/store/yyy-tool tool-name -- --flag

# Generate shell activation hooks
eval "$(nix-stubs activate bash --manifest manifest.json --shim-dir /path/to/shims)"

# Check realized packages and output PATH updates (called by the shell hook)
nix-stubs hook-env --manifest manifest.json
```

The Nix library functions `mkLazyPackage` and `mkManifest` are available at `nix-stubs.lib.${system}` for building custom integrations.

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
