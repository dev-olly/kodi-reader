use crate::{Result, SketchSession};
use base64::Engine;
use kodi_reader_core::{Library, LibraryStore};
use serde_json::{json, Value};
use std::{
    io::Write,
    path::{Component, Path, PathBuf},
};

fn metadata<'a>(store: &'a LibraryStore, session: &SketchSession) -> Result<&'a Value> {
    store
        .book(&session.book_id)
        .map_err(|error| error.to_string())?
        .annotations
        .iter()
        .find(|note| note.id.eq_ignore_ascii_case(&session.annotation_id))
        .ok_or("This note has been deleted.")?
        .sketches
        .iter()
        .find(|sketch| {
            sketch["id"]
                .as_str()
                .is_some_and(|id| id.eq_ignore_ascii_case(&session.sketch_id))
        })
        .ok_or_else(|| {
            "This sketch has been deleted. Its editor can no longer save changes.".into()
        })
}

pub(crate) fn exists(store: &LibraryStore, session: &SketchSession) -> bool {
    metadata(store, session).is_ok()
}

fn drawing_path(root: &Path, relative: &str) -> Result<PathBuf> {
    let relative_path = Path::new(relative);
    if !relative.starts_with("Drawings/")
        || relative.contains(['\\', '\0', ':'])
        || relative_path.is_absolute()
        || relative_path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err("Invalid drawing file location.".into());
    }
    let base = root
        .join("Drawings")
        .canonicalize()
        .map_err(|error| error.to_string())?;
    let path = root.join(relative_path);
    // Check an existing ancestor before creating any missing directories.
    let ancestor = path
        .ancestors()
        .find(|ancestor| ancestor.exists())
        .ok_or("Drawing folder is unavailable")?;
    if !ancestor
        .canonicalize()
        .map_err(|error| error.to_string())?
        .starts_with(&base)
    {
        return Err("This drawing is outside the drawing library.".into());
    }
    Ok(path)
}

fn legacy_path(root: &Path, session: &SketchSession) -> Result<PathBuf> {
    uuid::Uuid::parse_str(&session.annotation_id).map_err(|_| "Invalid note identifier")?;
    uuid::Uuid::parse_str(&session.sketch_id).map_err(|_| "Invalid sketch identifier")?;
    let book = session
        .book_id
        .bytes()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    drawing_path(
        root,
        &format!(
            "Drawings/{book}/{}/{}.excalidraw.json",
            session.annotation_id, session.sketch_id
        ),
    )
}

fn scene_path(store: &LibraryStore, session: &SketchSession, sketch: &Value) -> Result<PathBuf> {
    if let Some(relative) = sketch.get("scenePath").filter(|value| !value.is_null()) {
        let relative = relative
            .as_str()
            .filter(|value| value.ends_with(".json"))
            .ok_or("Invalid drawing file location")?;
        drawing_path(store.root(), relative)
    } else {
        legacy_path(store.root(), session)
    }
}

pub(crate) fn read(store: &LibraryStore, session: &SketchSession) -> Result<Value> {
    let sketch = metadata(store, session)?;
    let path = scene_path(store, session, sketch)?;
    if !path.is_file() {
        // A new local sketch has no scene yet. A missing saved/synced scene is
        // never presented as a blank canvas that could overwrite the original.
        if sketch
            .get("scenePath")
            .is_some_and(|value| !value.is_null())
            || sketch
                .get("cloudScene")
                .is_some_and(|value| !value.is_null())
        {
            return Err("The saved drawing is unavailable on this device. Sync its files before opening it.".into());
        }
        return Ok(json!({"type":"excalidraw","version":2,"elements":[],"appState":{},"files":{}}));
    }
    if std::fs::metadata(&path)
        .map_err(|error| error.to_string())?
        .len()
        > 32 * 1024 * 1024
    {
        return Err("This sketch exceeds the 32 MiB scene limit.".into());
    }
    let scene: Value =
        serde_json::from_slice(&std::fs::read(path).map_err(|error| error.to_string())?)
            .map_err(|error| error.to_string())?;
    if !scene["elements"].is_array() {
        return Err("The saved drawing scene is unreadable; its original file was kept.".into());
    }
    Ok(scene)
}

