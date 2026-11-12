//! Explicit schema-1 projection. Local desktop dates/paths never leak onto the Mac wire.
use crate::{
    hub::ServiceHub,
    sync::{self, BlobManifest, DriveJournal, DriveTransport, SyncEntity, APPLE_EPOCH_OFFSET},
};
use anyhow::{bail, Context, Result};
use serde_json::{json, Map, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
};

pub struct PreparedLibrarySync {
    pub library: Value,
    pub journal: DriveJournal,
    root: PathBuf,
    transport: DriveTransport,
}
const READING_MARKER_ID: &str = "00000000-0000-5000-8000-000000000001";
impl PreparedLibrarySync {
    /// The shell must persist `library` successfully before calling this method.
    pub async fn commit(mut self) -> Result<()> {
        self.journal.save(&self.root)?;
        self.transport
            .send_pending(&mut self.journal, &self.root)
            .await
    }
}
fn fields(value: &Value, keys: &[&str]) -> Value {
    let mut m = Map::new();
    for key in keys {
        if let Some(v) = value.get(*key) {
            if !v.is_null() {
                m.insert((*key).into(), v.clone());
            }
        }
    }
    Value::Object(m)
}
fn uppercase_ids(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, v) in map.iter_mut() {
                if ["id", "annotationID", "recoveredFrom"].contains(&key.as_str()) {
                    if let Some(s) = v.as_str() {
                        if let Ok(id) = uuid::Uuid::parse_str(s) {
                            *v = json!(id.to_string().to_uppercase());
                        }
                    }
                } else {
                    uppercase_ids(v);
                }
            }
        }
        Value::Array(items) => {
            for v in items {
                uppercase_ids(v);
            }
        }
        _ => {}
    }
}
fn dates(value: &mut Value, offset: f64) {
    match value {
        Value::Object(map) => {
            for (key, value) in map {
                if [
                    "createdAt",
                    "modifiedAt",
                    "updatedAt",
                    "completedAt",
                    "lastOpenedAt",
                    "addedAt",
                ]
                .contains(&key.as_str())
                {
                    if let Some(n) = value.as_f64() {
                        *value = json!(n + offset);
                    }
                } else {
                    dates(value, offset);
                }
            }
        }
        Value::Array(items) => {
            for value in items {
                dates(value, offset);
            }
        }
        _ => {}
    }
}
fn locator(value: &Value) -> Value {
    fields(
        value,
        &[
            "kind",
            "spineIndex",
            "start",
            "end",
            "totalProgression",
            "text",
            "pdfRanges",
        ],
    )
}

fn book_metadata(book: &Value) -> Value {
    // Device visibility and availability are deliberately local. Keep this
    // allowlist independent of Book's forward-compatible flattened fields.
    let mut metadata = fields(book, &["title", "author", "kind", "addedAt"]);
    if let Some(source) = book["sourceUrl"]
        .as_str()
        .or_else(|| book["sourceURL"].as_str())
    {
        if let Ok(url) = url::Url::parse(source) {
            if ["http", "https"].contains(&url.scheme()) {
                metadata["sourceURL"] = json!(source);
            }
        }
    }
    metadata
}
fn is_local_pdf(value: &Value) -> bool {
    value["locator"].get("pdfAnchors").is_some() || value["locator"].get("pdfGeometry").is_some()
}
fn id(value: &Value) -> Result<String> {
    let s = value["id"].as_str().context("A synced record has no ID")?;
    Ok(uuid::Uuid::parse_str(s)?.to_string().to_uppercase())
}
fn entity(
    book: &str,
    kind: &str,
    key: &str,
    mut body: Value,
    device: &str,
    old: Option<&SyncEntity>,
) -> Result<SyncEntity> {
    uppercase_ids(&mut body);
    dates(&mut body, -APPLE_EPOCH_OFFSET);
    let mut e = SyncEntity::from_body(book, kind, key, &body, device)?;
    if let Some(old) = old {
        if !old.deleted && old.body == e.body {
            e = old.clone();
        }
    }
    Ok(e)
}
fn safe_path(root: &Path, relative: &str) -> Result<PathBuf> {
    let p = Path::new(relative);
    if p.is_absolute()
        || p.components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
    {
        bail!("A media path escapes the local library");
    }
    let out = root.join(p);
    if out.exists() && !out.canonicalize()?.starts_with(root.canonicalize()?) {
        bail!("A media path escapes the local library");
    }
    Ok(out)
}
fn local_body(mut value: Value) -> Value {
    dates(&mut value, APPLE_EPOCH_OFFSET);
    value
}
fn imported_book_path(id: &str, kind: &str) -> Result<String> {
    let prefix = format!("{kind}-sha256:");
    if !["epub", "pdf"].contains(&kind)
        || !id.starts_with(&prefix)
        || id.len() != prefix.len() + 64
        || !id[prefix.len()..]
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        bail!("Cloud document identity is invalid");
    }
    Ok(format!("Books/{}.{}", id.replace(':', "-"), kind))
}
fn chat_reference(reference: &Value, message_id: &str, index: usize) -> Value {
    let mut wire = fields(
        reference,
        &[
            "id",
            "quotedText",
            "chapterTitle",
            "spineIndex",
            "contextBefore",
            "contextAfter",
        ],
    );
    if wire["id"]
        .as_str()
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
        .is_none()
    {
        use sha2::{Digest, Sha256};
        let digest = Sha256::digest(format!("chat-reference:{message_id}:{index}").as_bytes());
        wire["id"] = json!(uuid::Uuid::from_bytes(digest[..16].try_into().unwrap())
            .to_string()
            .to_uppercase());
    }
    if wire["quotedText"].is_null() {
        wire["quotedText"] = reference
            .get("text")
            .or_else(|| reference.get("quote"))
            .cloned()
            .unwrap_or(json!(""));
    }
    if wire["spineIndex"].is_null() {
        wire["spineIndex"] = reference["locator"]
            .get("spineIndex")
            .cloned()
            .unwrap_or(json!(0));
    }
    wire
}

