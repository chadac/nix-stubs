//! `gen` / `check` — produce stubs.lock from stubs.nix, and verify it in CI.

use crate::lock::{self, Entry, Lock};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::process::Command;

/// Applied to the flake's stub set to extract exactly what the lock records.
///
/// This is deliberately self-contained (pure builtins, no nix-stubs import) so
/// `gen` works against any flake without that flake depending on nix-stubs at
/// eval time. Contexts are discarded because the result is JSON text; the
/// overlay re-attaches the dependency edge when it reads the lock back.
const EXTRACT: &str = r#"
stubs:
  builtins.mapAttrs (name: v:
    let
      pkg = if v ? package then v.package else v;
      inferred = pkg.meta.mainProgram or (builtins.parseDrvName pkg.name).name;
    in {
      attr   = v.attr or name;
      drv    = builtins.unsafeDiscardStringContext pkg.drvPath;
      output = v.output or (pkg.outputName or "out");
      bins   = v.bins or [ inferred ];
      name   = builtins.unsafeDiscardStringContext pkg.name;
    }) stubs
"#;

#[derive(Deserialize)]
struct Raw {
    attr: String,
    drv: String,
    output: String,
    bins: Vec<String>,
    name: String,
}

pub struct GenOpts {
    pub flake: String,
    pub attr: String,
    pub systems: Vec<String>,
    pub lock_path: String,
    pub flake_lock_path: String,
    pub inputs: Vec<String>,
    pub discover_bins: bool,
}

fn current_system() -> Result<String, String> {
    nix(&[
        "eval",
        "--impure",
        "--raw",
        "--expr",
        "builtins.currentSystem",
    ])
    .map_err(|e| format!("could not determine the current system (pass --system): {e}"))
}

