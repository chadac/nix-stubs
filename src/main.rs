mod gen;
mod lock;

use clap::{Parser, Subcommand};
use gen::GenOpts;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

#[derive(Parser)]
#[command(name = "nix-stubs", about = "Lazy shims for Nix packages")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Execute a lazy-loaded tool, realizing it if needed
    Exec {
        /// Path to the .drv file
        #[arg(long)]
        drv_path: String,

        /// Output name to exec from (e.g. "out", "bin")
        #[arg(long, default_value = "out")]
        output: String,

        /// Output store path (optional; resolved from drv-path if omitted)
        #[arg(long)]
        out_path: Option<String>,

        /// Binary name override (defaults to tool name)
        #[arg(long)]
        bin: Option<String>,

        /// Tool name
        tool: String,

        /// Arguments to pass to the tool
        #[arg(last = true)]
        args: Vec<String>,
    },

    /// Generate stubs.lock from a flake's stub set
    Gen {
        /// Flake containing the stub set
        #[arg(long, default_value = ".")]
        flake: String,

        /// Flake output attribute holding the stub set
        #[arg(long, default_value = "stubs")]
        attr: String,

        /// Systems to lock (repeatable; defaults to the current system)
        #[arg(long = "system")]
        systems: Vec<String>,

        /// Path to stubs.lock
        #[arg(long, default_value = "stubs.lock")]
        lock: String,

        /// Path to the flake.lock stubs.lock is synced to
        #[arg(long = "flake-lock", default_value = "flake.lock")]
        flake_lock: String,

        /// Flake inputs to pin (repeatable; defaults to those already locked, else nixpkgs)
        #[arg(long = "input")]
        inputs: Vec<String>,

        /// Build each package and enumerate $out/bin instead of trusting stubs.nix
        #[arg(long)]
        discover_bins: bool,
    },

    /// Verify stubs.lock is in sync with flake.lock and stubs.nix (CI check)
    Check {
        #[arg(long, default_value = ".")]
        flake: String,

        #[arg(long, default_value = "stubs")]
        attr: String,

        #[arg(long, default_value = "stubs.lock")]
        lock: String,

        #[arg(long = "flake-lock", default_value = "flake.lock")]
        flake_lock: String,

        /// Only compare inputs against flake.lock; skip re-evaluating stubs.nix
        #[arg(long)]
        fast: bool,
    },

    /// Output shell activation hooks
    Activate {
        /// Shell type
        shell: Shell,

        /// Path to manifest JSON
        #[arg(long)]
        manifest: String,

        /// Path to shim directory
        #[arg(long)]
        shim_dir: String,
    },

    /// Check realized status and output PATH updates (called by shell hook)
    HookEnv {
        /// Path to manifest JSON
        #[arg(long)]
        manifest: String,
    },
}

#[derive(Clone, clap::ValueEnum)]
enum Shell {
    Bash,
    Zsh,
    Fish,
}

#[derive(Deserialize)]
struct Manifest {
    tools: HashMap<String, ToolEntry>,
}

#[derive(Deserialize)]
struct ToolEntry {
    #[allow(dead_code)]
    drv_path: String,
    out_path: String,
    #[allow(dead_code)]
    commands: Vec<String>,
}

/// Resolve an output BY NAME without realising anything.
///
/// `--query --binding <name>` reads the output path out of the .drv's own
/// environment. The obvious `--query --outputs` returns every output in
/// unspecified order, so taking the first is a coin flip on any multi-output
/// package (awscli2 has `out` and `dist`).
fn resolve_out_path(drv_path: &str, output: &str) -> Result<String, String> {
    let result = Command::new("nix-store")
        .args(["--query", "--binding", output, drv_path])
        .output()
        .map_err(|e| format!("failed to run nix-store: {e}"))?;

    if !result.status.success() {
        let stderr = String::from_utf8_lossy(&result.stderr);
        if stderr.contains("no substituter") || stderr.contains("is not valid") {
            return Err(format!(
                "the recipe for this tool is missing from the store:\n  {drv_path}\n\
                 Binary caches do not serve .drv paths, so it cannot be fetched. The stub was \
                 built without its recipe as a dependency — rebuild it with a nix-stubs that \
                 keeps the .drv in the stub's closure."
            ));
        }
        return Err(format!(
            "nix-store --query --binding {output} failed: {}",
            stderr.trim()
        ));
    }

    let out = String::from_utf8_lossy(&result.stdout).trim().to_string();
    if out.is_empty() {
        return Err(format!("{drv_path} has no output named '{output}'"));
    }
    Ok(out)
}

