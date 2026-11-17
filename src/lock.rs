//! stubs.lock — the build description, and its sync relationship to flake.lock.
//!
//! The lock is a BUILD-time artifact. Nothing reads it at runtime: once a stub
//! is built, the recipe is in the store and `nix-store` alone can realise it.
//! Its only job is to let the overlay construct stubs without evaluating the
//! packages they stand for.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const LOCK_VERSION: u32 = 1;

/// Ordering is deterministic (BTreeMap + pretty JSON) so a regenerated lock is
/// byte-identical when nothing changed, and a real diff is readable in review.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Lock {
    pub version: u32,
    /// Input name -> the `locked` node copied verbatim out of flake.lock.
    pub inputs: BTreeMap<String, serde_json::Value>,
    /// system -> stub name -> entry
    pub packages: BTreeMap<String, BTreeMap<String, Entry>>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Entry {
    /// nixpkgs attribute this stub replaces (defaults to the stub name).
    pub attr: String,
    /// The realisation key. Its closure is what gets baked into the image.
    pub drv: String,
    /// Which output to exec from, by name. Required: awscli2 realises to both
    /// `out` and `dist`, and position is not a stable way to pick.
    pub output: String,
    pub bins: Vec<String>,
    /// Package name+version, for human-readable diffs. Not used to build.
    pub name: String,
}

impl Lock {
    pub fn empty() -> Self {
        Lock {
            version: LOCK_VERSION,
            inputs: BTreeMap::new(),
            packages: BTreeMap::new(),
        }
    }

    pub fn read(path: &str) -> Result<Self, String> {
        let s = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
        let lock: Lock =
            serde_json::from_str(&s).map_err(|e| format!("{path}: not a valid stubs.lock: {e}"))?;
        if lock.version != LOCK_VERSION {
            return Err(format!(
                "{path}: lock version {} is not supported by this nix-stubs (expected {LOCK_VERSION})",
                lock.version
            ));
        }
        Ok(lock)
    }

    pub fn to_json(&self) -> String {
        let mut s = serde_json::to_string_pretty(self).expect("lock serialises");
        s.push('\n');
        s
    }

    pub fn write(&self, path: &str) -> Result<(), String> {
        std::fs::write(path, self.to_json()).map_err(|e| format!("{path}: {e}"))
    }
}

/// The `locked` node of a root-level flake input.
///
/// Recorded verbatim so the sync check is an exact comparison: any change to
/// how that input is pinned trips it, not just a rev bump.
/// A `follows` input pins the node it points at.
pub fn locked_input(
    flake_lock: &serde_json::Value,
    name: &str,
) -> Result<serde_json::Value, String> {
    let root = flake_lock
        .get("root")
        .and_then(|v| v.as_str())
        .ok_or("flake.lock: no root node")?;
    let nodes = flake_lock.get("nodes").ok_or("flake.lock: no nodes")?;
    let reference = input_of(nodes, root, name)
        .map_err(|_| format!("flake.lock: '{name}' is not an input of this flake"))?;
    let node_name = resolve(nodes, root, reference, 0)
        .map_err(|e| format!("flake.lock: input '{name}': {e}"))?;

    nodes
        .get(&node_name)
        .and_then(|n| n.get("locked"))
        .cloned()
        .ok_or_else(|| format!("flake.lock: node '{node_name}' has no 'locked' entry"))
}

fn input_of<'a>(
    nodes: &'a serde_json::Value,
    node: &str,
    input: &str,
) -> Result<&'a serde_json::Value, String> {
    nodes
        .get(node)
        .and_then(|n| n.get("inputs"))
        .and_then(|i| i.get(input))
        .ok_or_else(|| format!("'{input}' is not an input of '{node}'"))
}

/// A node name, or a `follows` path walked from the root to a node name.
fn resolve(
    nodes: &serde_json::Value,
    root: &str,
    reference: &serde_json::Value,
    depth: usize,
) -> Result<String, String> {
    if depth > 64 {
        return Err("its follows paths form a cycle".to_string());
    }
    match reference {
        serde_json::Value::String(node) => Ok(node.clone()),
        serde_json::Value::Array(path) => {
            let mut node = root.to_string();
            for step in path {
                let step = step.as_str().ok_or("malformed follows path")?;
                node = resolve(nodes, root, input_of(nodes, &node, step)?, depth + 1)?;
            }
            Ok(node)
        }
        _ => Err("malformed input reference".to_string()),
    }
}

pub fn describe_input(locked: &serde_json::Value) -> String {
    let field = |k: &str| locked.get(k).and_then(|v| v.as_str()).unwrap_or("");
    let rev = match locked.get("rev").and_then(|v| v.as_str()) {
        Some(r) => r.chars().take(12).collect::<String>(),
        None => field("narHash").to_string(),
    };
    let what = match (field("owner"), field("repo")) {
        ("", "") => format!("{}{}", field("url"), field("path")),
        (o, r) => format!("{o}/{r}"),
    };
    format!("{}:{} @ {}", field("type"), what, rev)
}

/// Inputs pinned by stubs.lock that flake.lock no longer agrees with.
pub fn sync_errors(lock: &Lock, flake_lock: &serde_json::Value) -> Vec<String> {
    let mut errs = Vec::new();
    for (name, pinned) in &lock.inputs {
        match locked_input(flake_lock, name) {
            Ok(actual) if &actual == pinned => {}
            Ok(actual) => errs.push(format!(
                "input '{name}'\n    flake.lock  {}\n    stubs.lock  {}",
                describe_input(&actual),
                describe_input(pinned)
            )),
            Err(e) => errs.push(format!("input '{name}'\n    {e}")),
        }
    }
    errs
}

pub fn read_flake_lock(path: &str) -> Result<serde_json::Value, String> {
    let s = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    serde_json::from_str(&s).map_err(|e| format!("{path}: not valid JSON: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn flake_lock() -> serde_json::Value {
        json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "scooter": "scooter", "nixpkgs": ["scooter", "nixpkgs"] } },
                "scooter": {
                    "inputs": { "nixpkgs": "nixpkgs", "pinned": ["scooter", "nixpkgs"] },
                    "locked": { "type": "github", "rev": "s" }
                },
                "nixpkgs": { "locked": { "type": "github", "rev": "n" } }
            }
        })
    }

    #[test]
    fn direct_input() {
        assert_eq!(locked_input(&flake_lock(), "scooter").unwrap()["rev"], "s");
    }

    #[test]
    fn follows_input_pins_its_target() {
        assert_eq!(locked_input(&flake_lock(), "nixpkgs").unwrap()["rev"], "n");
    }

    #[test]
    fn follows_through_follows() {
        let mut l = flake_lock();
        l["nodes"]["root"]["inputs"]["nixpkgs"] = json!(["scooter", "pinned"]);
        assert_eq!(locked_input(&l, "nixpkgs").unwrap()["rev"], "n");
    }

    #[test]
    fn follows_cycle_is_an_error() {
        let mut l = flake_lock();
        l["nodes"]["root"]["inputs"]["nixpkgs"] = json!(["nixpkgs"]);
        assert!(locked_input(&l, "nixpkgs").unwrap_err().contains("cycle"));
    }

    #[test]
    fn missing_input() {
        assert!(locked_input(&flake_lock(), "nope").is_err());
    }
}
