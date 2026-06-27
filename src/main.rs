use clap::{Parser, Subcommand};
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

fn resolve_out_path(drv_path: &str) -> Result<String, String> {
    let output = Command::new("nix-store")
        .args(["--query", "--outputs", drv_path])
        .output()
        .map_err(|e| format!("failed to run nix-store: {e}"))?;

    if !output.status.success() {
        return Err(format!(
            "nix-store --query --outputs failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let out = String::from_utf8_lossy(&output.stdout)
        .trim()
        .lines()
        .next()
        .unwrap_or("")
        .to_string();

    if out.is_empty() {
        return Err("nix-store returned empty output path".to_string());
    }

    Ok(out)
}

fn realize(drv_path: &str, tool: &str) -> Result<(), String> {
    eprintln!("nix-stubs: installing {tool}...");

    let status = Command::new("nix-store")
        .args(["--realise", drv_path])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::inherit())
        .status()
        .map_err(|e| format!("failed to run nix-store: {e}"))?;

    if !status.success() {
        return Err(format!("nix-store --realise failed for {tool}"));
    }

    Ok(())
}

fn cmd_exec(
    drv_path: String,
    out_path: Option<String>,
    bin: Option<String>,
    tool: String,
    args: Vec<String>,
) {
    let out_path = match out_path {
        Some(p) => p,
        None => match resolve_out_path(&drv_path) {
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
            out_path,
            bin,
            tool,
            args,
        } => cmd_exec(drv_path, out_path, bin, tool, args),
        Commands::Activate {
            shell,
            manifest,
            shim_dir,
        } => cmd_activate(shell, manifest, shim_dir),
        Commands::HookEnv { manifest } => cmd_hook_env(manifest),
    }
}
