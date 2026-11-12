use crate::epub::EpubArchive;
use crate::paths::{content_filename, safe_relative_file};
use crate::{
    build_article_epub, now, Annotation, Article, Book, Bookmark, DocumentKind, Error, Extra,
    Library, Locator, Publication, Reminder, Resource, Result, LIBRARY_SCHEMA_VERSION,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use tempfile::NamedTempFile;

const MAX_DOCUMENT_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const MAX_LIBRARY_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum RecoveryStatus {
    #[default]
    None,
    RecoveredBackup {
        preserved_corrupt_file: Option<PathBuf>,
    },
}

/// Durable library owner. Serialize access with a Mutex in a desktop shell.
/// Mutations are transactional: validation and persistence succeed before the
/// in-memory snapshot changes. Atomic replacement also works on Windows.
pub struct LibraryStore {
    root: PathBuf,
    library: Library,
    recovery: RecoveryStatus,
}

impl LibraryStore {
    pub fn open(root: PathBuf) -> Result<Self> {
        fs::create_dir_all(&root)?;
        let root = fs::canonicalize(root)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
        }
        for directory in ["Books", "Covers", "Drawings", "Audio"] {
            let path = root.join(directory);
            fs::create_dir_all(&path)?;
            if !fs::canonicalize(&path)?.starts_with(&root) {
                return Err(Error::UnsafePath(directory.into()));
            }
        }
        let primary = root.join("library.json");
        let backup = root.join("library.backup.json");
        let loaded = load_library(&primary);
        let mut recovery = RecoveryStatus::None;
        let library = match loaded {
            Ok(Some(library)) => library,
            Err(error @ Error::UnsupportedSchema { .. }) => return Err(error),
            Ok(None) if !backup.exists() => Library::default(),
            Ok(None) | Err(_) => {
                let library = match load_library(&backup) {
                    Ok(Some(library)) => library,
                    Err(error @ Error::UnsupportedSchema { .. }) => return Err(error),
                    _ => return Err(Error::CorruptLibrary(primary)),
                };
                let preserved = if primary.exists() {
                    let path = root.join(format!("library.corrupt-{}.json", uuid::Uuid::new_v4()));
                    fs::copy(&primary, &path)?;
                    Some(path)
                } else {
                    None
                };
                recovery = RecoveryStatus::RecoveredBackup {
                    preserved_corrupt_file: preserved,
                };
                library
            }
        };
        validate_library(&library)?;
        let store = Self {
            root,
            library,
            recovery,
        };
        // Materialize a new or recovered primary without rotating a good backup.
        if !primary.exists() || store.recovery != RecoveryStatus::None {
            atomic_write(&primary, &serde_json::to_vec_pretty(&store.library)?)?;
        }
        if !backup.exists() {
            atomic_write(&backup, &serde_json::to_vec_pretty(&store.library)?)?;
        }
        Ok(store)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn snapshot(&self) -> Library {
        self.library.clone()
    }
    pub fn recovery_status(&self) -> &RecoveryStatus {
        &self.recovery
    }

    pub fn book(&self, book_id: &str) -> Result<&Book> {
        self.library
            .books
            .get(book_id)
            .ok_or_else(|| Error::BookNotFound(book_id.into()))
    }

    /// Apply a complete local transaction. The closure cannot redirect an
    /// imported original: every book path must equal its content-addressed path.
    pub fn mutate<F>(&mut self, mutation: F) -> Result<Library>
    where
        F: FnOnce(&mut Library) -> Result<()>,
    {
        let mut candidate = self.library.clone();
        remember_completed_days(&mut candidate);
        mutation(&mut candidate)?;
        remember_completed_days(&mut candidate);
        validate_library(&candidate)?;
        self.persist(&candidate)?;
        self.library = candidate;
        Ok(self.snapshot())
    }

    pub fn update_book<F>(&mut self, book_id: &str, mutation: F) -> Result<Book>
    where
        F: FnOnce(&mut Book) -> Result<()>,
    {
        self.mutate(|library| {
            let book = library
                .books
                .get_mut(book_id)
                .ok_or_else(|| Error::BookNotFound(book_id.into()))?;
            mutation(book)
        })?;
        Ok(self.book(book_id)?.clone())
    }

    /// Save editable reading data while retaining the trusted imported-file
    /// identity and locations. UI payloads cannot redirect an original or cover.
    pub fn save_book(&mut self, mut book: Book) -> Result<Book> {
        let original = self.book(&book.id)?.clone();
        book.kind = original.kind;
        book.imported_relative_path = original.imported_relative_path;
        book.cover_path = original.cover_path;
        book.added_at = original.added_at;
        let mut extra = original.extra;
        extra.extend(book.extra);
        book.extra = extra;
        let id = book.id.clone();
        self.mutate(|library| {
            library.books.insert(id.clone(), book);
            Ok(())
        })?;
        Ok(self.book(&id)?.clone())
    }

    pub fn import_document<P: AsRef<Path>>(&mut self, path: P) -> Result<Book> {
        self.import_document_with_source(path.as_ref(), None)
    }

    fn import_document_with_source(
        &mut self,
        source: &Path,
        source_url: Option<String>,
    ) -> Result<Book> {
        let extension = source
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let kind = match extension.as_str() {
            "epub" => DocumentKind::Epub,
            "pdf" => DocumentKind::Pdf,
            _ => return Err(Error::UnsupportedDocument(extension)),
        };
        if fs::metadata(source)?.len() > MAX_DOCUMENT_BYTES {
            return Err(Error::InvalidPublication("Document is too large".into()));
        }
        // Snapshot the selected file once before parsing or hashing. This avoids
        // a changing source yielding an ID for bytes different from the import.
        let mut staged = NamedTempFile::new_in(self.root.join("Books"))?;
        let mut input = File::open(source)?;
        let mut digest = Sha256::new();
        let mut buffer = [0u8; 64 * 1024];
        let mut size = 0u64;
        loop {
            let count = input.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            size += count as u64;
            if size > MAX_DOCUMENT_BYTES {
                return Err(Error::InvalidPublication("Document is too large".into()));
            }
            digest.update(&buffer[..count]);
            staged.write_all(&buffer[..count])?;
        }
        staged.as_file().sync_all()?;
        let id = format!(
            "{}-sha256:{}",
            kind.extension(),
            hex::encode(digest.finalize())
        );
        if let Some(existing) = self.library.books.get(&id).cloned() {
            // Rehydrate a missing original without resetting reading data.
            // A corrupt existing copy must not make a known-good reimport a
            // silent no-op: preserve its bytes before replacing it atomically.
            let target = self
                .root
                .join(safe_relative_file(&existing.imported_relative_path)?);
            if target.exists() {
                let current = confined_file(&self.root, &existing.imported_relative_path)?;
                if hash_file(&current)? != id.split(':').nth(1).unwrap_or("") {
                    let preserved = self.root.join("Books").join(format!(
                        "{}.corrupt-{}",
                        content_filename(&id),
                        uuid::Uuid::new_v4()
                    ));
                    fs::copy(&current, preserved)?;
                    staged
                        .persist(&target)
                        .map_err(|error| Error::Io(error.error))?;
                }
            } else {
                staged
                    .persist_noclobber(&target)
                    .map_err(|error| Error::Io(error.error))?;
            }
            #[cfg(unix)]
            File::open(self.root.join("Books"))?.sync_all()?;
            if existing.extra.get("offlineAvailable") != Some(&serde_json::Value::Bool(true))
                || existing.extra.contains_key("removedFromLibrary")
            {
                return self.update_book(&id, |book| {
                    book.extra.insert("offlineAvailable".into(), true.into());
                    book.extra.remove("removedFromLibrary");
                    Ok(())
                });
            }
            return Ok(existing);
        }
        let fallback_title = source
            .file_stem()
            .and_then(|name| name.to_str())
            .unwrap_or("Untitled")
            .to_owned();
        let (title, author, cover) = match kind {
            DocumentKind::Epub => {
                let mut archive = EpubArchive::open(staged.path())?;
                let publication = archive.publication()?;
                let title = if publication.title.trim().is_empty() {
                    fallback_title
                } else {
                    publication.title
                };
                let cover = publication.cover_href.and_then(|path| {
                    archive
                        .resource(&path)
                        .ok()
                        .map(|resource| (path, resource))
                });
                (
                    title,
                    if publication.author.is_empty() {
                        "Unknown Author".into()
                    } else {
                        publication.author
                    },
                    cover,
                )
            }
            DocumentKind::Pdf => {
                let document = lopdf::Document::load(staged.path()).map_err(|error| {
                    Error::InvalidPublication(format!("Unreadable PDF: {error}"))
                })?;
                if document.is_encrypted() {
                    return Err(Error::InvalidPublication(
                        "Password-protected PDFs are not supported".into(),
                    ));
                }
                if document.get_pages().is_empty() {
                    return Err(Error::InvalidPublication("PDF has no pages".into()));
                }
                let info = document
                    .trailer
                    .get(b"Info")
                    .ok()
                    .and_then(|object| object.as_reference().ok())
                    .and_then(|id| document.get_dictionary(id).ok());
                let title = info
                    .and_then(|dict| dict.get(b"Title").ok())
                    .and_then(pdf_string)
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or(fallback_title);
                let author = info
                    .and_then(|dict| dict.get(b"Author").ok())
                    .and_then(pdf_string)
                    .unwrap_or_else(|| "Unknown Author".into());
                (title, author, None)
            }
        };
        let imported_relative_path = imported_path(&id, kind);
        let target = self.root.join(&imported_relative_path);
        if target.exists() {
            // A prior interrupted import may have left the immutable original.
            if hash_file(&target)? != id.split(':').nth(1).unwrap_or("") {
                return Err(Error::InvalidPublication(
                    "Imported original failed its content checksum".into(),
                ));
            }
        } else {
            staged
                .persist_noclobber(&target)
                .map_err(|error| Error::Io(error.error))?;
        }
        #[cfg(unix)]
        File::open(self.root.join("Books"))?.sync_all()?;
        let cover_path = if let Some((href, resource)) = cover {
            let extension = href
                .rsplit('.')
                .next()
                .unwrap_or("img")
                .to_ascii_lowercase();
            // Only image assets may become cover files; filenames are ours.
            if resource.media_type.starts_with("image/")
                && matches!(
                    extension.as_str(),
                    "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg" | "avif"
                )
            {
                let relative = format!("Covers/{}.{extension}", content_filename(&id));
                atomic_write(&self.root.join(&relative), &resource.bytes)?;
                Some(relative)
            } else {
                None
            }
        } else {
            None
        };
        let time = now();
        let book = Book {
            id: id.clone(),
            kind,
            title,
            author,
            imported_relative_path,
            cover_path,
            added_at: time,
            last_opened_at: time,
            progress: 0.,
            position: None,
            annotations: Vec::new(),
            bookmarks: Vec::new(),
            reminders: Vec::new(),
            chats: Vec::new(),
            reading_marker: None,
            source_url,
            extra: Extra::new(),
        };
        self.mutate(|library| {
            library.books.insert(id, book.clone());
            Ok(())
        })?;
        Ok(book)
    }

    pub fn import_article(&mut self, article: &Article) -> Result<Book> {
        let bytes = build_article_epub(article)?;
        let mut staged = tempfile::Builder::new()
            .suffix(".epub")
            .tempfile_in(&self.root)?;
        staged.write_all(&bytes)?;
        self.import_document_with_source(staged.path(), Some(article.source_url.clone()))
    }

    pub fn publication(&self, book_id: &str) -> Result<Publication> {
        let book = self.book(book_id)?;
        let source = self.imported_file(book)?;
        match book.kind {
            DocumentKind::Epub => EpubArchive::open(&source)?.publication(),
            DocumentKind::Pdf => {
                let document = lopdf::Document::load(&source)
                    .map_err(|error| Error::InvalidPublication(error.to_string()))?;
                let pages = document.get_pages();
                Ok(Publication {
                    title: book.title.clone(),
                    author: book.author.clone(),
                    reading_order: pages
                        .keys()
                        .map(|page| crate::SpineItem {
                            href: format!("#page={page}"),
                            media_type: "application/pdf".into(),
                            title: Some(format!("Page {page}")),
                        })
                        .collect(),
                    toc: crate::pdf::table_of_contents(&document, &pages),
                    page_progression: "ltr".into(),
                    ..Publication::default()
                })
            }
        }
    }

    /// Read an archive-relative URI reference, percent-decoding exactly once.
    /// `Publication` hrefs can be passed directly without further URI encoding.
    pub fn resource(&self, book_id: &str, path: &str) -> Result<Resource> {
        let book = self.book(book_id)?;
        if book.kind != DocumentKind::Epub {
            return Err(Error::UnsupportedDocument(
                "PDF resources are accessed through the immutable document".into(),
            ));
        }
        EpubArchive::open(&self.imported_file(book)?)?.resource(path)
    }

    pub fn document_path(&self, book_id: &str) -> Result<PathBuf> {
        self.imported_file(self.book(book_id)?)
    }

    /// Remove only the downloaded original. Reading data and attachments stay
    /// available for a later reimport. Commit metadata before deleting bytes so
    /// a storage failure or interruption cannot strand an unreferenced original.
    pub fn remove_local_download(&mut self, book_id: &str) -> Result<Book> {
        self.remove_download(book_id, false)
    }

    /// Hide a document from this device's Library while retaining its reading
    /// data and synced record. This local visibility flag never reaches sync.
    pub fn remove_from_library(&mut self, book_id: &str) -> Result<Book> {
        self.remove_download(book_id, true)
    }

    fn remove_download(&mut self, book_id: &str, hide_from_library: bool) -> Result<Book> {
        let book = self.book(book_id)?.clone();
        let path = self
            .root
            .join(safe_relative_file(&book.imported_relative_path)?);
        let exists = path.exists();
        if exists {
            confined_file(&self.root, &book.imported_relative_path)?;
        }
        let result = self.update_book(book_id, |book| {
            book.extra.insert("offlineAvailable".into(), false.into());
            if hide_from_library {
                book.extra.insert("removedFromLibrary".into(), true.into());
            }
            Ok(())
        })?;
        if exists {
            if let Err(error) = fs::remove_file(&path) {
                let restored = self.update_book(book_id, |current| {
                    for key in ["offlineAvailable", "removedFromLibrary"] {
                        if let Some(previous) = book.extra.get(key) {
                            current.extra.insert(key.into(), previous.clone());
                        } else {
                            current.extra.remove(key);
                        }
                    }
                    Ok(())
                });
                if let Err(restore) = restored {
                    return Err(Error::Validation(format!(
                        "The original was kept because the download could not be removed ({error}); its availability status could not be restored: {restore}"
                    )));
                }
                return Err(error.into());
            }
        }
        Ok(result)
    }

    /// Durably delete a record, then unlink only its owned, unshared local
    /// assets. Returned errors describe cleanup that could not finish; metadata
    /// deletion is already committed. A metadata failure never deletes bytes.
    pub fn delete_book(&mut self, book_id: &str) -> Result<Vec<String>> {
        let removed = self.book(book_id)?.clone();
        let plan = crate::assets::deletion_plan(
            &self.root,
            &removed,
            self.library
                .books
                .values()
                .filter(|book| book.id != book_id),
        )?;
        self.mutate(|library| {
            library.books.remove(book_id);
            Ok(())
        })?;
        Ok(plan.execute())
    }

    fn imported_file(&self, book: &Book) -> Result<PathBuf> {
        confined_file(&self.root, &book.imported_relative_path)
    }

    pub fn rename_book(&mut self, book_id: &str, title: &str) -> Result<Book> {
        let title = title.trim();
        if title.is_empty() {
            return Err(Error::Validation("Enter a document title".into()));
        }
        self.update_book(book_id, |book| {
            book.title = title.into();
            Ok(())
        })
    }

    pub fn save_position(
        &mut self,
        book_id: &str,
        locator: Locator,
        progress: f64,
    ) -> Result<Book> {
        self.update_book(book_id, |book| {
            book.position = Some(locator);
            book.progress = progress;
            book.last_opened_at = now();
            Ok(())
        })
    }

    pub fn upsert_annotation(&mut self, book_id: &str, mut annotation: Annotation) -> Result<Book> {
        annotation.modified_at = now();
        self.update_book(book_id, |book| {
            if let Some(existing) = book
                .annotations
                .iter_mut()
                .find(|value| value.id == annotation.id)
            {
                *existing = annotation;
            } else {
                book.annotations.push(annotation);
            }
            Ok(())
        })
    }

    pub fn delete_annotation(&mut self, book_id: &str, annotation_id: &str) -> Result<Book> {
        // Research reminders retain their source context after a note is removed.
        self.update_book(book_id, |book| {
            book.annotations.retain(|value| value.id != annotation_id);
            Ok(())
        })
    }

    pub fn upsert_bookmark(&mut self, book_id: &str, bookmark: Bookmark) -> Result<Book> {
        self.update_book(book_id, |book| {
            if let Some(existing) = book
                .bookmarks
                .iter_mut()
                .find(|value| value.id == bookmark.id)
            {
                *existing = bookmark;
            } else {
                book.bookmarks.push(bookmark);
            }
            Ok(())
        })
    }

    pub fn delete_bookmark(&mut self, book_id: &str, bookmark_id: &str) -> Result<Book> {
        self.update_book(book_id, |book| {
            book.bookmarks.retain(|value| value.id != bookmark_id);
            Ok(())
        })
    }

    pub fn upsert_reminder(&mut self, book_id: &str, mut reminder: Reminder) -> Result<Book> {
        reminder.modified_at = now();
        self.update_book(book_id, |book| {
            if let Some(existing) = book
                .reminders
                .iter_mut()
                .find(|value| value.id == reminder.id)
            {
                *existing = reminder;
            } else {
                book.reminders.push(reminder);
            }
            Ok(())
        })
    }

    pub fn delete_reminder(&mut self, book_id: &str, reminder_id: &str) -> Result<Book> {
        self.update_book(book_id, |book| {
            book.reminders.retain(|value| value.id != reminder_id);
            Ok(())
        })
    }

    pub fn add_reading_seconds(&mut self, date: &str, seconds: u64) -> Result<Library> {
        if !valid_date(date) || seconds > 24 * 60 * 60 {
            return Err(Error::Validation("Invalid reading date or duration".into()));
        }
        self.mutate(|library| {
            let total = library.reading_history.entry(date.into()).or_default();
            *total = total.saturating_add(seconds).min(24 * 60 * 60);
            Ok(())
        })
    }

    pub fn goal_reached(&self, date: &str) -> bool {
        self.library.reading_history.get(date).copied().unwrap_or(0)
            >= u64::from(self.library.goal_minutes) * 60
            || self
                .library
                .extra
                .get("completedReadingDays")
                .and_then(|value| value.as_array())
                .is_some_and(|days| days.iter().any(|day| day.as_str() == Some(date)))
    }

    pub fn reading_streak(&self, date: &str) -> u32 {
        if !valid_date(date) {
            return 0;
        }
        let mut cursor = date.to_owned();
        if !self.goal_reached(&cursor) {
            cursor = previous_date(&cursor);
        }
        let mut streak = 0u32;
        while self.goal_reached(&cursor) {
            streak = streak.saturating_add(1);
            if cursor == "1970-01-01" {
                break;
            }
            cursor = previous_date(&cursor);
        }
        streak
    }

    fn persist(&self, library: &Library) -> Result<()> {
        let primary = self.root.join("library.json");
        if let Ok(Some(previous)) = load_library(&primary) {
            atomic_write(
                &self.root.join("library.backup.json"),
                &serde_json::to_vec_pretty(&previous)?,
            )?;
        }
        atomic_write(&primary, &serde_json::to_vec_pretty(library)?)
    }
}

fn imported_path(id: &str, kind: DocumentKind) -> String {
    format!("Books/{}.{}", content_filename(id), kind.extension())
}

pub(crate) fn confined_file(root: &Path, relative: &str) -> Result<PathBuf> {
    let path = root.join(safe_relative_file(relative)?);
    let canonical = fs::canonicalize(&path)?;
    if !canonical.starts_with(root) || !canonical.is_file() {
        return Err(Error::UnsafePath(relative.into()));
    }
    Ok(canonical)
}

pub(crate) fn atomic_write(destination: &Path, bytes: &[u8]) -> Result<()> {
    let parent = destination
        .parent()
        .ok_or_else(|| Error::UnsafePath(destination.display().to_string()))?;
    fs::create_dir_all(parent)?;
    let mut staged = NamedTempFile::new_in(parent)?;
    staged.write_all(bytes)?;
    staged.as_file().sync_all()?;
    staged
        .persist(destination)
        .map_err(|error| Error::Io(error.error))?;
    #[cfg(unix)]
    File::open(parent)?.sync_all()?;
    Ok(())
}

fn load_library(path: &Path) -> Result<Option<Library>> {
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if metadata.len() > MAX_LIBRARY_BYTES {
        return Err(Error::Validation("Library is too large".into()));
    }
    let bytes = fs::read(path)?;
    let value: serde_json::Value = serde_json::from_slice(&bytes)?;
    let version = value
        .get("schemaVersion")
        .or_else(|| value.get("version"))
        .and_then(|x| x.as_u64())
        .ok_or_else(|| Error::Validation("Library schema version is missing".into()))?;
    if version > u64::from(LIBRARY_SCHEMA_VERSION) {
        return Err(Error::UnsupportedSchema {
            found: version.min(u64::from(u32::MAX)) as u32,
            supported: LIBRARY_SCHEMA_VERSION,
        });
    }
    let mut library: Library = serde_json::from_value(value)?;
    library.schema_version = LIBRARY_SCHEMA_VERSION;
    validate_library(&library)?;
    Ok(Some(library))
}

fn finite(value: f64) -> bool {
    value.is_finite() && value >= 0.
}

fn validate_library(library: &Library) -> Result<()> {
    if library.schema_version != LIBRARY_SCHEMA_VERSION {
        return Err(Error::UnsupportedSchema {
            found: library.schema_version,
            supported: LIBRARY_SCHEMA_VERSION,
        });
    }
    if library.device_id.is_empty() || library.goal_minutes < 5 || library.goal_minutes > 1440 {
        return Err(Error::Validation(
            "Invalid device identity or reading goal".into(),
        ));
    }
    let settings = &library.settings;
    if !["light", "sepia", "dark", "system"].contains(&settings.theme.as_str())
        || !(8. ..=96.).contains(&settings.font_size)
        || !(1. ..=4.).contains(&settings.line_height)
        || !(0. ..=400.).contains(&settings.margin)
        || settings.font_family.len() > 512
    {
        return Err(Error::Validation("Invalid reader appearance".into()));
    }
    for (id, book) in &library.books {
        let expected_prefix = format!("{}-sha256:", book.kind.extension());
        if id != &book.id
            || !id.starts_with(&expected_prefix)
            || id.len() != expected_prefix.len() + 64
            || !id[expected_prefix.len()..]
                .bytes()
                .all(|x| x.is_ascii_hexdigit() && !x.is_ascii_uppercase())
            || book.imported_relative_path != imported_path(id, book.kind)
        {
            return Err(Error::Validation(
                "Imported document identity/path cannot be changed".into(),
            ));
        }
        safe_relative_file(&book.imported_relative_path)?;
        if let Some(path) = &book.cover_path {
            safe_relative_file(path)?;
            if !path.starts_with("Covers/") {
                return Err(Error::UnsafePath(path.into()));
            }
        }
        if book.title.trim().is_empty()
            || !finite(book.added_at)
            || !finite(book.last_opened_at)
            || !(0. ..=1.).contains(&book.progress)
        {
            return Err(Error::Validation("Invalid document metadata".into()));
        }
        for locator in book
            .position
            .iter()
            .chain(book.reading_marker.iter())
            .chain(book.annotations.iter().map(|x| &x.locator))
            .chain(book.bookmarks.iter().map(|x| &x.locator))
            .chain(book.reminders.iter().map(|x| &x.locator))
        {
            if locator.kind != book.kind
                || locator.start.element_path.len() > 256
                || locator
                    .end
                    .as_ref()
                    .is_some_and(|x| x.element_path.len() > 256)
                || locator
                    .total_progression
                    .is_some_and(|value| !(0. ..=1.).contains(&value))
            {
                return Err(Error::Validation("Invalid document locator".into()));
            }
        }
        let mut ids = std::collections::BTreeSet::new();
        for note in &book.annotations {
            if note.id.is_empty()
                || !ids.insert(&note.id)
                || !finite(note.created_at)
                || !finite(note.modified_at)
                || !["yellow", "green", "blue", "pink", "purple", "underline"]
                    .contains(&note.color.as_str())
            {
                return Err(Error::Validation("Invalid annotation".into()));
            }
        }
        ids.clear();
        for reminder in &book.reminders {
            if reminder.id.is_empty()
                || !ids.insert(&reminder.id)
                || reminder.title.trim().is_empty()
                || !finite(reminder.created_at)
                || !finite(reminder.modified_at)
            {
                return Err(Error::Validation("Invalid research reminder".into()));
            }
        }
    }
    if library
        .reading_history
        .iter()
        .any(|(date, seconds)| !valid_date(date) || *seconds > 86400)
    {
        return Err(Error::Validation("Invalid reading history".into()));
    }
    Ok(())
}

fn valid_date(date: &str) -> bool {
    let parts = date.split('-').collect::<Vec<_>>();
    if parts.len() != 3 || parts[0].len() != 4 || parts[1].len() != 2 || parts[2].len() != 2 {
        return false;
    }
    let (Ok(year), Ok(month), Ok(day)) = (
        parts[0].parse::<u32>(),
        parts[1].parse::<u32>(),
        parts[2].parse::<u32>(),
    ) else {
        return false;
    };
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let max = match month {
        2 => {
            if leap {
                29
            } else {
                28
            }
        }
        4 | 6 | 9 | 11 => 30,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => return false,
    };
    year >= 1970 && (1..=max).contains(&day)
}

fn remember_completed_days(library: &mut Library) {
    let mut days = library
        .extra
        .get("completedReadingDays")
        .and_then(|value| value.as_array())
        .map(|days| {
            days.iter()
                .filter_map(|day| day.as_str())
                .filter(|day| valid_date(day))
                .map(String::from)
                .collect::<std::collections::BTreeSet<_>>()
        })
        .unwrap_or_default();
    days.extend(
        library
            .reading_history
            .iter()
            .filter(|(_, seconds)| **seconds >= u64::from(library.goal_minutes) * 60)
            .map(|(date, _)| date.clone()),
    );
    if !days.is_empty() {
        library.extra.insert(
            "completedReadingDays".into(),
            serde_json::to_value(days).unwrap(),
        );
    }
}

fn previous_date(date: &str) -> String {
    let mut parts = date.split('-').map(|part| part.parse::<u32>().unwrap());
    let (mut year, mut month, mut day) = (
        parts.next().unwrap(),
        parts.next().unwrap(),
        parts.next().unwrap(),
    );
    if day > 1 {
        day -= 1;
    } else {
        if month > 1 {
            month -= 1;
        } else {
            year -= 1;
            month = 12;
        }
        day = match month {
            2 => {
                if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
                    29
                } else {
                    28
                }
            }
            4 | 6 | 9 | 11 => 30,
            _ => 31,
        };
    }
    format!("{year:04}-{month:02}-{day:02}")
}

fn hash_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(hex::encode(digest.finalize()))
}

fn pdf_string(object: &lopdf::Object) -> Option<String> {
    let bytes = object.as_str().ok()?;
    if bytes.starts_with(&[0xfe, 0xff]) {
        Some(String::from_utf16_lossy(
            &bytes[2..]
                .chunks_exact(2)
                .map(|x| u16::from_be_bytes([x[0], x[1]]))
                .collect::<Vec<_>>(),
        ))
    } else {
        Some(String::from_utf8_lossy(bytes).into_owned())
    }
}