fn atomic_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().ok_or("Drawing folder is unavailable")?;
    std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let mut temporary =
        tempfile::NamedTempFile::new_in(parent).map_err(|error| error.to_string())?;
    temporary
        .write_all(bytes)
        .map_err(|error| error.to_string())?;
    temporary
        .as_file()
        .sync_all()
        .map_err(|error| error.to_string())?;
    temporary.persist(path).map_err(|error| error.to_string())?;
    Ok(())
}

pub(crate) fn save(
    store: &mut LibraryStore,
    session: &SketchSession,
    scene: Value,
    preview: Option<String>,
) -> Result<Library> {
    // Validate ownership before any sidecar write, so an already-open editor
    // cannot recreate metadata or change files after its sketch was removed.
    let sketch = metadata(store, session)?.clone();
    let path = scene_path(store, session, &sketch)?;
    if !scene["elements"].is_array() {
        return Err("Invalid drawing scene.".into());
    }
    let bytes = serde_json::to_vec(&scene).map_err(|error| error.to_string())?;
    if bytes.len() > 32 * 1024 * 1024 {
        return Err("This sketch exceeds the 32 MiB scene limit.".into());
    }
    let preview = preview
        .map(|preview| -> Result<Vec<u8>> {
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(preview.trim_start_matches("data:image/png;base64,"))
                .map_err(|error| error.to_string())?;
            if bytes.len() > 16 * 1024 * 1024 {
                return Err("This sketch preview exceeds the 16 MiB image limit.".into());
            }
            Ok(bytes)
        })
        .transpose()?;
    atomic_file(&path, &bytes)?;
    let relative = path
        .strip_prefix(store.root())
        .map_err(|_| "Invalid drawing file location")?
        .to_string_lossy()
        .replace('\\', "/");
    let preview_relative = if let Some(bytes) = preview {
        let preview_path = if let Some(relative) = sketch["previewPath"].as_str() {
            if !relative.ends_with(".png") {
                return Err("Invalid drawing preview location.".into());
            }
            drawing_path(store.root(), relative)?
        } else {
            path.with_extension("png")
        };
        atomic_file(&preview_path, &bytes)?;
        Some(
            preview_path
                .strip_prefix(store.root())
                .map_err(|_| "Invalid drawing preview location")?
                .to_string_lossy()
                .replace('\\', "/"),
        )
    } else {
        None
    };
    store
        .mutate(|library| {
            let note = library
                .books
                .get_mut(&session.book_id)
                .and_then(|book| {
                    book.annotations
                        .iter_mut()
                        .find(|note| note.id.eq_ignore_ascii_case(&session.annotation_id))
                })
                .ok_or_else(|| {
                    kodi_reader_core::Error::Validation("This note has been deleted.".into())
                })?;
            let sketch = note
                .sketches
                .iter_mut()
                .find(|sketch| {
                    sketch["id"]
                        .as_str()
                        .is_some_and(|id| id.eq_ignore_ascii_case(&session.sketch_id))
                })
                .ok_or_else(|| {
                    kodi_reader_core::Error::Validation("This sketch has been deleted.".into())
                })?;
            sketch["scenePath"] = json!(relative);
            if preview_relative.is_some()
                || scene["elements"]
                    .as_array()
                    .is_some_and(|elements| elements.is_empty())
            {
                sketch["previewPath"] = json!(preview_relative);
            }
            sketch["modifiedAt"] = json!(kodi_reader_core::now());
            note.modified_at = kodi_reader_core::now();
            Ok(())
        })
        .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use kodi_reader_core::{Annotation, Article, Locator};

    fn fixture() -> (tempfile::TempDir, LibraryStore, SketchSession) {
        let directory = tempfile::tempdir().unwrap();
        let mut store = LibraryStore::open(directory.path().join("library")).unwrap();
        let book = store
            .import_article(&Article {
                title: "Sketch book".into(),
                author: "Author".into(),
                source_url: "https://example.com".into(),
                html: "<p>Text</p>".into(),
                images: vec![],
            })
            .unwrap();
        let mut note = Annotation::new(Locator::default(), "Passage".into());
        let sketch_id = uuid::Uuid::new_v4().to_string();
        note.sketches.push(json!({"id":sketch_id,"title":"Keep this title","createdAt":10.,"modifiedAt":20.,"futureField":true}));
        let session = SketchSession {
            book_id: book.id,
            annotation_id: note.id.clone(),
            sketch_id,
        };
        store.upsert_annotation(&session.book_id, note).unwrap();
        (directory, store, session)
    }

    #[test]
    fn synced_scene_path_is_read_and_saved_without_changing_metadata_or_location() {
        let (_directory, mut store, session) = fixture();
        let relative = format!(
            "Drawings/{}/{}/{}.excalidraw.json",
            "a".repeat(64),
            session.annotation_id,
            session.sketch_id
        );
        let path = drawing_path(store.root(), &relative).unwrap();
        atomic_file(&path, br#"{"elements":[{"id":"original"}]}"#).unwrap();
        store
            .mutate(|library| {
                library.books.get_mut(&session.book_id).unwrap().annotations[0].sketches[0]
                    ["scenePath"] = json!(relative);
                Ok(())
            })
            .unwrap();
        assert_eq!(
            read(&store, &session).unwrap()["elements"][0]["id"],
            "original"
        );
        save(
            &mut store,
            &session,
            json!({"elements":[{"id":"edited"}]}),
            None,
        )
        .unwrap();
        assert_eq!(
            read(&store, &session).unwrap()["elements"][0]["id"],
            "edited"
        );
        let sketch = metadata(&store, &session).unwrap();
        assert_eq!(sketch["scenePath"], relative);
        assert_eq!(sketch["title"], "Keep this title");
        assert_eq!(sketch["createdAt"], 10.);
        assert_eq!(sketch["futureField"], true);
        assert!(!legacy_path(store.root(), &session).unwrap().exists());
    }

    #[test]
    fn deleting_a_sketch_prevents_later_autosave_and_does_not_touch_its_file() {
        let (_directory, mut store, session) = fixture();
        save(
            &mut store,
            &session,
            json!({"elements":[{"id":"saved"}]}),
            None,
        )
        .unwrap();
        let path = scene_path(&store, &session, metadata(&store, &session).unwrap()).unwrap();
        let before = std::fs::read(&path).unwrap();
        store
            .mutate(|library| {
                library.books.get_mut(&session.book_id).unwrap().annotations[0]
                    .sketches
                    .clear();
                Ok(())
            })
            .unwrap();
        assert!(read(&store, &session).is_err());
        assert!(save(&mut store, &session, json!({"elements":[]}), None).is_err());
        assert_eq!(std::fs::read(path).unwrap(), before);
        assert!(store.book(&session.book_id).unwrap().annotations[0]
            .sketches
            .is_empty());
    }

    #[test]
    fn missing_saved_scene_and_unsafe_metadata_paths_never_open_as_blank_drawings() {
        let (_directory, mut store, session) = fixture();
        assert!(read(&store, &session).unwrap()["elements"]
            .as_array()
            .unwrap()
            .is_empty());
        for relative in [
            "Drawings/missing.excalidraw.json",
            "Books/other.json",
            "Drawings/../../outside.json",
        ] {
            store
                .mutate(|library| {
                    library.books.get_mut(&session.book_id).unwrap().annotations[0].sketches[0]
                        ["scenePath"] = json!(relative);
                    Ok(())
                })
                .unwrap();
            assert!(read(&store, &session).is_err(), "{relative}");
        }
        assert!(save(&mut store, &session, json!({"elements":[]}), None).is_err());
    }
}
