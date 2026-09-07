mod gen;
mod lock;
mod recipe;

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

        /// Recipe blob to import when the .drv is not in the store
        #[arg(long)]
        recipe: Option<String>,

        /// Tool name
        tool: String,

        /// Arguments to pass to the tool
        #[arg(last = true)]
        args: Vec<String>,
    },

    /// Pack a .drv's build graph into a recipe blob (a nix-store export stream)
    Recipe {
        /// Where to write the blob
        #[arg(long)]
        out: Option<String>,

        /// Print the closure in packing order instead of writing a blob
        #[arg(long)]
        list: bool,

        /// Root .drv paths to pack
        roots: Vec<String>,
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
                 Binary caches do not serve .drv paths, so it cannot be fetched — it comes \
                 from the stub's recipe blob. The stub was built without one, or the import \
                 failed; rebuild it with a nix-stubs that passes --recipe."
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

/// Put the recipe back in the store.
///
/// The blob is an ordinary derivation output — that is the whole point, since a
/// .drv shipped as itself breaks closure enumeration and no cache serves one —
/// so the .drv only becomes a real store path here, on first use.
fn import_recipe(blob: &str, tool: &str) -> Result<(), String> {
    let file = std::fs::File::open(blob)
        .map_err(|e| format!("the recipe blob for {tool} is missing:\n  {blob}\n  {e}"))?;

    let result = Command::new("nix-store")
        .arg("--import")
        .stdin(file)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .output()
        .map_err(|e| format!("failed to run nix-store --import: {e}"))?;

    if !result.status.success() {
        let stderr = String::from_utf8_lossy(&result.stderr);
        // The blob is unsigned: nothing signs a path that is generated inside a
        // build sandbox. Untrusted users cannot import one, and the generic
        // "cannot add path" is not a useful thing to hand a user.
        if stderr.contains("lacks a signature") || stderr.contains("untrusted") {
            return Err(format!(
                "cannot import the recipe for '{tool}': this user is not a trusted \
                 nix user, and a recipe blob carries no signature.\n\
                 Add yourself to `trusted-users` in nix.conf, or realise the tool \
                 as root once."
            ));
        }
        return Err(format!(
            "nix-store --import failed for {tool}: {}",
            stderr.trim()
        ));
    }
    Ok(())
}

/// A stub that still has work to do needs the daemon, which a build sandbox does
/// not have. Checked before the import as well as before the realise: with the
/// recipe now shipped as a blob, importing it is the first thing that would fail,
/// and it fails as an opaque "cannot add path" instead of naming the escape hatch.
fn refuse_in_build_sandbox(tool: &str) -> Result<(), String> {
    if std::env::var_os("NIX_BUILD_TOP").is_some() {
        return Err(format!(
            "'{tool}' is a lazy stub and cannot be realised inside a build sandbox.\n\
             Use the real package for build inputs: pkgs.{tool}.real (buildInputs already \
             get it via getDev)."
        ));
    }
    Ok(())
}

fn realize(drv_path: &str, out_path: &str, tool: &str) -> Result<(), String> {
    refuse_in_build_sandbox(tool)?;

    // Substitute-first, and against the OUTPUT PATH rather than the .drv: a
    // cache hit is silent, and a MISS is where the user finds out they are about
    // to compile rather than a stub appearing to hang for 40 minutes.
    //
    // Asking for the path is also the only form that is safe here. Handing
    // nix-store a freshly imported .drv makes it plan a derivation goal, and
    // nix 2.34 ABORTS on an assertion inside Goal::work() when it does — a
    // crash, not a cache miss, so the stub fell through to building stdenv from
    // source. A path goal cannot build anything, so `--max-jobs 0` is implied.
    eprintln!("nix-stubs: fetching {tool}...");
    let substituted = Command::new("nix-store")
        .args(["--realise", out_path])
        .stdout(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("failed to run nix-store: {e}"))?;

    if substituted.status.success() {
        return Ok(());
    }

    // Why it missed, not just that it did: "no substituter" and "signature"
    // and "not allowed to build" are three different problems for the user, and
    // the next line commits them to a build that can take 40 minutes.
    let why = String::from_utf8_lossy(&substituted.stderr);
    for line in why.lines().filter(|l| !l.trim().is_empty()).take(3) {
        eprintln!("nix-stubs: {}", line.trim());
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
    recipe: Option<String>,
    tool: String,
    args: Vec<String>,
) {
    let die = |e: String| -> ! {
        eprintln!("nix-stubs: {e}");
        std::process::exit(1)
    };

    // The .drv is absent until something imports the blob — a stub ships the
    // recipe as an opaque output, not as store derivations.
    //
    // Driven by nix REJECTING the .drv, not by the file being absent: a store
    // image can carry the .drv file without registering it as valid (a NixOS VM
    // does exactly this), and then an existence check skips the import and every
    // later nix call fails with "path … is not valid".
    let import_once = std::cell::Cell::new(false);
    let ensure_recipe = || {
        if import_once.replace(true) {
            return false;
        }
        match &recipe {
            None => false,
            Some(blob) => {
                if let Err(e) =
                    refuse_in_build_sandbox(&tool).and_then(|_| import_recipe(blob, &tool))
                {
                    die(e);
                }
                true
            }
        }
    };

    let out_path = match out_path {
        // An out-path in the shim means the common case (the tool is already
        // realised) costs no nix-store call and no import at all.
        Some(p) => p,
        None => match resolve_out_path(&drv_path, &output) {
            Ok(p) => p,
            // The recipe is the only way that lookup can start working, so retry
            // exactly once behind it rather than reporting the first failure.
            Err(e) => {
                if !ensure_recipe() {
                    die(e);
                }
                match resolve_out_path(&drv_path, &output) {
                    Ok(p) => p,
                    Err(e) => die(e),
                }
            }
        },
    };

    if !Path::new(&out_path).exists() {
        ensure_recipe();
        if let Err(e) = realize(&drv_path, &out_path, &tool) {
            die(e);
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
            recipe,
            tool,
            args,
        } => cmd_exec(drv_path, output, out_path, bin, recipe, tool, args),
        Commands::Recipe { out, list, roots } => recipe::cmd_export(roots, out, list),
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
