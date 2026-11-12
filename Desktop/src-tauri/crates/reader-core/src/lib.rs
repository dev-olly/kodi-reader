//! Kodi Reader's platform-independent, offline-first document and library core.
//!
//! Book resources are always read from immutable imported originals. This crate
//! never executes book scripts or treats a book-supplied path as a filesystem path.

mod assets;
mod epub;
mod export;
mod models;
mod paths;
mod pdf;
mod store;

pub use epub::{build_article_epub, Article, ArticleImage};
pub use export::{ExportFormat, ExportResult};
pub use models::*;
pub use paths::{normalize_archive_path, resolve_archive_href};
pub use store::{LibraryStore, RecoveryStatus};

use std::path::PathBuf;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Could not access local data: {0}")]
    Io(#[from] std::io::Error),
    #[error("Could not read library data: {0}")]
    Json(#[from] serde_json::Error),
    #[error("This file is not a readable EPUB: {0}")]
    Zip(#[from] zip::result::ZipError),
    #[error("Invalid publication: {0}")]
    InvalidPublication(String),
    #[error("Unsafe resource path: {0}")]
    UnsafePath(String),
    #[error("Resource not found: {0}")]
    ResourceNotFound(String),
    #[error("Book not found: {0}")]
    BookNotFound(String),
    #[error("Unsupported document type: {0}")]
    UnsupportedDocument(String),
    #[error("This library uses schema {found}; update Kodi Reader (supported: {supported})")]
    UnsupportedSchema { found: u32, supported: u32 },
    #[error("The library and its backup are unreadable; original files were preserved at {0}")]
    CorruptLibrary(PathBuf),
    #[error("Invalid library change: {0}")]
    Validation(String),
    #[error("Export destination already exists: {0}")]
    ExportExists(PathBuf),
}

/// Seconds since the Unix epoch. Unlike Swift's internal Date encoding this is
/// deliberately explicit and shared by all new desktop wire models.
pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
