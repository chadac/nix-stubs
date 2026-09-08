//! The recipe blob: a package's build graph packed as a `nix-store --export`
//! stream, so it can travel as an ordinary derivation OUTPUT.
//!
//! Why a blob instead of the .drv files themselves: a .drv inside a stub's
//! closure makes every closure ENUMERATION fail — closureInfo, nix2container,
//! dockerTools.streamLayeredImage all walk the graph with
//! exportReferencesGraph, which requires every path in it to be locally valid,
//! and no binary cache serves .drv paths. That took down a consumer's image
//! build; nix/tests/closure.nix is the regression test.
//!
//! A blob's output is reference-FREE (the shim sets unsafeDiscardReferences),
//! so it substitutes from a cache like any other package and a closure walk
//! sees one unremarkable path.
//!
//! The stream is written by hand rather than shelled out to `nix-store
//! --export` because this runs INSIDE a build sandbox, which has no daemon
//! socket. The format needs no hashing — nix computes that on import — so it is
//! just NAR + framing.

use std::collections::HashSet;
use std::fs;
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// "NIXE" little-endian, written as a u64. Nix's `exportMagic`.
const EXPORT_MAGIC: u64 = 0x4558_494e;

// --- ATerm -----------------------------------------------------------------

/// Split a store derivation's ATerm into its 7 top-level fields:
///
///   Derive([outputs],[inputDrvs],[inputSrcs],system,builder,[args],[env])
///
/// Fields 2 and 3 are the dependency edges, and are exactly what nix records as
/// a .drv's references. Field 1 names OUTPUT paths and field 7 (env) names the
/// output paths of build inputs — collecting either drags in the whole
/// toolchain, unbuilt, which is the bug this module exists to avoid.
fn aterm_fields(text: &str) -> Result<Vec<&str>, String> {
    let body = text
        .strip_prefix("Derive(")
        .ok_or_else(|| "not a store derivation: no `Derive(` prefix".to_string())?;

    let bytes = body.as_bytes();
    let mut fields = Vec::new();
    let mut depth = 0usize;
    let mut in_str = false;
    let mut escaped = false;
    let mut start = 0usize;

    for (i, &c) in bytes.iter().enumerate() {
        if escaped {
            escaped = false;
            continue;
        }
        match c {
            b'\\' if in_str => escaped = true,
            b'"' => in_str = !in_str,
            _ if in_str => {}
            b'[' | b'(' => depth += 1,
            b']' => depth -= 1,
            b')' => {
                if depth == 0 {
                    fields.push(&body[start..i]);
                    return Ok(fields);
                }
                depth -= 1;
            }
            b',' if depth == 0 => {
                fields.push(&body[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    Err("malformed store derivation: unterminated `Derive(`".to_string())
}

/// Every quoted string in `field` that names a store path.
///
/// Output NAMES ("out", "dev") and build args are quoted too, so the
/// `/nix/store/` prefix is what separates a dependency from a label.
fn store_paths_in(field: &str) -> Vec<String> {
    let mut out = Vec::new();
    let bytes = field.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'"' {
            let start = i + 1;
            let mut j = start;
            while j < bytes.len() && bytes[j] != b'"' {
                if bytes[j] == b'\\' {
                    j += 1;
                }
                j += 1;
            }
            let s = &field[start..j.min(field.len())];
            if s.starts_with("/nix/store/") {
                out.push(s.to_string());
            }
            i = j + 1;
        } else {
            i += 1;
        }
    }
    out
}

/// A .drv's references: inputDrvs ∪ inputSrcs.
pub fn references_of(path: &Path) -> Result<Vec<String>, String> {
    if !is_drv(path) {
        // Source paths in a recipe closure carry no references of their own.
        // nix/tests/integration.nix checks the whole packed closure against
        // `nix-store --requisites` in a VM, so a package that broke this
        // assumption fails there rather than silently shipping a recipe that
        // cannot be realised.
        return Ok(Vec::new());
    }
    let text = fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
    let fields = aterm_fields(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    if fields.len() < 3 {
        return Err(format!("{}: expected 7 ATerm fields", path.display()));
    }
    let mut refs: Vec<String> = store_paths_in(fields[1]);
    refs.extend(store_paths_in(fields[2]));
    refs.sort();
    refs.dedup();
    Ok(refs)
}

fn is_drv(path: &Path) -> bool {
    path.extension().map(|e| e == "drv").unwrap_or(false)
}

/// The recipe closure of `roots`, DEPENDENCIES FIRST.
///
/// `nix-store --import` registers paths as it reads them, so a path must not
/// appear before something it references.
pub fn closure(roots: &[PathBuf]) -> Result<Vec<PathBuf>, String> {
    let mut order = Vec::new();
    let mut done: HashSet<PathBuf> = HashSet::new();
    let mut stack: Vec<(PathBuf, bool)> = roots.iter().rev().map(|r| (r.clone(), false)).collect();

    while let Some((path, expanded)) = stack.pop() {
        if done.contains(&path) {
            continue;
        }
        if expanded {
            done.insert(path.clone());
            order.push(path);
            continue;
        }
        stack.push((path.clone(), true));
        for r in references_of(&path)? {
            let dep = PathBuf::from(r);
            if dep != path && !done.contains(&dep) {
                stack.push((dep, false));
            }
        }
    }
    Ok(order)
}

// --- NAR -------------------------------------------------------------------

fn write_u64<W: Write>(w: &mut W, v: u64) -> io::Result<()> {
    w.write_all(&v.to_le_bytes())
}

/// Length-prefixed and padded to an 8-byte boundary — the only primitive the
/// NAR and export formats use.
fn write_bytes<W: Write>(w: &mut W, b: &[u8]) -> io::Result<()> {
    write_u64(w, b.len() as u64)?;
    w.write_all(b)?;
    let pad = (8 - b.len() % 8) % 8;
    if pad > 0 {
        w.write_all(&[0u8; 8][..pad])?;
    }
    Ok(())
}

fn write_str<W: Write>(w: &mut W, s: &str) -> io::Result<()> {
    write_bytes(w, s.as_bytes())
}

fn write_node<W: Write>(w: &mut W, path: &Path) -> io::Result<()> {
    let md = fs::symlink_metadata(path)?;
    write_str(w, "(")?;
    write_str(w, "type")?;

    if md.file_type().is_symlink() {
        write_str(w, "symlink")?;
        write_str(w, "target")?;
        write_bytes(w, fs::read_link(path)?.as_os_str().as_bytes())?;
    } else if md.is_dir() {
        write_str(w, "directory")?;
        // Byte order, matching nix's own `std::map<string>` ordering — a NAR
        // with entries in any other order hashes differently.
        let mut entries: Vec<_> = fs::read_dir(path)?
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .map(|e| e.file_name())
            .collect();
        entries.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
        for name in entries {
            write_str(w, "entry")?;
            write_str(w, "(")?;
            write_str(w, "name")?;
            write_bytes(w, name.as_bytes())?;
            write_str(w, "node")?;
            write_node(w, &path.join(&name))?;
            write_str(w, ")")?;
        }
    } else {
        write_str(w, "regular")?;
        if md.permissions().mode() & 0o111 != 0 {
            write_str(w, "executable")?;
            write_str(w, "")?;
        }
        write_str(w, "contents")?;
        write_bytes(w, &fs::read(path)?)?;
    }

    write_str(w, ")")
}

fn write_nar<W: Write>(w: &mut W, path: &Path) -> io::Result<()> {
    write_str(w, "nix-archive-1")?;
    write_node(w, path)
}

// --- export stream ---------------------------------------------------------

/// Write the `nix-store --export` stream for `paths`, in the given order.
pub fn write_export<W: Write>(w: &mut W, paths: &[PathBuf]) -> Result<(), String> {
    let io_err = |p: &Path, e: io::Error| format!("packing {}: {e}", p.display());

    for path in paths {
        write_u64(w, 1).map_err(|e| io_err(path, e))?;
        write_nar(w, path).map_err(|e| io_err(path, e))?;
        write_u64(w, EXPORT_MAGIC).map_err(|e| io_err(path, e))?;
        write_str(w, &path.to_string_lossy()).map_err(|e| io_err(path, e))?;

        let refs = references_of(path)?;
        write_u64(w, refs.len() as u64).map_err(|e| io_err(path, e))?;
        for r in &refs {
            write_str(w, r).map_err(|e| io_err(path, e))?;
        }

        // Deriver: deliberately empty. A recipe is for BUILDING, and a deriver
        // only records what already built a path.
        write_str(w, "").map_err(|e| io_err(path, e))?;
        // No signature. Import therefore needs a trusted user, which is why the
        // dispatcher reports that case specifically (see main.rs).
        write_u64(w, 0).map_err(|e| io_err(path, e))?;
    }
    write_u64(w, 0).map_err(|e| format!("closing the stream: {e}"))
}

pub fn cmd_export(roots: Vec<String>, out: Option<String>, list: bool) {
    let roots: Vec<PathBuf> = roots.into_iter().map(PathBuf::from).collect();
    let paths = match closure(&roots) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("nix-stubs: {e}");
            std::process::exit(1);
        }
    };

    // `--list` exists so the packing ORDER can be handed to `nix-store --export`
    // and the two streams compared byte-for-byte. That comparison is the only
    // real check on a hand-written NAR writer.
    if list {
        for p in &paths {
            println!("{}", p.display());
        }
        return;
    }

    let out = match out {
        Some(o) => o,
        None => {
            eprintln!("nix-stubs: recipe needs --out (or --list)");
            std::process::exit(1);
        }
    };

    let file = match fs::File::create(&out) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("nix-stubs: creating {out}: {e}");
            std::process::exit(1);
        }
    };
    let mut w = io::BufWriter::new(file);
    if let Err(e) = write_export(&mut w, &paths).and_then(|()| {
        w.flush()
            .map_err(|e| format!("flushing {out}: {e}"))
            .map(|_| ())
    }) {
        eprintln!("nix-stubs: {e}");
        std::process::exit(1);
    }
    eprintln!("nix-stubs: packed {} paths into {out}", paths.len());
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = concat!(
        r#"Derive([("out","/nix/store/aaa-out","","")],"#,
        r#"[("/nix/store/bbb-dep.drv",["out"])],"#,
        r#"["/nix/store/ccc-builder.sh","/nix/store/ddd-patch"],"#,
        r#""x86_64-linux","/nix/store/eee-bash",["-e"],"#,
        r#"[("buildInputs","/nix/store/fff-should-not-appear")])"#
    );

    #[test]
    fn splits_top_level_fields() {
        let f = aterm_fields(SAMPLE).unwrap();
        assert_eq!(f.len(), 7);
    }

    #[test]
    fn takes_only_the_dependency_fields() {
        let f = aterm_fields(SAMPLE).unwrap();
        let mut refs = store_paths_in(f[1]);
        refs.extend(store_paths_in(f[2]));
        assert_eq!(
            refs,
            vec![
                "/nix/store/bbb-dep.drv",
                "/nix/store/ccc-builder.sh",
                "/nix/store/ddd-patch"
            ]
        );
        // The output path (field 1) and the env's build inputs (field 7) are
        // what a naive regex over the whole .drv would pull in.
        assert!(!refs.iter().any(|r| r.contains("should-not-appear")));
        assert!(!refs.iter().any(|r| r.contains("aaa-out")));
    }

    #[test]
    fn commas_inside_strings_do_not_split_a_field() {
        let drv = r#"Derive([("out","/nix/store/aaa-out","","")],[],["/nix/store/x-a,b"],"s","/nix/store/b",["-c","a,b"],[])"#;
        let f = aterm_fields(drv).unwrap();
        assert_eq!(f.len(), 7);
        assert_eq!(store_paths_in(f[2]), vec!["/nix/store/x-a,b"]);
    }
}
