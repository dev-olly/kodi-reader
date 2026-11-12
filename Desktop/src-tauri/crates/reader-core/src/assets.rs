use crate::paths::{content_filename, safe_relative_file};
use crate::{Book, Result};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

/// A deletion plan is prepared before the library commit, but is executed only
/// after the record has durably disappeared. Paths are checked again at unlink.
pub(crate) struct DeletionPlan {
    root: PathBuf,
    files: BTreeMap<String, &'static str>,
    directories: Vec<PathBuf>,
}

pub(crate) fn deletion_plan<'a>(
    root: &Path,
    removed: &Book,
    remaining: impl Iterator<Item = &'a Book>,
) -> Result<DeletionPlan> {
    let mut retained = BTreeSet::new();
    for book in remaining {
        // Preserve future/unknown media fields too. Only safe paths under an
        // expected asset folder qualify; ordinary note prose is not a path.
        let value = serde_json::to_value(book)?;
        let mut strings = Vec::new();
        string_values(&value, &mut strings);
        for relative in strings {
            if asset_folder(relative).is_some() {
                // A remaining record may legitimately refer through an
                // internal symlink. Preserve its target even though unlink
                // candidates require stricter, symlink-free ancestors.
                if let Ok(relative) = safe_relative_file(relative) {
                    if let Ok(path) = root.join(relative).canonicalize() {
                        if path.starts_with(root) {
                            retained.insert(path);
                        }
                    }
                }
            }
        }
    }
    let mut candidates = BTreeMap::new();
    candidates.insert(removed.imported_relative_path.clone(), "Books");
    if let Some(path) = &removed.cover_path {
        candidates.insert(path.clone(), "Covers");
    }
    for note in &removed.annotations {
        for sketch in &note.sketches {
            for key in ["scenePath", "previewPath"] {
                if let Some(path) = sketch[key]
                    .as_str()
                    .filter(|path| asset_folder(path) == Some("Drawings"))
                {
                    candidates.insert(path.into(), "Drawings");
                }
            }
        }
        for recording in &note.audio_recordings {
            if let Some(path) = recording["path"]
                .as_str()
                .filter(|path| asset_folder(path) == Some("Audio"))
            {
                candidates.insert(path.into(), "Audio");
            }
        }
    }
    // Include older sidecars no longer linked from a note. These directory
    // names are generated from this book's identity, never from media metadata.
    let mut identities = BTreeSet::from([removed.id.as_str()]);
    if let Some(identity) = removed.extra.get("cloudIdentity").and_then(Value::as_str) {
        identities.insert(identity);
    }
    let mut roots = BTreeSet::new();
    let literal_hex = removed
        .id
        .bytes()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    roots.insert(root.join("Drawings").join(literal_hex));
    for identity in identities {
        let hash = hex::encode(Sha256::digest(identity.as_bytes()));
        roots.insert(root.join("Drawings").join(&hash));
        roots.insert(root.join("Audio").join(hash));
    }
    let mut directories = Vec::new();
    for directory in roots {
        collect_owned_tree(root, &directory, &mut candidates, &mut directories)?;
    }
    let filename = content_filename(&removed.id);
    for folder in ["Books", "Covers"] {
        let Some(base) = safe_base(root, folder) else {
            continue;
        };
        for entry in fs::read_dir(base)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let owned = if folder == "Books" {
                name.starts_with(&format!("{filename}.corrupt-"))
            } else {
                name.starts_with(&format!("{filename}."))
            };
            if owned {
                candidates.insert(format!("{folder}/{name}"), folder);
            }
        }
    }
    candidates.retain(|relative, folder| {
        checked_asset(root, relative, folder)
            .and_then(|path| path.canonicalize().ok())
            .is_some_and(|path| {
                !retained
                    .iter()
                    .any(|reference| path == *reference || path.starts_with(reference))
            })
    });
    Ok(DeletionPlan {
        root: root.to_path_buf(),
        files: candidates,
        directories,
    })
}