fn nix(args: &[&str]) -> Result<String, String> {
    let out = Command::new("nix")
        .args(["--extra-experimental-features", "nix-command flakes"])
        .args(args)
        .output()
        .map_err(|e| format!("failed to run nix: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Enumerate `$out/bin` for real. Opt-in: it BUILDS the package, and the point
/// of a relock is to not build anything.
fn discover_bins(drv: &str, output: &str) -> Result<Vec<String>, String> {
    let out_path = nix(&[
        "build",
        "--no-link",
        "--print-out-paths",
        &format!("{drv}^{output}"),
    ])?;
    let bin_dir = format!("{}/bin", out_path.lines().next().unwrap_or_default());
    let mut bins: Vec<String> = std::fs::read_dir(&bin_dir)
        .map_err(|e| format!("{bin_dir}: {e}"))?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    bins.sort();
    if bins.is_empty() {
        return Err(format!("{bin_dir}: no binaries found"));
    }
    Ok(bins)
}

pub fn build_lock(opts: &GenOpts) -> Result<Lock, String> {
    let flake_lock = lock::read_flake_lock(&opts.flake_lock_path)?;

    let mut out = Lock::empty();
    for name in &opts.inputs {
        out.inputs
            .insert(name.clone(), lock::locked_input(&flake_lock, name)?);
    }

    let systems = if opts.systems.is_empty() {
        vec![current_system()?]
    } else {
        opts.systems.clone()
    };

    for system in &systems {
        let target = format!("{}#{}.{}", opts.flake, opts.attr, system);
        eprintln!("nix-stubs: evaluating {target}");
        let json = nix(&["eval", "--json", &target, "--apply", EXTRACT]).map_err(|e| {
            format!(
                "failed to evaluate {target}\n{e}\n\nDoes the flake expose `{}.{system}`?",
                opts.attr
            )
        })?;
        let raw: BTreeMap<String, Raw> =
            serde_json::from_str(&json).map_err(|e| format!("unexpected eval output: {e}"))?;

        let mut entries = BTreeMap::new();
        for (stub, r) in raw {
            let bins = if opts.discover_bins {
                discover_bins(&r.drv, &r.output)
                    .map_err(|e| format!("--discover-bins failed for '{stub}': {e}"))?
            } else {
                r.bins
            };
            entries.insert(
                stub,
                Entry {
                    attr: r.attr,
                    drv: r.drv,
                    output: r.output,
                    bins,
                    name: r.name,
                },
            );
        }
        out.packages.insert(system.clone(), entries);
    }
    Ok(out)
}

pub fn cmd_gen(opts: GenOpts) {
    // Systems the existing lock covers but this run didn't regenerate are
    // carried over, so locking on one machine doesn't drop another's entries.
    let existing = Lock::read(&opts.lock_path).ok();

    let mut new = match build_lock(&opts) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("nix-stubs: {e}");
            std::process::exit(1);
        }
    };

    if let Some(old) = &existing {
        for (system, entries) in &old.packages {
            new.packages
                .entry(system.clone())
                .or_insert_with(|| entries.clone());
        }
    }

    if existing.as_ref() == Some(&new) {
        println!("nix-stubs: {} is already up to date", opts.lock_path);
        return;
    }

    if let Err(e) = new.write(&opts.lock_path) {
        eprintln!("nix-stubs: {e}");
        std::process::exit(1);
    }
    let n: usize = new.packages.values().map(|p| p.len()).sum();
    println!(
        "nix-stubs: wrote {} ({n} stubs across {} system(s))",
        opts.lock_path,
        new.packages.len()
    );
}

pub fn cmd_check(opts: GenOpts, fast: bool) {
    let committed = match Lock::read(&opts.lock_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("nix-stubs: {e}");
            std::process::exit(1);
        }
    };

    // Stage 1 — inputs. Pure JSON comparison, no evaluation, instant. This is
    // the check that catches the common case: flake.lock moved, nobody relocked.
    let flake_lock = match lock::read_flake_lock(&opts.flake_lock_path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("nix-stubs: {e}");
            std::process::exit(1);
        }
    };
    let errs = lock::sync_errors(&committed, &flake_lock);
    if !errs.is_empty() {
        eprintln!(
            "nix-stubs: {} is out of sync with flake.lock\n",
            opts.lock_path
        );
        for e in &errs {
            eprintln!("  {e}\n");
        }
        eprintln!("Regenerate with: nix run github:chadac/nix-stubs#gen");
        std::process::exit(1);
    }

    if fast {
        println!(
            "nix-stubs: {} inputs match flake.lock ({} pinned)",
            opts.lock_path,
            committed.inputs.len()
        );
        return;
    }

    // Stage 2 — re-evaluate and compare drv paths. Catches drift the input
    // pins can't see: an overlay, a package override, a changed stubs.nix.
    let opts = GenOpts {
        systems: committed.packages.keys().cloned().collect(),
        inputs: committed.inputs.keys().cloned().collect(),
        ..opts
    };
    let fresh = match build_lock(&opts) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("nix-stubs: {e}");
            std::process::exit(1);
        }
    };

    if fresh == committed {
        let n: usize = committed.packages.values().map(|p| p.len()).sum();
        println!("nix-stubs: {} is up to date ({n} stubs)", opts.lock_path);
        return;
    }

    eprintln!("nix-stubs: {} does not match stubs.nix\n", opts.lock_path);
    for (system, entries) in &fresh.packages {
        let old = committed.packages.get(system);
        for (name, e) in entries {
            match old.and_then(|o| o.get(name)) {
                None => eprintln!("  + {system}.{name}  {}", e.name),
                Some(prev) if prev != e => {
                    eprintln!("  ~ {system}.{name}  {} -> {}", prev.name, e.name)
                }
                Some(_) => {}
            }
        }
        if let Some(old) = old {
            for name in old.keys().filter(|k| !entries.contains_key(*k)) {
                eprintln!("  - {system}.{name}");
            }
        }
    }
    eprintln!("\nRegenerate with: nix run github:chadac/nix-stubs#gen");
    std::process::exit(1);
}