fn realize(drv_path: &str, tool: &str) -> Result<(), String> {
    if std::env::var_os("NIX_BUILD_TOP").is_some() {
        return Err(format!(
            "'{tool}' is a lazy stub and cannot be realised inside a build sandbox.\n\
             Use the real package for build inputs: pkgs.{tool}.real (buildInputs already \
             get it via getDev)."
        ));
    }

    // Substitute-first. `--max-jobs 0` refuses to build anything locally, so a
    // cache hit is silent and a cache MISS is where the user finds out they are
    // about to compile — rather than a stub appearing to hang for 40 minutes.
    eprintln!("nix-stubs: fetching {tool}...");
    let substituted = Command::new("nix-store")
        .args(["--realise", "--max-jobs", "0", drv_path])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| format!("failed to run nix-store: {e}"))?;

    if substituted.success() {
        return Ok(());
    }

    if std::env::var_os("NIX_STUBS_NO_BUILD").is_some() {
        return Err(format!(
            "{tool} is not in any configured binary cache, and NIX_STUBS_NO_BUILD is set."
        ));
    }

    eprintln!("nix-stubs: {tool} is not in any binary cache — building it from source.");
    eprintln!("nix-stubs: this can take a while. Set NIX_STUBS_NO_BUILD=1 to fail instead.");

    let built = Command::new("nix-store")
        .args(["--realise", drv_path])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::inherit())
        .status()
        .map_err(|e| format!("failed to run nix-store: {e}"))?;

    if !built.success() {
        return Err(format!("nix-store --realise failed for {tool}"));
    }
    Ok(())
}

fn cmd_exec(
    drv_path: String,
    output: String,
    out_path: Option<String>,
    bin: Option<String>,
    tool: String,
    args: Vec<String>,
) {
    let out_path = match out_path {
        Some(p) => p,
        None => match resolve_out_path(&drv_path, &output) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("nix-stubs: {e}");
                std::process::exit(1);
            }
        },
    };

    if !Path::new(&out_path).exists() {
        if let Err(e) = realize(&drv_path, &tool) {
            eprintln!("nix-stubs: {e}");
            std::process::exit(1);
        }
    }

    let bin_name = bin.unwrap_or_else(|| tool.clone());
    let bin_path = format!("{out_path}/bin/{bin_name}");

    if !Path::new(&bin_path).exists() {
        eprintln!("nix-stubs: binary '{bin_name}' not found at {bin_path}");
        std::process::exit(1);
    }

    let err = Command::new(&bin_path).args(&args).exec();
    eprintln!("nix-stubs: failed to exec {bin_path}: {err}");
    std::process::exit(1);
}

fn gen_opts(
    flake: String,
    attr: String,
    systems: Vec<String>,
    lock_path: String,
    flake_lock_path: String,
    inputs: Vec<String>,
    discover_bins: bool,
) -> GenOpts {
    // An explicit --input wins; otherwise reuse whatever the lock already pins,
    // so a plain `gen` after the first one keeps the same input set.
    let inputs = if !inputs.is_empty() {
        inputs
    } else {
        match lock::Lock::read(&lock_path) {
            Ok(l) if !l.inputs.is_empty() => l.inputs.keys().cloned().collect(),
            _ => vec!["nixpkgs".to_string()],
        }
    };
    GenOpts {
        flake,
        attr,
        systems,
        lock_path,
        flake_lock_path,
        inputs,
        discover_bins,
    }
}

