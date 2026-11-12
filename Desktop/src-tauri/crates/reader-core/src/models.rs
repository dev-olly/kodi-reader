use crate::now;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

pub const LIBRARY_SCHEMA_VERSION: u32 = 1;

pub type Extra = BTreeMap<String, Value>;

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DocumentKind {
    #[default]
    Epub,
    Pdf,
}

impl DocumentKind {
    pub fn extension(self) -> &'static str {
        match self {
            Self::Epub => "epub",
            Self::Pdf => "pdf",
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TextPosition {
    #[serde(default)]
    pub element_path: Vec<usize>,
    #[serde(default)]
    pub offset: usize,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Locator {
    #[serde(default)]
    pub kind: DocumentKind,
    #[serde(default)]
    pub spine_index: usize,
    #[serde(default)]
    pub start: TextPosition,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<TextPosition>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_progression: Option<f64>,
    /// Portable PDF geometry, passed through without losing future fields.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pdf_anchors: Option<Value>,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Annotation {
    pub id: String,
    pub locator: Locator,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default = "yellow")]
    pub color: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chapter_title: Option<String>,
    #[serde(default = "now")]
    pub created_at: f64,
    #[serde(default = "now")]
    pub modified_at: f64,
    #[serde(default)]
    pub sketches: Vec<Value>,
    #[serde(default)]
    pub audio_recordings: Vec<Value>,
    #[serde(flatten)]
    pub extra: Extra,
}

fn yellow() -> String {
    "yellow".into()
}

impl Annotation {
    pub fn new(locator: Locator, text: String) -> Self {
        let time = now();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            locator,
            text,
            note: None,
            color: yellow(),
            chapter_title: None,
            created_at: time,
            modified_at: time,
            sketches: Vec::new(),
            audio_recordings: Vec::new(),
            extra: Extra::new(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Bookmark {
    pub id: String,
    pub locator: Locator,
    #[serde(default)]
    pub title: String,
    #[serde(default = "now")]
    pub created_at: f64,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Reminder {
    pub id: String,
    pub locator: Locator,
    pub title: String,
    #[serde(default)]
    pub completed: bool,
    #[serde(default = "now")]
    pub created_at: f64,
    #[serde(default = "now")]
    pub modified_at: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub annotation_id: Option<String>,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ChatThread {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub messages: Vec<Value>,
    #[serde(default = "now")]
    pub created_at: f64,
    #[serde(default = "now", alias = "updatedAt")]
    pub modified_at: f64,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ReaderSettings {
    pub theme: String,
    pub font_family: String,
    pub font_size: f64,
    pub line_height: f64,
    pub margin: f64,
    pub two_page_spread: bool,
    pub show_reading_goal: bool,
    pub analytics_enabled: bool,
    #[serde(flatten)]
    pub extra: Extra,
}

impl Default for ReaderSettings {
    fn default() -> Self {
        Self {
            theme: "system".into(),
            font_family: "Georgia".into(),
            font_size: 19.,
            line_height: 1.6,
            margin: 72.,
            two_page_spread: true,
            show_reading_goal: false,
            analytics_enabled: false,
            extra: Extra::new(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Book {
    pub id: String,
    #[serde(default, alias = "documentKind")]
    pub kind: DocumentKind,
    pub title: String,
    #[serde(default)]
    pub author: String,
    pub imported_relative_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_path: Option<String>,
    #[serde(default = "now")]
    pub added_at: f64,
    #[serde(default = "now")]
    pub last_opened_at: f64,
    #[serde(default)]
    pub progress: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<Locator>,
    #[serde(default)]
    pub annotations: Vec<Annotation>,
    #[serde(default)]
    pub bookmarks: Vec<Bookmark>,
    #[serde(default)]
    pub reminders: Vec<Reminder>,
    #[serde(default)]
    pub chats: Vec<ChatThread>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reading_marker: Option<Locator>,
    #[serde(default, alias = "sourceURL", skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Library {
    #[serde(alias = "version")]
    pub schema_version: u32,
    #[serde(default)]
    pub books: BTreeMap<String, Book>,
    #[serde(default)]
    pub settings: ReaderSettings,
    #[serde(default)]
    pub reading_history: BTreeMap<String, u64>,
    #[serde(default = "default_goal")]
    pub goal_minutes: u32,
    #[serde(default = "new_device_id")]
    pub device_id: String,
    #[serde(flatten)]
    pub extra: Extra,
}

fn default_goal() -> u32 {
    20
}
fn new_device_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

impl Default for Library {
    fn default() -> Self {
        Self {
            schema_version: LIBRARY_SCHEMA_VERSION,
            books: BTreeMap::new(),
            settings: ReaderSettings::default(),
            reading_history: BTreeMap::new(),
            goal_minutes: default_goal(),
            device_id: new_device_id(),
            extra: Extra::new(),
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SpineItem {
    /// Canonical archive-relative URI (not a decoded ZIP filename), or the
    /// one-based `#page=N` target for a PDF page.
    pub href: String,
    pub media_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TocEntry {
    pub title: String,
    /// Canonical URI with filename delimiters encoded separately from fragment.
    pub href: String,
    #[serde(default)]
    pub children: Vec<TocEntry>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Publication {
    pub title: String,
    pub author: String,
    pub reading_order: Vec<SpineItem>,
    pub toc: Vec<TocEntry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_href: Option<String>,
    #[serde(default = "ltr")]
    pub page_progression: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identifier: Option<String>,
}

fn ltr() -> String {
    "ltr".into()
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Resource {
    #[serde(skip)]
    pub bytes: Vec<u8>,
    pub media_type: String,
}