impl ServiceHub {
    /// Capture local mutations, reconcile remote heads, and hydrate note media.
    /// This returns an uncommitted library snapshot; no fetch cursor is saved yet.
    pub async fn prepare_sync(
        &self,
        mut library: Value,
        mode: &str,
        ai_enabled: bool,
    ) -> Result<PreparedLibrarySync> {
        if mode != "notesOnly" && mode != "booksAndNotes" {
            bail!("Choose Notes only or Books and notes before syncing");
        }
        let editing: BTreeSet<String> = library["desktopEditingBookIds"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect();
        if let Some(map) = library.as_object_mut() {
            map.remove("desktopEditingBookIds");
        }
        let transport = self.drive_transport().await?;
        let account = transport.account().await?;
        let root = self.data_root().join("Sync");
        let device = library["deviceId"]
            .as_str()
            .or_else(|| library["deviceID"].as_str())
            .context("The library has no device identity")?;
        let mut journal = DriveJournal::load(&root, &account.id, device)?;
        let mut current = BTreeMap::<String, SyncEntity>::new();
        let books = library["books"]
            .as_object()
            .context("Invalid library snapshot")?;
        for (book_id, book) in books {
            if book["syncDetached"] == true {
                continue;
            }
            let meta_id = format!("book:{book_id}:metadata");
            let previous = journal
                .base
                .get(&meta_id)
                .or_else(|| journal.pending.get(&meta_id))
                .filter(|e| !e.deleted)
                .and_then(|e| e.value().ok());
            let mut metadata = book_metadata(book);
            if let Some(manifest) = previous.as_ref().and_then(|v| v.get("file")) {
                metadata["file"] = manifest.clone();
            }
            if mode == "booksAndNotes" {
                if let Some(path) = book["importedRelativePath"].as_str() {
                    let path = safe_path(self.data_root(), path)?;
                    if path.is_file() {
                        let manifest = BlobManifest::describe(&path)?;
                        let known = metadata
                            .get("file")
                            .and_then(|v| serde_json::from_value::<BlobManifest>(v.clone()).ok());
                        if known.as_ref().map(|m| (&m.hash, m.size))
                            != Some((&manifest.hash, manifest.size))
                        {
                            metadata["file"] = serde_json::to_value(
                                transport
                                    .upload_blob_cached(&path, &meta_id, None, &root.join("Chunks"))
                                    .await?,
                            )?;
                        }
                    }
                }
            }
            let mut e = entity(
                book_id,
                "book",
                "metadata",
                metadata,
                device,
                journal.base.get(&meta_id),
            )?;
            if let Some(file) = previous.and_then(|v| v.get("file").cloned()) {
                let mut body = e.value()?;
                if body.get("file").is_none() {
                    body["file"] = file;
                    e.body = sync::swift_json(&body)?;
                }
            }
            current.insert(e.id.clone(), e);
            let position_id = format!("position:{book_id}:position");
            let mut position = json!({"progress":book["progress"].as_f64().unwrap_or(0.),"lastOpenedAt":book["lastOpenedAt"].as_f64().unwrap_or(crate::now()as f64)});
            if !book["position"].is_null() {
                position["locator"] = locator(&book["position"]);
            }
            let e = entity(
                book_id,
                "position",
                "position",
                position,
                device,
                journal.base.get(&position_id),
            )?;
            current.insert(e.id.clone(), e);
            if let Some(marker) = book.get("readingMarker").filter(|v| !v.is_null()) {
                let marker_id = format!("bookmark:{book_id}:{READING_MARKER_ID}");
                let mut body = json!({"id":READING_MARKER_ID,"locator":locator(marker),"createdAt":crate::now()as f64});
                if let Some(old) = journal.base.get(&marker_id).filter(|e| !e.deleted) {
                    let old = old.value()?;
                    if old["locator"] == body["locator"] {
                        body = local_body(old);
                    }
                }
                let marker = entity(
                    book_id,
                    "bookmark",
                    READING_MARKER_ID,
                    body,
                    device,
                    journal.base.get(&marker_id),
                )?;
                current.insert(marker.id.clone(), marker);
            }
            for (kind, collection) in [
                ("annotation", "annotations"),
                ("bookmark", "bookmarks"),
                ("reminder", "reminders"),
                ("chat", "chats"),
            ] {
                if kind == "chat" && !ai_enabled {
                    continue;
                }
                for record in book[collection].as_array().into_iter().flatten() {
                    if is_local_pdf(record) {
                        continue;
                    }
                    let key = id(record)?;
                    let entity_id = format!("{kind}:{book_id}:{key}");
                    let previous = journal
                        .base
                        .get(&entity_id)
                        .or_else(|| journal.pending.get(&entity_id))
                        .filter(|e| !e.deleted)
                        .and_then(|e| e.value().ok());
                    let body = match kind {
                        "annotation" => {
                            let mut note = fields(
                                record,
                                &[
                                    "id",
                                    "text",
                                    "note",
                                    "color",
                                    "chapterTitle",
                                    "createdAt",
                                    "modifiedAt",
                                    "recoveredFrom",
                                ],
                            );
                            note["locator"] = locator(&record["locator"]);
                            note["anchorStatus"] = json!("unknown");
                            let mut scenes = vec![];
                            let mut audio = vec![];
                            let mut sketches = vec![];
                            let mut recordings = vec![];
                            for (media_key, output, metadata_fields) in [
                                (
                                    "sketches",
                                    &mut sketches,
                                    &["id", "title", "createdAt", "modifiedAt"][..],
                                ),
                                (
                                    "audioRecordings",
                                    &mut recordings,
                                    &[
                                        "id",
                                        "title",
                                        "duration",
                                        "createdAt",
                                        "modifiedAt",
                                        "waveform",
                                        "transcript",
                                    ][..],
                                ),
                            ] {
                                for media in record[media_key].as_array().into_iter().flatten() {
                                    let media_id = id(media)?;
                                    let mut info = fields(media, metadata_fields);
                                    info["id"] = json!(media_id);
                                    if info["createdAt"].is_null() {
                                        info["createdAt"] = record["createdAt"].clone();
                                    }
                                    if info["modifiedAt"].is_null() {
                                        info["modifiedAt"] = record["modifiedAt"].clone();
                                    }
                                    let mut asset = json!({"id":media_id});
                                    let old = previous
                                        .as_ref()
                                        .and_then(|p| p[media_key].as_array())
                                        .and_then(|items| {
                                            items.iter().find(|v| {
                                                v["id"]
                                                    .as_str()
                                                    .map(|s| s.eq_ignore_ascii_case(&media_id))
                                                    .unwrap_or(false)
                                            })
                                        });
                                    for (path_key, manifest_key) in if media_key == "sketches" {
                                        vec![("scenePath", "scene"), ("previewPath", "preview")]
                                    } else {
                                        vec![("path", "recording")]
                                    } {
                                        let local = media[path_key]
                                            .as_str()
                                            .map(|p| safe_path(self.data_root(), p))
                                            .transpose()?;
                                        let remembered = old.and_then(|o| o.get(manifest_key));
                                        if let Some(file) = local.filter(|p| p.is_file()) {
                                            let described = BlobManifest::describe(&file)?;
                                            if remembered.and_then(|v| v["hash"].as_str())
                                                == Some(&described.hash)
                                            {
                                                asset[manifest_key] = remembered.unwrap().clone();
                                            } else {
                                                asset[manifest_key] = serde_json::to_value(
                                                    transport
                                                        .upload_blob_cached(
                                                            &file,
                                                            &entity_id,
                                                            None,
                                                            &root.join("Chunks"),
                                                        )
                                                        .await?,
                                                )?;
                                            }
                                        } else if let Some(previous) = remembered {
                                            asset[manifest_key] = previous.clone();
                                        }
                                    }
                                    if media_key == "sketches" {
                                        scenes.push(asset);
                                    } else {
                                        if info["waveform"].is_null() {
                                            info["waveform"] = json!([]);
                                        }
                                        if info["duration"].is_null() {
                                            info["duration"] = json!(0);
                                        }
                                        audio.push(asset);
                                    }
                                    output.push(info);
                                }
                            }
                            note["hasDrawing"] = json!(!sketches.is_empty());
                            note["sketches"] = json!(sketches);
                            note["audioRecordings"] = json!(recordings);
                            let mut body = json!({"annotation":note});
                            if !scenes.is_empty() {
                                body["sketches"] = json!(scenes);
                            }
                            if !audio.is_empty() {
                                body["audioRecordings"] = json!(audio);
                            }
                            body
                        }
                        "bookmark" => {
                            let mut v =
                                fields(record, &["id", "chapterTitle", "excerpt", "createdAt"]);
                            if v["excerpt"].is_null() {
                                if let Some(title) =
                                    record["title"].as_str().filter(|s| !s.is_empty())
                                {
                                    v["excerpt"] = json!(title);
                                }
                            }
                            v["locator"] = locator(&record["locator"]);
                            v
                        }
                        "reminder" => {
                            let mut v = fields(
                                record,
                                &[
                                    "id",
                                    "title",
                                    "source",
                                    "quotedText",
                                    "chapterTitle",
                                    "createdAt",
                                    "modifiedAt",
                                    "completedAt",
                                ],
                            );
                            v["locator"] = locator(&record["locator"]);
                            if let Some(annotation) = record["annotationId"]
                                .as_str()
                                .or_else(|| record["annotationID"].as_str())
                            {
                                v["annotationID"] = json!(annotation);
                            }
                            if v["source"].is_null() {
                                v["source"] = json!(if v.get("annotationID").is_some() {
                                    "note"
                                } else {
                                    "selection"
                                });
                            }
                            if v["quotedText"].is_null() {
                                v["quotedText"] = record["locator"]["text"]
                                    .as_str()
                                    .map(|s| json!(s))
                                    .unwrap_or(json!(""));
                            }
                            if record["completed"] == false {
                                v.as_object_mut().unwrap().remove("completedAt");
                            }
                            if record["completed"] == true && v["completedAt"].is_null() {
                                v["completedAt"] = record["modifiedAt"].clone();
                            }
                            v
                        }
                        "chat" => {
                            let mut v =
                                fields(record, &["id", "title", "createdAt", "recoveredFrom"]);
                            v["updatedAt"] = record
                                .get("modifiedAt")
                                .or_else(|| record.get("updatedAt"))
                                .cloned()
                                .unwrap_or(json!(crate::now()));
                            let mut messages = vec![];
                            for source in record["messages"].as_array().into_iter().flatten() {
                                let mut message = fields(
                                    source,
                                    &["id", "role", "text", "references", "createdAt"],
                                );
                                if message["text"].is_null() {
                                    message["text"] =
                                        source.get("content").cloned().unwrap_or(json!(""));
                                }
                                if message["id"].is_null() {
                                    bail!("A saved chat message has no stable ID");
                                }
                                message["references"] = json!(source["references"]
                                    .as_array()
                                    .into_iter()
                                    .flatten()
                                    .enumerate()
                                    .map(|(index, r)| chat_reference(
                                        r,
                                        message["id"].as_str().unwrap(),
                                        index
                                    ))
                                    .collect::<Vec<_>>());
                                messages.push(message);
                            }
                            v["messages"] = json!(messages);
                            v
                        }
                        _ => unreachable!(),
                    };
                    let e = entity(
                        book_id,
                        kind,
                        &key,
                        body,
                        device,
                        journal.base.get(&entity_id),
                    )?;
                    current.insert(e.id.clone(), e);
                }
            }
        }
        for (id, e) in &current {
            if journal
                .base
                .get(id)
                .map(|old| old.body != e.body || old.deleted)
                .unwrap_or(true)
            {
                journal.pending.insert(id.clone(), e.clone());
            }
        }
        for (id, old) in journal.base.clone() {
            if current.contains_key(&id) || old.deleted || (old.kind == "chat" && !ai_enabled) {
                continue;
            }
            let preserved_local_pdf = books
                .get(&old.book_id)
                .and_then(|b| {
                    b[match old.kind.as_str() {
                        "annotation" => "annotations",
                        "bookmark" => "bookmarks",
                        "reminder" => "reminders",
                        _ => "",
                    }]
                    .as_array()
                })
                .map(|items| {
                    items.iter().any(|v| {
                        self::id(v)
                            .ok()
                            .map(|key| old.id.ends_with(&key))
                            .unwrap_or(false)
                            && is_local_pdf(v)
                    })
                })
                .unwrap_or(false);
            if preserved_local_pdf {
                continue;
            }
            let mut deleted = old;
            deleted.deleted = true;
            deleted.body.clear();
            deleted.modified_at = crate::now() as f64 - APPLE_EPOCH_OFFSET;
            deleted.device_id = device.into();
            journal.pending.insert(id, deleted);
        }
        journal.save(&root)?;
        let batch = transport
            .fetch(&journal, ai_enabled, &root.join("Chunks"))
            .await?;
        let mut journal = batch.journal;
        let mut received = std::mem::take(&mut journal.deferred);
        for entity in batch.received {
            received.retain(|old| old.id != entity.id);
            received.push(entity);
        }
        received.sort_by_key(|e| if e.kind == "book" { 0 } else { 1 });
        for remote in received {
            if editing.contains(&remote.book_id) {
                journal.deferred.push(remote);
                continue;
            }
            let mut resolved = if let Some(local) = journal.pending.get(&remote.id) {
                sync::merge(local, &remote, journal.base.get(&remote.id))?
            } else {
                vec![remote.clone()]
            };
            for value in resolved.drain(..) {
                if value != remote {
                    journal.pending.insert(value.id.clone(), value.clone());
                } else if journal.pending.get(&value.id) == Some(&value) {
                    journal.pending.remove(&value.id);
                }
                if value.kind == "book"
                    && value.deleted
                    && journal
                        .pending
                        .values()
                        .any(|e| e.book_id == value.book_id && e.kind != "book" && !e.deleted)
                {
                    if let Some(book) = library["books"].get_mut(&value.book_id) {
                        book["syncDetached"] = json!(true);
                    }
                    journal.base.insert(value.id.clone(), value);
                    continue;
                }
                apply(&transport, self.data_root(), &mut library, &value, mode).await?;
                journal.base.insert(value.id.clone(), value);
            }
        }
        Ok(PreparedLibrarySync {
            library,
            journal,
            root,
            transport,
        })
    }
    pub async fn download_synced_book(&self, book: &Value) -> Result<String> {
        let manifest: BlobManifest = serde_json::from_value(book["cloudFile"].clone())
            .context("This book has no cloud download")?;
        let book_id = book["id"].as_str().context("Missing book identity")?;
        let kind = if book["kind"] == "pdf" { "pdf" } else { "epub" };
        let relative = imported_book_path(book_id, kind)?;
        let destination = self.data_root().join(&relative);
        self.drive_transport()
            .await?
            .download_blob(
                &manifest,
                &format!("book:{book_id}:metadata"),
                &self.data_root().join("Sync/Chunks"),
                &destination,
            )
            .await?;
        Ok(relative)
    }
}
async fn apply(
    transport: &DriveTransport,
    root: &Path,
    library: &mut Value,
    entity: &SyncEntity,
    _mode: &str,
) -> Result<()> {
    let books = library["books"]
        .as_object_mut()
        .context("Invalid local library")?;
    let cache = root.join("Sync/Chunks");
    if entity.kind == "book" {
        if entity.deleted {
            books.remove(&entity.book_id);
            return Ok(());
        }
        let value = local_body(entity.value()?);
        let imported_path = imported_book_path(
            &entity.book_id,
            value["kind"]
                .as_str()
                .context("Cloud book kind is missing")?,
        )?;
        let book=books.entry(entity.book_id.clone()).or_insert_with(||json!({"id":entity.book_id,"kind":value["kind"],"title":value["title"],"author":value["author"],"importedRelativePath":imported_path,"addedAt":value["addedAt"].as_f64().unwrap_or(crate::now()as f64),"lastOpenedAt":0,"progress":0,"annotations":[],"bookmarks":[],"reminders":[],"chats":[]}));
        for key in ["title", "author", "kind"] {
            book[key] = value[key].clone();
        }
        if !value["file"].is_null() {
            book["cloudFile"] = value["file"].clone();
        }
        if !value["sourceURL"].is_null() {
            book["sourceUrl"] = value["sourceURL"].clone();
        }
        return Ok(());
    }
    let Some(book) = books.get_mut(&entity.book_id) else {
        return Ok(());
    };
    if entity.kind == "position" {
        if !entity.deleted {
            let value = local_body(entity.value()?);
            book["position"] = value["locator"].clone();
            book["progress"] = value["progress"].clone();
            book["lastOpenedAt"] = value["lastOpenedAt"].clone();
        }
        return Ok(());
    }
    let collection = match entity.kind.as_str() {
        "annotation" => "annotations",
        "bookmark" => "bookmarks",
        "reminder" => "reminders",
        "chat" => "chats",
        _ => return Ok(()),
    };
    let key = entity
        .id
        .rsplit(':')
        .next()
        .context("Invalid cloud record ID")?;
    if entity.kind == "bookmark" && key == READING_MARKER_ID {
        if entity.deleted {
            book.as_object_mut().unwrap().remove("readingMarker");
        } else {
            book["readingMarker"] = entity.value()?["locator"].clone();
        }
        if let Some(items) = book["bookmarks"].as_array_mut() {
            items.retain(|b| b["id"] != READING_MARKER_ID);
        }
        return Ok(());
    }
    let mut value = if entity.deleted {
        Value::Null
    } else {
        let body = entity.value()?;
        let mut record = local_body(if entity.kind == "annotation" {
            body["annotation"].clone()
        } else {
            body.clone()
        });
        if entity.kind == "annotation" {
            for (media_key, manifests) in [
                ("sketches", body["sketches"].as_array()),
                ("audioRecordings", body["audioRecordings"].as_array()),
            ] {
                for asset in manifests.into_iter().flatten() {
                    let media_id = asset["id"].as_str().context("Cloud media has no ID")?;
                    let Some(recording) = record[media_key].as_array_mut().and_then(|items| {
                        items
                            .iter_mut()
                            .find(|v| v["id"].as_str() == Some(media_id))
                    }) else {
                        continue;
                    };
                    for (manifest_key, path_key, extension) in if media_key == "sketches" {
                        vec![
                            ("scene", "scenePath", "excalidraw.json"),
                            ("preview", "previewPath", "png"),
                        ]
                    } else {
                        vec![("recording", "path", "m4a")]
                    } {
                        if !asset[manifest_key].is_null() {
                            let manifest: BlobManifest =
                                serde_json::from_value(asset[manifest_key].clone())?;
                            let relative = format!(
                                "{}/{}/{}/{}.{}",
                                if media_key == "sketches" {
                                    "Drawings"
                                } else {
                                    "Audio"
                                },
                                sync::sha256(entity.book_id.as_bytes()),
                                key,
                                media_id,
                                extension
                            );
                            transport
                                .download_blob(&manifest, &entity.id, &cache, &root.join(&relative))
                                .await?;
                            recording[path_key] = json!(relative);
                        }
                    }
                }
            }
        }
        if entity.kind == "reminder" {
            record["completed"] = json!(!record["completedAt"].is_null());
            if let Some(annotation) = record.get("annotationID").cloned() {
                record["annotationId"] = annotation;
            }
        }
        if entity.kind == "bookmark" {
            record["title"] = record
                .get("excerpt")
                .or_else(|| record.get("chapterTitle"))
                .cloned()
                .unwrap_or(json!("Bookmark"));
        }
        if entity.kind == "chat" {
            record["modifiedAt"] = record["updatedAt"].clone();
        }
        record
    };
    if let Some(items) = book[collection].as_array_mut() {
        let existing = items
            .iter()
            .find(|v| {
                v["id"]
                    .as_str()
                    .map(|id| id.eq_ignore_ascii_case(key))
                    .unwrap_or(false)
            })
            .cloned();
        if let Some(existing) = existing {
            if !value.is_null() {
                if let Some(anchors) = existing["locator"].get("pdfAnchors") {
                    value["locator"]["pdfAnchors"] = anchors.clone();
                }
            }
        }
        items.retain(|v| {
            !v["id"]
                .as_str()
                .map(|id| id.eq_ignore_ascii_case(key))
                .unwrap_or(false)
        });
        if !entity.deleted {
            items.push(value);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dates_round_trip_without_touching_durations() {
        let mut value =
            json!({"createdAt":1700000000.25,"duration":45,"nested":{"completedAt":1700000010.5}});
        let original = value.clone();
        dates(&mut value, -APPLE_EPOCH_OFFSET);
        assert_eq!(value["createdAt"], 721692800.25);
        assert_eq!(value["duration"], 45);
        dates(&mut value, APPLE_EPOCH_OFFSET);
        assert_eq!(value, original);
    }
    #[test]
    fn projection_does_not_export_pdfjs_anchors() {
        let l = json!({"kind":"pdf","spineIndex":2,"start":{"elementPath":[],"offset":0},"pdfAnchors":[{"rect":[1,2,3,4]}],"pdfRanges":[{"location":2}]});
        let wire = locator(&l);
        assert!(wire.get("pdfAnchors").is_none());
        assert!(wire.get("pdfRanges").is_some());
    }
    #[test]
    fn local_library_visibility_never_enters_apple_book_metadata() {
        let book = json!({"title":"Book","author":"Writer","kind":"epub","addedAt":1700000000.,"sourceUrl":"https://example.org/source","removedFromLibrary":true,"offlineAvailable":false});
        let metadata = book_metadata(&book);
        assert_eq!(metadata["title"], "Book");
        assert_eq!(metadata["sourceURL"], "https://example.org/source");
        assert!(metadata.get("removedFromLibrary").is_none());
        assert!(metadata.get("offlineAvailable").is_none());
        assert_eq!(book["removedFromLibrary"], true);
    }
    #[tokio::test]
    async fn local_library_visibility_survives_remote_updates_without_hiding_new_cloud_books() {
        let directory = tempfile::tempdir().unwrap();
        let book_id = format!("epub-sha256:{}", "a".repeat(64));
        let cloud_id = format!("epub-sha256:{}", "b".repeat(64));
        let mut library = json!({"books":{book_id.clone():{"id":book_id,"kind":"epub","title":"Old title","author":"Writer","removedFromLibrary":true,"offlineAvailable":false,"annotations":[{"id":"saved-note","text":"Keep"}]}}});
        let transport = DriveTransport::new("unused".into()).unwrap();
        let body = json!({"title":"Updated remotely","author":"Writer","kind":"epub","addedAt":700000000.,"removedFromLibrary":false});
        let remote = SyncEntity::from_body(&book_id, "book", "metadata", &body, "MAC").unwrap();
        apply(
            &transport,
            directory.path(),
            &mut library,
            &remote,
            "notesOnly",
        )
        .await
        .unwrap();
        let position = SyncEntity::from_body(&book_id, "position", "current", &json!({"locator":{"kind":"epub","spineIndex":0,"start":{"elementPath":[],"offset":0}},"progress":0.5,"lastOpenedAt":700000001.}), "MAC").unwrap();
        apply(
            &transport,
            directory.path(),
            &mut library,
            &position,
            "notesOnly",
        )
        .await
        .unwrap();
        assert_eq!(library["books"][&book_id]["removedFromLibrary"], true);
        assert_eq!(library["books"][&book_id]["offlineAvailable"], false);
        assert_eq!(library["books"][&book_id]["title"], "Updated remotely");
        assert_eq!(library["books"][&book_id]["progress"], 0.5);
        assert_eq!(library["books"][&book_id]["annotations"][0]["text"], "Keep");

        // Local visibility never transfers to a book arriving from another
        // device, even if an unrecognized wire field happens to use its name.
        let cloud = SyncEntity::from_body(&cloud_id, "book", "metadata", &json!({"title":"Cloud book","author":"Writer","kind":"epub","addedAt":700000000.,"removedFromLibrary":true}), "MAC").unwrap();
        apply(
            &transport,
            directory.path(),
            &mut library,
            &cloud,
            "notesOnly",
        )
        .await
        .unwrap();
        assert!(library["books"][&cloud_id]
            .get("removedFromLibrary")
            .is_none());
    }
    #[test]
    fn source_paths_cannot_escape_library() {
        let dir = tempfile::tempdir().unwrap();
        assert!(safe_path(dir.path(), "../private").is_err());
    }
    #[test]
    fn desktop_chat_references_project_required_mac_fields() {
        let source = json!({"text":"A passage","locator":{"spineIndex":4,"pdfAnchors":[1]}});
        let wire = chat_reference(&source, "a", 0);
        assert_eq!(wire["quotedText"], "A passage");
        assert_eq!(wire["spineIndex"], 4);
        assert!(uuid::Uuid::parse_str(wire["id"].as_str().unwrap()).is_ok());
        assert!(wire.get("locator").is_none());
        assert_eq!(wire, chat_reference(&source, "a", 0));
    }
    #[tokio::test]
    async fn incoming_book_projection_commits_through_core_validation() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = kodi_reader_core::LibraryStore::open(dir.path().to_path_buf()).unwrap();
        let mut library = serde_json::to_value(store.snapshot()).unwrap();
        let book_id = format!("epub-sha256:{}", "a".repeat(64));
        let body =
            json!({"title":"Remote book","author":"Writer","kind":"epub","addedAt":700000000.25});
        let remote = SyncEntity::from_body(&book_id, "book", "metadata", &body, "MAC").unwrap();
        apply(
            &DriveTransport::new("unused".into()).unwrap(),
            dir.path(),
            &mut library,
            &remote,
            "notesOnly",
        )
        .await
        .unwrap();
        let incoming: kodi_reader_core::Library = serde_json::from_value(library).unwrap();
        store
            .mutate(|local| {
                *local = incoming;
                Ok(())
            })
            .unwrap();
        let reopened = kodi_reader_core::LibraryStore::open(dir.path().to_path_buf()).unwrap();
        assert_eq!(reopened.snapshot().books[&book_id].title, "Remote book");
        assert_eq!(
            reopened.snapshot().books[&book_id].imported_relative_path,
            format!("Books/epub-sha256-{}.epub", "a".repeat(64))
        );
    }
    #[tokio::test]
    async fn native_reserved_bookmark_updates_desktop_reading_marker() {
        let dir = tempfile::tempdir().unwrap();
        let mut library = json!({"books":{"epub-sha256:a":{"bookmarks":[]}}});
        let body = json!({"id":READING_MARKER_ID,"locator":{"kind":"epub","spineIndex":3,"start":{"elementPath":[0],"offset":12}},"createdAt":700000000.0});
        let mut remote =
            SyncEntity::from_body("epub-sha256:a", "bookmark", READING_MARKER_ID, &body, "MAC")
                .unwrap();
        let transport = DriveTransport::new("unused".into()).unwrap();
        apply(&transport, dir.path(), &mut library, &remote, "notesOnly")
            .await
            .unwrap();
        assert_eq!(
            library["books"]["epub-sha256:a"]["readingMarker"]["spineIndex"],
            3
        );
        assert_eq!(
            library["books"]["epub-sha256:a"]["bookmarks"]
                .as_array()
                .unwrap()
                .len(),
            0
        );
        remote.deleted = true;
        remote.body.clear();
        apply(&transport, dir.path(), &mut library, &remote, "notesOnly")
            .await
            .unwrap();
        assert!(library["books"]["epub-sha256:a"]
            .get("readingMarker")
            .is_none());
    }
    #[tokio::test]
    async fn incoming_mac_note_keeps_transcript_and_local_geometry() {
        let dir = tempfile::tempdir().unwrap();
        let mut library = json!({"books":{"pdf-sha256:a":{"annotations":[{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","locator":{"pdfAnchors":[{"x":2}]}}]}}});
        let body = json!({"annotation":{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","locator":{"kind":"pdf","spineIndex":0,"start":{"elementPath":[],"offset":3},"pdfRanges":[{"pageIndex":0,"location":3,"length":5}]},"text":"quote","note":"saved","color":"yellow","createdAt":700000000.0,"modifiedAt":700000001.0,"audioRecordings":[{"id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","title":"Thought","duration":3,"createdAt":700000000.0,"modifiedAt":700000001.0,"waveform":[0.5],"transcript":"My saved transcript"}],"sketches":[]}});
        let e = SyncEntity::from_body(
            "pdf-sha256:a",
            "annotation",
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            &body,
            "MAC",
        )
        .unwrap();
        apply(
            &DriveTransport::new("unused".into()).unwrap(),
            dir.path(),
            &mut library,
            &e,
            "notesOnly",
        )
        .await
        .unwrap();
        let note = &library["books"]["pdf-sha256:a"]["annotations"][0];
        assert_eq!(
            note["audioRecordings"][0]["transcript"],
            "My saved transcript"
        );
        assert_eq!(note["createdAt"], 1678307200.0);
        assert_eq!(note["locator"]["pdfAnchors"][0]["x"], 2);
        assert_eq!(note["locator"]["pdfRanges"][0]["location"], 3);
    }
}