fn cmd_activate(shell: Shell, manifest: String, shim_dir: String) {
    match shell {
        Shell::Bash => {
            println!(
                r#"# nix-stubs shell activation (bash)
export PATH="${{PATH}}:{shim_dir}"
__nix_stubs_hook() {{
  local new_path
  new_path="$(nix-stubs hook-env --manifest "{manifest}" 2>/dev/null)"
  if [ -n "$new_path" ]; then
    export PATH="$new_path"
  fi
}}
if [[ ! "${{PROMPT_COMMAND:-}}" =~ __nix_stubs_hook ]]; then
  PROMPT_COMMAND="__nix_stubs_hook${{PROMPT_COMMAND:+;$PROMPT_COMMAND}}"
fi"#
            );
        }
        Shell::Zsh => {
            println!(
                r#"# nix-stubs shell activation (zsh)
export PATH="${{PATH}}:{shim_dir}"
__nix_stubs_hook() {{
  local new_path
  new_path="$(nix-stubs hook-env --manifest "{manifest}" 2>/dev/null)"
  if [[ -n "$new_path" ]]; then
    export PATH="$new_path"
  fi
}}
if (( ! ${{precmd_functions[(I)__nix_stubs_hook]}} )); then
  precmd_functions+=(__nix_stubs_hook)
fi"#
            );
        }
        Shell::Fish => {
            println!(
                r#"# nix-stubs shell activation (fish)
set -gx PATH $PATH "{shim_dir}"
function __nix_stubs_hook --on-event fish_prompt
  set -l new_path (nix-stubs hook-env --manifest "{manifest}" 2>/dev/null)
  if test -n "$new_path"
    set -gx PATH (string split ":" -- $new_path)
  end
end"#
            );
        }
    }
}

fn cmd_hook_env(manifest: String) {
    let manifest_contents = match fs::read_to_string(&manifest) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("nix-stubs: failed to read manifest {manifest}: {e}");
            std::process::exit(1);
        }
    };

    let manifest: Manifest = match serde_json::from_str(&manifest_contents) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("nix-stubs: failed to parse manifest: {e}");
            std::process::exit(1);
        }
    };

    let current_path = std::env::var("PATH").unwrap_or_default();
    let current_entries: Vec<&str> = current_path.split(':').collect();

    // Collect bin dirs for realized packages
    let mut realized_dirs: Vec<String> = Vec::new();
    for entry in manifest.tools.values() {
        let bin_dir = format!("{}/bin", entry.out_path);
        if Path::new(&bin_dir).exists() && !current_entries.contains(&bin_dir.as_str()) {
            realized_dirs.push(bin_dir);
        }
    }

    if realized_dirs.is_empty() {
        // No changes needed — output nothing
        return;
    }

    // Prepend realized dirs to PATH (before existing entries)
    realized_dirs.extend(current_entries.iter().map(|s| s.to_string()));
    println!("{}", realized_dirs.join(":"));
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Exec {
            drv_path,
            output,
            out_path,
            bin,
            tool,
            args,
        } => cmd_exec(drv_path, output, out_path, bin, tool, args),
        Commands::Gen {
            flake,
            attr,
            systems,
            lock,
            flake_lock,
            inputs,
            discover_bins,
        } => gen::cmd_gen(gen_opts(
            flake,
            attr,
            systems,
            lock,
            flake_lock,
            inputs,
            discover_bins,
        )),
        Commands::Check {
            flake,
            attr,
            lock,
            flake_lock,
            fast,
        } => gen::cmd_check(
            gen_opts(flake, attr, vec![], lock, flake_lock, vec![], false),
            fast,
        ),
        Commands::Activate {
            shell,
            manifest,
            shim_dir,
        } => cmd_activate(shell, manifest, shim_dir),
        Commands::HookEnv { manifest } => cmd_hook_env(manifest),
    }
}