fn string_values<'a>(value: &'a Value, output: &mut Vec<&'a str>) {
    match value {
        Value::String(value) => output.push(value),
        Value::Array(values) => values.iter().for_each(|value| string_values(value, output)),
        Value::Object(values) => values
            .values()
            .for_each(|value| string_values(value, output)),
        _ => {}
    }
}

fn asset_folder(relative: &str) -> Option<&'static str> {
    ["Books", "Covers", "Drawings", "Audio"]
        .into_iter()
        .find(|folder| relative.starts_with(&format!("{folder}/")))
}

fn checked_asset(root: &Path, relative: &str, expected: &str) -> Option<PathBuf> {
    let path = checked_asset_path(root, relative, expected)?;
    path.is_file().then_some(path)
}

fn safe_base(root: &Path, expected: &str) -> Option<PathBuf> {
    let base = root.join(expected);
    if fs::symlink_metadata(&base).ok()?.file_type().is_symlink() {
        return None;
    }
    let canonical = base.canonicalize().ok()?;
    (canonical.starts_with(root) && canonical.is_dir()).then_some(base)
}

fn checked_asset_path(root: &Path, relative: &str, expected: &str) -> Option<PathBuf> {
    let relative_path = safe_relative_file(relative).ok()?;
    if relative_path.components().next()?.as_os_str() != expected {
        return None;
    }
    let base = safe_base(root, expected)?.canonicalize().ok()?;
    let path = root.join(&relative_path);
    // Never follow a metadata-selected directory symlink into another tree.
    let mut ancestor = root.to_path_buf();
    let count = relative_path.components().count();
    for component in relative_path.components().take(count.saturating_sub(1)) {
        ancestor.push(component.as_os_str());
        if fs::symlink_metadata(&ancestor)
            .ok()?
            .file_type()
            .is_symlink()
        {
            return None;
        }
    }
    let canonical = path.canonicalize().ok()?;
    canonical.starts_with(base).then_some(path)
}

fn collect_owned_tree(
    root: &Path,
    directory: &Path,
    files: &mut BTreeMap<String, &'static str>,
    directories: &mut Vec<PathBuf>,
) -> Result<()> {
    let mut pending = vec![directory.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let metadata = match fs::symlink_metadata(&directory) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            continue;
        }
        let relative = directory
            .strip_prefix(root)
            .unwrap_or(Path::new(""))
            .to_string_lossy()
            .replace('\\', "/");
        let Some(folder) = asset_folder(&relative) else {
            continue;
        };
        if checked_asset_path(root, &relative, folder).is_none() {
            continue;
        }
        directories.push(directory.clone());
        for entry in fs::read_dir(&directory)? {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                pending.push(entry.path());
            } else if let Ok(relative) = entry.path().strip_prefix(root) {
                files.insert(relative.to_string_lossy().replace('\\', "/"), folder);
            }
        }
    }
    Ok(())
}

impl DeletionPlan {
    pub fn execute(mut self) -> Vec<String> {
        let mut errors = Vec::new();
        for (relative, folder) in self.files {
            if let Some(path) = checked_asset(&self.root, &relative, folder) {
                if let Err(error) = fs::remove_file(path) {
                    if error.kind() != std::io::ErrorKind::NotFound {
                        errors.push(format!("{relative}: {error}"));
                    }
                }
            }
        }
        self.directories
            .sort_by_key(|path| std::cmp::Reverse(path.components().count()));
        for directory in self.directories {
            // Nonempty folders contain retained/shared assets and are kept.
            let relative = directory
                .strip_prefix(&self.root)
                .unwrap_or(Path::new(""))
                .to_string_lossy()
                .replace('\\', "/");
            if let Some(folder) = asset_folder(&relative) {
                if checked_asset_path(&self.root, &relative, folder).is_some()
                    && fs::symlink_metadata(&directory).is_ok_and(|metadata| {
                        metadata.is_dir() && !metadata.file_type().is_symlink()
                    })
                {
                    let _ = fs::remove_dir(directory);
                }
            }
        }
        errors
    }
}
