mod gen;
mod lock;

use clap::{Parser, Subcommand};
use gen::GenOpts;
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
    }
}
