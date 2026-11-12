use kodi_reader_core::*;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Cursor, Read, Write};
use std::path::Path;
use tempfile::TempDir;
use zip::{write::FileOptions, ZipArchive, ZipWriter};

fn epub(path: &Path, ncx: bool) {
    let mut writer = ZipWriter::new(fs::File::create(path).unwrap());
    let mut entries = vec![
        ("mimetype", "application/epub+zip".to_owned()),
        ("META-INF/container.xml", r#"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#.to_owned()),
        ("OPS/package.opf", format!(r#"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>A &amp; B</dc:title><dc:creator>Jane Doe</dc:creator><dc:identifier>same-id</dc:identifier></metadata><manifest><item id="one" href="Text/one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="Text/two.xhtml" media-type="application/xhtml+xml"/><item id="cover" href="Images/cover.svg" media-type="image/svg+xml" properties="cover-image"/>{}</manifest><spine toc="ncx" page-progression-direction="rtl"><itemref idref="one"/><itemref idref="two"/><itemref idref="cover" linear="no"/></spine></package>"#, if ncx { r#"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"# } else { r#"<item id="nav" href="navigation.xhtml" media-type="application/xhtml+xml" properties="nav"/>"# })),
        ("OPS/Text/one.xhtml", r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head><body><p id="first">Hello 😀 reader.</p></body></html>"#.to_owned()),
        ("OPS/Text/two.xhtml", r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title></head><body><p>Another chapter.</p></body></html>"#.to_owned()),
        ("OPS/Images/cover.svg", r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>"#.to_owned()),
    ];
    entries.push(if ncx {
        ("OPS/toc.ncx", r#"<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint id="a"><navLabel><text>Chapter One</text></navLabel><content src="Text/one.xhtml#first"/><navPoint id="b"><navLabel><text>Chapter Two</text></navLabel><content src="Text/two.xhtml"/></navPoint></navPoint></navMap></ncx>"#.into())
    } else {
        ("OPS/navigation.xhtml", r#"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Navigation</title></head><body><nav epub:type="toc"><ol><li><a href="Text/one.xhtml#first">Chapter One</a><ol><li><a href="Text/two.xhtml">Chapter Two</a></li></ol></li></ol></nav></body></html>"#.into())
    });
    for (name, content) in entries {
        writer.start_file(name, FileOptions::default()).unwrap();
        writer.write_all(content.as_bytes()).unwrap();
    }
    writer.finish().unwrap();
}

fn imported() -> (TempDir, LibraryStore, Book) {
    let directory = TempDir::new().unwrap();
    let source = directory.path().join("source.epub");
    epub(&source, false);
    let mut store = LibraryStore::open(directory.path().join("library")).unwrap();
    let book = store.import_document(source).unwrap();
    (directory, store, book)
}

#[test]
fn imports_immutable_original_and_parses_navigation_cover_and_resources() {
    let (directory, store, book) = imported();
    assert!(book.id.starts_with("epub-sha256:"));
    assert_eq!(book.title, "A & B");
    assert_eq!(book.author, "Jane Doe");
    let publication = store.publication(&book.id).unwrap();
    assert_eq!(publication.reading_order.len(), 2);
    assert_eq!(publication.reading_order[0].href, "OPS/Text/one.xhtml");
    assert_eq!(
        publication.reading_order[0].title.as_deref(),
        Some("Chapter One")
    );
    assert_eq!(publication.toc[0].children[0].title, "Chapter Two");
    assert_eq!(publication.page_progression, "rtl");
    assert!(store.root().join(book.cover_path.unwrap()).exists());
    assert_eq!(
        fs::read(directory.path().join("source.epub")).unwrap(),
        fs::read(store.document_path(&book.id).unwrap()).unwrap()
    );
    fs::remove_file(directory.path().join("source.epub")).unwrap();
    let resource = store.resource(&book.id, "ops/text/one.xhtml").unwrap();
    assert_eq!(resource.media_type, "application/xhtml+xml");
    assert!(String::from_utf8(resource.bytes).unwrap().contains("😀"));
}

#[test]
fn content_hash_distinguishes_editions_but_reimport_keeps_reading_data() {
    let (directory, mut store, book) = imported();
    let note = Annotation::new(Locator::default(), "Hello 😀 reader.".into());
    let saved = store.upsert_annotation(&book.id, note.clone()).unwrap();
    let renamed = directory.path().join("different-name.epub");
    fs::copy(directory.path().join("source.epub"), &renamed).unwrap();
    let duplicate = store.import_document(&renamed).unwrap();
    assert_eq!(duplicate.id, book.id);
    assert_eq!(duplicate.annotations, saved.annotations);
    let other = Article {
        title: "Different edition".into(),
        author: "Jane Doe".into(),
        source_url: "https://example.org/reading".into(),
        html: "<p>Different contents.</p>".into(),
        images: vec![],
    };
    let different = store.import_article(&other).unwrap();
    assert_ne!(different.id, book.id);
    assert_eq!(store.snapshot().books.len(), 2);
}

#[test]
fn removing_and_reimporting_a_download_preserves_reading_data_and_restores_availability() {
    let (directory, mut store, book) = imported();
    let note = Annotation::new(Locator::default(), "A saved passage".into());
    store.upsert_annotation(&book.id, note.clone()).unwrap();
    store.rename_book(&book.id, "My title").unwrap();
    let before = store.book(&book.id).unwrap().clone();
    let original_path = store.document_path(&book.id).unwrap();
    let removed = store.remove_local_download(&book.id).unwrap();
    assert!(!original_path.exists());
    assert_eq!(removed.extra["offlineAvailable"], json!(false));
    assert_eq!(removed.annotations, before.annotations);
    assert_eq!(removed.title, "My title");
    let restored = store
        .import_document(directory.path().join("source.epub"))
        .unwrap();
    assert_eq!(restored.extra["offlineAvailable"], json!(true));
    assert_eq!(restored.annotations, before.annotations);
    assert_eq!(restored.title, before.title);
    assert_eq!(restored.added_at, before.added_at);
    assert_eq!(restored.last_opened_at, before.last_opened_at);
    assert_eq!(
        fs::read(&original_path).unwrap(),
        fs::read(directory.path().join("source.epub")).unwrap()
    );
}

#[test]
fn keep_data_removal_hides_only_locally_and_reimport_restores_all_reading_data() {
    let (directory, mut store, book) = imported();
    let mut note = Annotation::new(Locator::default(), "Saved passage".into());
    note.note = Some("Keep this thought".into());
    note.sketches = vec![json!({"id":"sketch","scenePath":"Drawings/kept.json"})];
    note.audio_recordings = vec![json!({"id":"audio","path":"Audio/kept.m4a"})];
    fixture_asset(store.root(), "Drawings/kept.json");
    fixture_asset(store.root(), "Audio/kept.m4a");
    store.upsert_annotation(&book.id, note).unwrap();
    store
        .update_book(&book.id, |book| {
            book.position = Some(Locator::default());
            book.reading_marker = Some(Locator::default());
            book.progress = 0.4;
            book.bookmarks = serde_json::from_value(json!([{"id":"mark","title":"Saved","locator":Locator::default(),"createdAt":12.}]))?;
            book.reminders = serde_json::from_value(json!([{"id":"task","title":"Research","locator":Locator::default(),"completed":false,"createdAt":12.,"modifiedAt":13.}]))?;
            book.chats = serde_json::from_value(json!([{"id":"chat","title":"Question","messages":[{"role":"assistant","text":"Saved reply"}],"createdAt":12.,"modifiedAt":13.}]))?;
            book.extra.insert("cloudFile".into(), json!({"hash":"kept-manifest"}));
            Ok(())
        })
        .unwrap();
    let before = store.book(&book.id).unwrap().clone();
    let mut expected = before.clone();
    expected
        .extra
        .insert("offlineAvailable".into(), json!(false));
    expected
        .extra
        .insert("removedFromLibrary".into(), json!(true));
    let removed = store.remove_from_library(&book.id).unwrap();
    assert_eq!(removed, expected);
    assert!(!store.root().join(&book.imported_relative_path).exists());
    assert!(store.root().join("Drawings/kept.json").is_file());
    assert!(store.root().join("Audio/kept.m4a").is_file());
    assert_eq!(
        LibraryStore::open(store.root().to_path_buf())
            .unwrap()
            .book(&book.id)
            .unwrap(),
        &expected
    );
    let restored = store
        .import_document(directory.path().join("source.epub"))
        .unwrap();
    expected
        .extra
        .insert("offlineAvailable".into(), json!(true));
    expected.extra.remove("removedFromLibrary");
    assert_eq!(restored, expected);

    // A hidden record with bytes already present must also become visible.
    store
        .update_book(&book.id, |book| {
            book.extra.insert("removedFromLibrary".into(), json!(true));
            Ok(())
        })
        .unwrap();
    assert_eq!(
        store
            .import_document(directory.path().join("source.epub"))
            .unwrap(),
        expected
    );
}

#[test]
fn reimport_repairs_a_corrupt_original_and_preserves_its_damaged_bytes() {
    let (directory, mut store, book) = imported();
    let path = store.document_path(&book.id).unwrap();
    fs::write(&path, b"damaged local copy").unwrap();
    let restored = store
        .import_document(directory.path().join("source.epub"))
        .unwrap();
    assert_eq!(restored.id, book.id);
    assert_eq!(
        fs::read(&path).unwrap(),
        fs::read(directory.path().join("source.epub")).unwrap()
    );
    let preserved = fs::read_dir(store.root().join("Books"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .contains(".corrupt-")
        })
        .unwrap();
    assert_eq!(fs::read(preserved).unwrap(), b"damaged local copy");
}

#[test]
fn failed_download_removal_metadata_commit_never_deletes_the_original() {
    let (_directory, mut store, book) = imported();
    let before = store.snapshot();
    let original = store.document_path(&book.id).unwrap();
    let bytes = fs::read(&original).unwrap();
    fs::remove_file(store.root().join("library.json")).unwrap();
    fs::create_dir(store.root().join("library.json")).unwrap();
    assert!(store.remove_from_library(&book.id).is_err());
    assert_eq!(store.snapshot(), before);
    assert_eq!(fs::read(original).unwrap(), bytes);
}

fn fixture_asset(root: &Path, relative: &str) {
    let path = root.join(relative);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, relative.as_bytes()).unwrap();
}

#[test]
fn full_delete_cleans_owned_assets_and_orphans_but_preserves_shared_and_unrelated_files() {
    let (_directory, mut store, book) = imported();
    let other = store
        .import_article(&Article {
            title: "Another document".into(),
            author: "Writer".into(),
            source_url: "https://example.org/another".into(),
            html: "<p>A different book.</p>".into(),
            images: vec![],
        })
        .unwrap();
    let root = store.root().to_path_buf();
    let drawing_owner = hex::encode(book.id.as_bytes());
    let audio_owner = hex::encode(Sha256::digest(book.id.as_bytes()));
    let scene = format!("Drawings/{drawing_owner}/note/scene.excalidraw.json");
    let preview = format!("Drawings/{drawing_owner}/note/scene.png");
    let shared_scene = format!("Drawings/{drawing_owner}/note/shared.excalidraw.json");
    let orphan_scene = format!("Drawings/{drawing_owner}/old/orphan.json");
    let future_shared = format!("Drawings/{drawing_owner}/old/future.json");
    let audio = format!("Audio/{audio_owner}/note/recording.m4a");
    let shared_audio = format!("Audio/{audio_owner}/note/shared.m4a");
    let orphan_audio = format!("Audio/{audio_owner}/old/orphan.m4a");
    let backup = format!("Books/{}.corrupt-fixture", book.id.replace(':', "-"));
    let orphan_cover = format!("Covers/{}.png", book.id.replace(':', "-"));
    let protected = "Models/protected.onnx";
    let unrelated = "Covers/unrelated.svg";
    for path in [
        &scene,
        &preview,
        &shared_scene,
        &orphan_scene,
        &future_shared,
        &audio,
        &shared_audio,
        &orphan_audio,
        &backup,
        &orphan_cover,
        protected,
        unrelated,
    ] {
        fixture_asset(&root, path);
    }
    let mut note = Annotation::new(Locator::default(), "Removed note".into());
    note.sketches = vec![
        json!({"scenePath": scene, "previewPath": preview}),
        json!({"scenePath": shared_scene}),
        json!({"scenePath": protected}),
        json!({"scenePath": "Drawings/../../library.json"}),
    ];
    note.audio_recordings = vec![
        json!({"path": audio}),
        json!({"path": shared_audio}),
        json!({"path": unrelated}),
    ];
    store.upsert_annotation(&book.id, note).unwrap();
    let mut kept_note = Annotation::new(Locator::default(), "Kept note".into());
    kept_note.sketches = vec![json!({"scenePath": shared_scene})];
    kept_note.audio_recordings = vec![json!({"path": shared_audio})];
    kept_note
        .extra
        .insert("futureAsset".into(), json!(future_shared));
    store.upsert_annotation(&other.id, kept_note).unwrap();
    store
        .update_book(&other.id, |other| {
            other.cover_path = book.cover_path.clone();
            Ok(())
        })
        .unwrap();
    assert!(store.delete_book(&book.id).unwrap().is_empty());
    assert!(!store.snapshot().books.contains_key(&book.id));
    assert!(LibraryStore::open(root.clone())
        .unwrap()
        .book(&book.id)
        .is_err());
    for path in [
        &book.imported_relative_path,
        &scene,
        &preview,
        &orphan_scene,
        &audio,
        &orphan_audio,
        &backup,
        &orphan_cover,
    ] {
        assert!(!root.join(path).exists(), "owned asset was kept: {path}");
    }
    for path in [
        &other.imported_relative_path,
        book.cover_path.as_ref().unwrap(),
        &shared_scene,
        &shared_audio,
        &future_shared,
        protected,
        unrelated,
        "library.json",
    ] {
        assert!(
            root.join(path).is_file(),
            "shared/unrelated asset lost: {path}"
        );
    }
}

#[test]
fn failed_full_delete_metadata_commit_never_deletes_original_cover_or_sidecars() {
    let (_directory, mut store, book) = imported();
    let scene = format!(
        "Drawings/{}/note/scene.excalidraw.json",
        hex::encode(book.id.as_bytes())
    );
    fixture_asset(store.root(), &scene);
    let mut note = Annotation::new(Locator::default(), "Saved note".into());
    note.sketches = vec![json!({"scenePath": scene})];
    store.upsert_annotation(&book.id, note).unwrap();
    let before = store.snapshot();
    let originals =
        [book.imported_relative_path, book.cover_path.unwrap(), scene].map(|relative| {
            let path = store.root().join(relative);
            let bytes = fs::read(&path).unwrap();
            (path, bytes)
        });
    fs::remove_file(store.root().join("library.json")).unwrap();
    fs::create_dir(store.root().join("library.json")).unwrap();
    assert!(store.delete_book(&book.id).is_err());
    assert_eq!(store.snapshot(), before);
    for (path, bytes) in originals {
        assert_eq!(fs::read(path).unwrap(), bytes);
    }
}

#[cfg(unix)]
#[test]
fn full_delete_preserves_remaining_references_through_internal_symlinks() {
    use std::os::unix::fs::symlink;
    let (_directory, mut store, book) = imported();
    let other = store
        .import_article(&Article {
            title: "Shared audio".into(),
            author: "Writer".into(),
            source_url: "https://example.org/shared".into(),
            html: "<p>A different book.</p>".into(),
            images: vec![],
        })
        .unwrap();
    let owner = hex::encode(Sha256::digest(book.id.as_bytes()));
    let relative = format!("Audio/{owner}/clip.m4a");
    fixture_asset(store.root(), &relative);
    symlink(
        store.root().join("Audio").join(&owner),
        store.root().join("Audio/shared"),
    )
    .unwrap();
    let mut note = Annotation::new(Locator::default(), "A shared recording".into());
    note.audio_recordings = vec![json!({"path": "Audio/shared/clip.m4a"})];
    store.upsert_annotation(&other.id, note).unwrap();
    assert!(store.delete_book(&book.id).unwrap().is_empty());
    assert!(store.root().join(relative).is_file());
    assert!(store.root().join("Audio/shared/clip.m4a").is_file());
}

#[cfg(unix)]
#[test]
fn full_delete_never_traverses_a_replaced_asset_folder_symlink() {
    use std::os::unix::fs::symlink;
    let (directory, mut store, book) = imported();
    let outside = directory.path().join("outside");
    let empty_owned_directory = outside.join(hex::encode(book.id.as_bytes())).join("empty");
    fs::create_dir_all(&empty_owned_directory).unwrap();
    let sentinel = outside
        .join(hex::encode(book.id.as_bytes()))
        .join("scene.json");
    fs::write(&sentinel, b"outside bytes").unwrap();
    fs::remove_dir(store.root().join("Drawings")).unwrap();
    symlink(&outside, store.root().join("Drawings")).unwrap();
    assert!(store.delete_book(&book.id).unwrap().is_empty());
    assert_eq!(fs::read(sentinel).unwrap(), b"outside bytes");
    assert!(empty_owned_directory.is_dir());
}

#[test]
fn reads_epub2_nested_ncx() {
    let directory = TempDir::new().unwrap();
    let source = directory.path().join("old.epub");
    epub(&source, true);
    let mut store = LibraryStore::open(directory.path().join("library")).unwrap();
    let book = store.import_document(source).unwrap();
    let publication = store.publication(&book.id).unwrap();
    assert_eq!(publication.toc[0].href, "OPS/Text/one.xhtml#first");
    assert_eq!(publication.toc[0].children[0].href, "OPS/Text/two.xhtml");
}

#[test]
fn archive_path_normalization_blocks_traversal_windows_paths_and_encoded_roots() {
    for path in [
        "../secret",
        "%2e%2e/secret",
        "%2fetc/passwd",
        "C:/Windows/system.ini",
        "foo\\bar",
        "a/%00b",
        "//server/share",
    ] {
        assert!(normalize_archive_path(path).is_err(), "accepted {path}");
    }
    assert_eq!(
        resolve_archive_href("OPS/nav/toc.xhtml", "../Text/one%20two.xhtml#part").unwrap(),
        "OPS/Text/one%20two.xhtml#part"
    );
    let (_, store, book) = imported();
    assert!(store.resource(&book.id, "../../library.json").is_err());
    assert!(store
        .resource(&book.id, "META-INF/../../library.json")
        .is_err());
}

#[test]
fn rejects_unsafe_zip_entries_before_any_import_is_committed() {
    let directory = TempDir::new().unwrap();
    let source = directory.path().join("bad.epub");
    let mut writer = ZipWriter::new(fs::File::create(&source).unwrap());
    writer
        .start_file("../library.json", FileOptions::default())
        .unwrap();
    writer.write_all(b"evil").unwrap();
    writer.finish().unwrap();
    let mut store = LibraryStore::open(directory.path().join("library")).unwrap();
    assert!(matches!(
        store.import_document(source),
        Err(Error::UnsafePath(_))
    ));
    assert!(store.snapshot().books.is_empty());
}

#[test]
fn mutation_is_durable_and_path_injection_is_rejected_or_stripped() {
    let (_directory, mut store, book) = imported();
    let previous = store.snapshot();
    assert!(store
        .mutate(|library| {
            library
                .books
                .get_mut(&book.id)
                .unwrap()
                .imported_relative_path = "../../secret".into();
            Ok(())
        })
        .is_err());
    assert_eq!(store.snapshot(), previous);
    let mut changed = book.clone();
    changed.imported_relative_path = "/etc/passwd".into();
    changed.cover_path = Some("../../secret".into());
    changed.title = "New title".into();
    let saved = store.save_book(changed).unwrap();
    assert_eq!(saved.imported_relative_path, book.imported_relative_path);
    assert_eq!(saved.cover_path, book.cover_path);
    let reopened = LibraryStore::open(store.root().to_path_buf()).unwrap();
    assert_eq!(reopened.book(&book.id).unwrap().title, "New title");
}

#[test]
fn failed_disk_commit_does_not_change_memory() {
    let (_directory, mut store, book) = imported();
    let original = store.snapshot();
    fs::remove_file(store.root().join("library.json")).unwrap();
    fs::create_dir(store.root().join("library.json")).unwrap();
    assert!(store.rename_book(&book.id, "Failed write").is_err());
    assert_eq!(store.snapshot(), original);
}

#[test]
fn corrupt_primary_recovers_last_good_backup_and_preserves_corrupt_bytes() {
    let (_directory, mut store, book) = imported();
    store.rename_book(&book.id, "First title").unwrap();
    store.rename_book(&book.id, "Latest title").unwrap();
    fs::write(store.root().join("library.json"), b"{truncated").unwrap();
    let reopened = LibraryStore::open(store.root().to_path_buf()).unwrap();
    assert_eq!(reopened.book(&book.id).unwrap().title, "First title");
    match reopened.recovery_status() {
        RecoveryStatus::RecoveredBackup {
            preserved_corrupt_file: Some(path),
        } => assert_eq!(fs::read(path).unwrap(), b"{truncated"),
        status => panic!("unexpected recovery {status:?}"),
    }
}

#[test]
fn unreadable_library_and_future_schema_never_start_empty() {
    let directory = TempDir::new().unwrap();
    let root = directory.path().join("library");
    let store = LibraryStore::open(root.clone()).unwrap();
    fs::write(root.join("library.json"), b"broken").unwrap();
    fs::write(root.join("library.backup.json"), b"broken backup").unwrap();
    assert!(matches!(
        LibraryStore::open(root.clone()),
        Err(Error::CorruptLibrary(_))
    ));
    let mut future = serde_json::to_value(store.snapshot()).unwrap();
    future["schemaVersion"] = json!(LIBRARY_SCHEMA_VERSION + 1);
    fs::write(
        root.join("library.json"),
        serde_json::to_vec(&future).unwrap(),
    )
    .unwrap();
    assert!(matches!(
        LibraryStore::open(root),
        Err(Error::UnsupportedSchema { .. })
    ));
}

#[test]
fn unknown_fields_and_pdf_legacy_ranges_roundtrip_losslessly() {
    let mut annotation: Annotation = serde_json::from_value(json!({"id":"note","locator":{"kind":"pdf","spineIndex":0,"start":{"elementPath":[],"offset":7},"pdfRanges":[{"pageIndex":0,"location":7,"length":4}],"pdfAnchors":{"quads":[[0.1,0.2,0.4,0.2,0.4,0.3,0.1,0.3]]}},"text":"text","createdAt":1234.5,"modifiedAt":1234.5,"color":"yellow","futureFeature":{"nested":true}})).unwrap();
    annotation.note = Some("A note".into());
    let value = serde_json::to_value(annotation).unwrap();
    assert_eq!(value["futureFeature"]["nested"], true);
    assert_eq!(value["locator"]["pdfRanges"][0]["location"], 7);
    assert!(value["locator"]["pdfAnchors"].is_object());
}

#[test]
fn reminders_survive_note_removal_and_goals_work_offline() {
    let (_directory, mut store, book) = imported();
    let note = Annotation::new(Locator::default(), "Quote".into());
    store.upsert_annotation(&book.id, note.clone()).unwrap();
    let reminder = Reminder {
        id: "reminder".into(),
        locator: Locator::default(),
        title: "Research this".into(),
        completed: false,
        created_at: now(),
        modified_at: now(),
        annotation_id: Some(note.id.clone()),
        extra: Extra::new(),
    };
    store.upsert_reminder(&book.id, reminder).unwrap();
    store.delete_annotation(&book.id, &note.id).unwrap();
    assert_eq!(store.book(&book.id).unwrap().reminders.len(), 1);
    store.add_reading_seconds("2026-11-10", 600).unwrap();
    assert!(!store.goal_reached("2026-11-10"));
    store.add_reading_seconds("2026-11-10", 600).unwrap();
    assert!(store.goal_reached("2026-11-10"));
    store
        .mutate(|library| {
            library.goal_minutes = 60;
            Ok(())
        })
        .unwrap();
    assert!(
        store.goal_reached("2026-11-10"),
        "raising goal cannot remove an earned day"
    );
    assert_eq!(store.reading_streak("2026-11-11"), 1);
    assert!(store.add_reading_seconds("2026-02-30", 1).is_err());
    let reopened = LibraryStore::open(store.root().to_path_buf()).unwrap();
    assert!(reopened.goal_reached("2026-11-10"));
}

#[test]
fn article_builder_creates_complete_offline_epub_with_image() {
    let directory = TempDir::new().unwrap();
    let article = Article {
        title: "A local article".into(),
        author: "Writer".into(),
        source_url: "https://example.org/article".into(),
        html: "<p>Article text.</p><img src=\"images/picture.svg\"/>".into(),
        images: vec![ArticleImage {
            path: "images/picture.svg".into(),
            media_type: "image/svg+xml".into(),
            bytes: b"<svg xmlns=\"http://www.w3.org/2000/svg\"/>".to_vec(),
        }],
    };
    let mut store = LibraryStore::open(directory.path().join("library")).unwrap();
    let book = store.import_article(&article).unwrap();
    assert_eq!(book.title, article.title);
    assert_eq!(
        book.source_url.as_deref(),
        Some(article.source_url.as_str())
    );
    assert_eq!(
        store.publication(&book.id).unwrap().reading_order[0].href,
        "EPUB/article.xhtml"
    );
    assert!(!store
        .resource(&book.id, "EPUB/images/picture.svg")
        .unwrap()
        .bytes
        .is_empty());
    let mut archive = ZipArchive::new(Cursor::new(build_article_epub(&article).unwrap())).unwrap();
    assert_eq!(archive.by_index(0).unwrap().name(), "mimetype");
}

#[test]
fn exports_markdown_html_and_real_docx_with_sidecar_assets() {
    let (directory, mut store, book) = imported();
    let id = uuid::Uuid::new_v4().to_string();
    fs::write(
        store.root().join("Audio/recording.m4a"),
        b"fake recording fixture",
    )
    .unwrap();
    let mut note = Annotation::new(Locator::default(), "Referenced passage".into());
    note.chapter_title = Some("Chapter One".into());
    note.note = Some(format!(
        "**Bold thought** and *emphasis*.\n\n[Source link](https://example.org/source)\n\n| Idea | Status |\n| --- | --- |\n| Offline | Kept |\n\n<script>alert(1)</script>\n\n[Listen](kodi-audio://{id})"
    ));
    note.audio_recordings.push(json!({"id":id,"title":"A thought","path":"Audio/recording.m4a","transcript":"Offline transcript"}));
    store.upsert_annotation(&book.id, note.clone()).unwrap();
    for (format, extension) in [
        (ExportFormat::Markdown, "md"),
        (ExportFormat::Notion, "notion.md"),
        (ExportFormat::Html, "html"),
        (ExportFormat::Docx, "docx"),
    ] {
        let path = directory.path().join(format!("notes.{extension}"));
        let result = store
            .export_notes(&book.id, Some(&note.id), &path, format)
            .unwrap();
        assert_eq!(result.annotation_count, 1);
        assert!(result.assets_directory.unwrap().read_dir().unwrap().count() > 0);
        if format == ExportFormat::Docx {
            let mut archive = ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
            let mut document = String::new();
            archive
                .by_name("word/document.xml")
                .unwrap()
                .read_to_string(&mut document)
                .unwrap();
            assert!(document.contains("Referenced passage"));
            assert!(document.contains("Offline transcript"));
            assert!(
                document.contains("<w:b/>")
                    && document.contains("<w:i/>")
                    && document.contains("<w:tbl>")
            );
            let mut xml = quick_xml::Reader::from_str(&document);
            loop {
                if matches!(
                    xml.read_event().expect("DOCX XML must be well formed"),
                    quick_xml::events::Event::Eof
                ) {
                    break;
                }
            }
            let mut relationships = String::new();
            archive
                .by_name("word/_rels/document.xml.rels")
                .unwrap()
                .read_to_string(&mut relationships)
                .unwrap();
            assert!(relationships.contains("https://example.org/source"));
            assert!(archive.by_name("[Content_Types].xml").is_ok());
        } else {
            let text = fs::read_to_string(path).unwrap();
            assert!(text.contains("Referenced passage"));
            assert!(text.contains("Offline transcript"));
            assert!(!text.contains("kodi-audio://"));
            if format == ExportFormat::Html {
                assert!(!text.contains("<script>"));
                assert!(text.contains("&lt;script&gt;"));
            }
        }
    }
}

#[test]
fn imports_and_reads_pdf_metadata_and_pages_without_modifying_pdf() {
    use lopdf::{dictionary, Document, Object, Stream};
    let directory = TempDir::new().unwrap();
    let path = directory.path().join("sample.pdf");
    let mut document = Document::with_version("1.5");
    let pages_id = document.new_object_id();
    let content = document.add_object(Stream::new(dictionary! {}, b"".to_vec()));
    let page = document.add_object(dictionary! {"Type"=>"Page","Parent"=>pages_id,"Contents"=>content,"MediaBox"=>vec![0.into(),0.into(),600.into(),800.into()]});
    document.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {"Type"=>"Pages","Kids"=>vec![page.into()],"Count"=>1}),
    );
    let catalog = document.add_object(dictionary! {"Type"=>"Catalog","Pages"=>pages_id});
    let info = document.add_object(dictionary! {"Title"=>Object::string_literal("PDF Title"),"Author"=>Object::string_literal("PDF Author")});
    document.trailer.set("Root", catalog);
    document.trailer.set("Info", info);
    document.save(&path).unwrap();
    let bytes = fs::read(&path).unwrap();
    let mut store = LibraryStore::open(directory.path().join("library")).unwrap();
    let book = store.import_document(&path).unwrap();
    assert_eq!(book.kind, DocumentKind::Pdf);
    assert_eq!(book.title, "PDF Title");
    assert_eq!(book.author, "PDF Author");
    assert_eq!(store.publication(&book.id).unwrap().reading_order.len(), 1);
    assert_eq!(
        fs::read(store.document_path(&book.id).unwrap()).unwrap(),
        bytes
    );
}
