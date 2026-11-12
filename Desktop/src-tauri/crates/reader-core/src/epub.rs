use crate::paths::{
    mime_type, normalize_archive_entry_path, normalize_archive_path, resolve_archive_href,
    resolve_archive_reference,
};
use crate::{Error, Publication, Resource, Result, SpineItem, TocEntry};
use quick_xml::{events::Event, Reader};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Cursor, Read, Write};
use std::path::Path;
use zip::{write::FileOptions, CompressionMethod, ZipArchive, ZipWriter};

pub(crate) const MAX_RESOURCE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_XML_BYTES: usize = 16 * 1024 * 1024;

pub(crate) struct EpubArchive {
    zip: ZipArchive<File>,
    index: BTreeMap<String, (String, usize)>,
}

impl EpubArchive {
    pub(crate) fn open(path: &Path) -> Result<Self> {
        let mut zip = ZipArchive::new(File::open(path)?)?;
        if zip.len() > 100_000 {
            return Err(Error::InvalidPublication("Too many archive entries".into()));
        }
        let mut index = BTreeMap::new();
        let mut total = 0u64;
        for number in 0..zip.len() {
            let entry = zip.by_index(number)?;
            if entry.is_dir() {
                continue;
            }
            if entry
                .unix_mode()
                .is_some_and(|mode| mode & 0o170000 == 0o120000)
            {
                return Err(Error::UnsafePath(entry.name().into()));
            }
            let name = entry.name();
            if name.split('/').any(|part| part == "..") {
                return Err(Error::UnsafePath(name.into()));
            }
            let path = normalize_archive_entry_path(name)?;
            total = total
                .checked_add(entry.size())
                .ok_or_else(|| Error::InvalidPublication("Archive size overflow".into()))?;
            if total > 2 * 1024 * 1024 * 1024 {
                return Err(Error::InvalidPublication(
                    "EPUB expands beyond the supported size".into(),
                ));
            }
            if index
                .insert(path.to_lowercase(), (path.clone(), number))
                .is_some()
            {
                return Err(Error::InvalidPublication(format!(
                    "Ambiguous archive resource: {path}"
                )));
            }
        }
        Ok(Self { zip, index })
    }

    pub(crate) fn resource(&mut self, path: &str) -> Result<Resource> {
        let path = normalize_archive_path(path.split(['#', '?']).next().unwrap_or(path))?;
        self.resource_at_path(&path)
    }

    /// Read a canonical, already-resolved ZIP name. Internal parsers and cover
    /// loading use this path, avoiding a second round of percent decoding.
    pub(crate) fn resource_at_path(&mut self, path: &str) -> Result<Resource> {
        let path = normalize_archive_entry_path(path)?;
        let (actual, index) = self
            .index
            .get(&path.to_lowercase())
            .cloned()
            .ok_or_else(|| Error::ResourceNotFound(path.clone()))?;
        let mut entry = self.zip.by_index(index)?;
        if entry.size() > MAX_RESOURCE_BYTES {
            return Err(Error::InvalidPublication(format!(
                "Resource is too large: {path}"
            )));
        }
        let mut bytes = Vec::with_capacity(entry.size() as usize);
        (&mut entry)
            .take(MAX_RESOURCE_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_RESOURCE_BYTES {
            return Err(Error::InvalidPublication(
                "Resource expands beyond its size limit".into(),
            ));
        }
        Ok(Resource {
            bytes,
            media_type: mime_type(&actual).into(),
        })
    }

    fn xml(&mut self, path: &str) -> Result<Node> {
        let bytes = self.resource_at_path(path)?.bytes;
        if bytes.len() > MAX_XML_BYTES {
            return Err(Error::InvalidPublication(
                "XML document is too large".into(),
            ));
        }
        parse_xml(&bytes)
    }

    pub(crate) fn publication(&mut self) -> Result<Publication> {
        let container = self.xml("META-INF/container.xml")?;
        let package_path = container
            .descendants("rootfile")
            .find(|node| node.attr("media-type") == Some("application/oebps-package+xml"))
            .or_else(|| container.descendants("rootfile").next())
            .and_then(|node| node.attr("full-path"))
            .ok_or_else(|| Error::InvalidPublication("EPUB has no package document".into()))?;
        let package_path = normalize_archive_entry_path(package_path)?;
        let package = self.xml(&package_path)?;
        let package = package
            .descendants("package")
            .next()
            .ok_or_else(|| Error::InvalidPublication("Missing OPF package element".into()))?;
        let metadata = package.child("metadata");
        let title = metadata
            .and_then(|node| node.descendants("title").next())
            .map(Node::text)
            .unwrap_or_default();
        let creators: Vec<_> = metadata
            .map(|node| {
                node.descendants("creator")
                    .map(Node::text)
                    .filter(|x| !x.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let identifier = metadata
            .and_then(|node| node.descendants("identifier").next())
            .map(Node::text)
            .filter(|x| !x.is_empty());
        let mut manifest = BTreeMap::new();
        let mut nav = None;
        let mut cover = None;
        let cover_id = metadata
            .and_then(|node| {
                node.descendants("meta")
                    .find(|x| x.attr("name") == Some("cover"))
            })
            .and_then(|node| node.attr("content"));
        if let Some(items) = package.child("manifest") {
            for item in items.children.iter().filter(|node| node.name == "item") {
                let (Some(id), Some(href)) = (item.attr("id"), item.attr("href")) else {
                    continue;
                };
                let reference = resolve_archive_reference(&package_path, href)?;
                let media_type = item
                    .attr("media-type")
                    .unwrap_or(mime_type(&reference.path))
                    .to_owned();
                let props = item
                    .attr("properties")
                    .unwrap_or("")
                    .split_whitespace()
                    .collect::<Vec<_>>();
                if props.contains(&"nav") {
                    nav = Some(reference.path.clone());
                }
                if props.contains(&"cover-image") || cover_id == Some(id) {
                    cover = Some(reference.href());
                }
                manifest.insert(id.to_owned(), (reference, media_type));
            }
        }
        let spine = package
            .child("spine")
            .ok_or_else(|| Error::InvalidPublication("EPUB has no reading order".into()))?;
        let mut reading_order = Vec::new();
        for item in spine
            .children
            .iter()
            .filter(|node| node.name == "itemref" && node.attr("linear") != Some("no"))
        {
            let id = item
                .attr("idref")
                .ok_or_else(|| Error::InvalidPublication("Spine entry has no reference".into()))?;
            let (reference, media_type) = manifest.get(id).ok_or_else(|| {
                Error::InvalidPublication(format!("Missing spine resource: {id}"))
            })?;
            if !self.index.contains_key(&reference.path.to_lowercase()) {
                return Err(Error::InvalidPublication(format!(
                    "Missing chapter: {}",
                    reference.path
                )));
            }
            reading_order.push(SpineItem {
                href: reference.href(),
                media_type: media_type.clone(),
                title: None,
            });
        }
        if reading_order.is_empty() {
            return Err(Error::InvalidPublication(
                "EPUB has an empty reading order".into(),
            ));
        }
        let toc = if let Some(nav_path) = nav {
            self.xml(&nav_path)
                .ok()
                .map(|tree| parse_nav(&tree, &nav_path))
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        let toc = if toc.is_empty() {
            let ncx = spine
                .attr("toc")
                .and_then(|id| manifest.get(id))
                .or_else(|| {
                    manifest
                        .values()
                        .find(|(_, media)| media == "application/x-dtbncx+xml")
                });
            ncx.and_then(|(reference, _)| {
                self.xml(&reference.path)
                    .ok()
                    .map(|tree| parse_ncx(&tree, &reference.path))
            })
            .unwrap_or_default()
        } else {
            toc
        };
        for item in &mut reading_order {
            item.title = toc_title(&toc, &item.href);
        }
        Ok(Publication {
            title,
            author: creators.join(", "),
            reading_order,
            toc,
            cover_href: cover,
            page_progression: if spine.attr("page-progression-direction") == Some("rtl") {
                "rtl"
            } else {
                "ltr"
            }
            .into(),
            identifier,
        })
    }
}

#[derive(Clone, Debug, Default)]
struct Node {
    name: String,
    attrs: BTreeMap<String, String>,
    children: Vec<Node>,
    content: String,
}

impl Node {
    fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
    }
    fn child(&self, name: &str) -> Option<&Node> {
        self.children.iter().find(|child| child.name == name)
    }
    fn text(&self) -> String {
        self.content
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    }
    fn descendants<'a>(&'a self, name: &'a str) -> Box<dyn Iterator<Item = &'a Node> + 'a> {
        Box::new(
            std::iter::once(self)
                .filter(move |node| node.name == name)
                .chain(
                    self.children
                        .iter()
                        .flat_map(move |child| child.descendants(name)),
                ),
        )
    }
}

fn local_name(name: &[u8]) -> String {
    String::from_utf8_lossy(name.rsplit(|b| *b == b':').next().unwrap_or(name)).to_ascii_lowercase()
}

fn parse_xml(bytes: &[u8]) -> Result<Node> {
    // XML parsing never resolves external entities. Reject internal entity
    // declarations too, making entity expansion attacks impossible.
    let xml = if bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff]) {
        let little = bytes[0] == 0xff;
        let units = bytes[2..]
            .chunks_exact(2)
            .map(|x| {
                if little {
                    u16::from_le_bytes([x[0], x[1]])
                } else {
                    u16::from_be_bytes([x[0], x[1]])
                }
            })
            .collect::<Vec<_>>();
        String::from_utf16(&units)
            .map_err(|_| Error::InvalidPublication("Invalid UTF-16 XML".into()))?
    } else {
        String::from_utf8(bytes.to_vec())
            .map_err(|_| Error::InvalidPublication("Invalid UTF-8 XML".into()))?
    };
    let xml = xml.replace("&nbsp;", "&#160;");
    let mut reader = Reader::from_str(&xml);
    let mut stack = vec![Node::default()];
    let mut count = 0usize;
    let mut retained_text_bytes = 0usize;
    loop {
        let event = reader
            .read_event()
            .map_err(|error| Error::InvalidPublication(error.to_string()))?;
        let is_empty = matches!(event, Event::Empty(_));
        match event {
            Event::Start(event) | Event::Empty(event) => {
                let mut node = Node {
                    name: local_name(event.name().as_ref()),
                    ..Node::default()
                };
                for attr in event.attributes() {
                    let attr =
                        attr.map_err(|error| Error::InvalidPublication(error.to_string()))?;
                    node.attrs.insert(
                        local_name(attr.key.as_ref()),
                        attr.decode_and_unescape_value(&reader)
                            .map_err(|error| Error::InvalidPublication(error.to_string()))?
                            .into_owned(),
                    );
                }
                count += 1;
                if stack.len() > 128 || count > 200_000 {
                    return Err(Error::InvalidPublication(
                        "XML structure is too complex".into(),
                    ));
                }
                if is_empty {
                    stack.last_mut().unwrap().children.push(node);
                } else {
                    stack.push(node);
                }
            }
            Event::End(_) => {
                if stack.len() <= 1 {
                    return Err(Error::InvalidPublication("Unbalanced XML".into()));
                }
                let node = stack.pop().unwrap();
                let parent = stack.last_mut().unwrap();
                retained_text_bytes = retained_text_bytes.saturating_add(node.content.len());
                if retained_text_bytes > MAX_XML_BYTES * 4 {
                    return Err(Error::InvalidPublication(
                        "XML text structure is too complex".into(),
                    ));
                }
                parent.content.push_str(&node.content);
                parent.children.push(node);
            }
            Event::Text(text) => {
                let text = text
                    .unescape()
                    .map_err(|error| Error::InvalidPublication(error.to_string()))?;
                retained_text_bytes = retained_text_bytes.saturating_add(text.len());
                if retained_text_bytes > MAX_XML_BYTES * 4 {
                    return Err(Error::InvalidPublication(
                        "XML text structure is too complex".into(),
                    ));
                }
                stack.last_mut().unwrap().content.push_str(&text);
            }
            Event::CData(text) => stack
                .last_mut()
                .unwrap()
                .content
                .push_str(&String::from_utf8_lossy(text.as_ref())),
            Event::DocType(text) => {
                if String::from_utf8_lossy(text.as_ref())
                    .to_ascii_uppercase()
                    .contains("ENTITY")
                {
                    return Err(Error::InvalidPublication(
                        "XML entity declarations are not supported".into(),
                    ));
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if stack.len() != 1 {
        return Err(Error::InvalidPublication("Incomplete XML document".into()));
    }
    Ok(stack.pop().unwrap())
}

fn parse_nav(tree: &Node, path: &str) -> Vec<TocEntry> {
    let nav = tree
        .descendants("nav")
        .find(|node| {
            node.attr("type")
                .unwrap_or("")
                .split_whitespace()
                .any(|x| x == "toc")
        })
        .or_else(|| tree.descendants("nav").next());
    fn list(node: &Node, path: &str) -> Vec<TocEntry> {
        node.children
            .iter()
            .filter(|node| node.name == "li")
            .filter_map(|item| {
                let label = item
                    .children
                    .iter()
                    .find(|node| node.name == "a" || node.name == "span")?;
                let href = match label.attr("href") {
                    Some(href) => resolve_archive_href(path, href).ok()?,
                    None => String::new(),
                };
                Some(TocEntry {
                    title: label.text(),
                    href,
                    children: item
                        .child("ol")
                        .map(|node| list(node, path))
                        .unwrap_or_default(),
                })
            })
            .collect()
    }
    nav.and_then(|nav| nav.child("ol"))
        .map(|node| list(node, path))
        .unwrap_or_default()
}

fn parse_ncx(tree: &Node, path: &str) -> Vec<TocEntry> {
    fn point(node: &Node, path: &str) -> Option<TocEntry> {
        let title = node.child("navlabel").map(Node::text).unwrap_or_default();
        let href = resolve_archive_href(path, node.child("content")?.attr("src")?).ok()?;
        Some(TocEntry {
            title,
            href,
            children: node
                .children
                .iter()
                .filter(|x| x.name == "navpoint")
                .filter_map(|x| point(x, path))
                .collect(),
        })
    }
    tree.descendants("navmap")
        .next()
        .map(|map| {
            map.children
                .iter()
                .filter(|x| x.name == "navpoint")
                .filter_map(|x| point(x, path))
                .collect()
        })
        .unwrap_or_default()
}

fn toc_title(toc: &[TocEntry], path: &str) -> Option<String> {
    for entry in toc {
        if entry.href.split('#').next() == Some(path) {
            return Some(entry.title.clone());
        }
        if let Some(title) = toc_title(&entry.children, path) {
            return Some(title);
        }
    }
    None
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Article {
    pub title: String,
    #[serde(default)]
    pub author: String,
    pub source_url: String,
    /// Reader-mode HTML produced locally by a trusted Readability host.
    pub html: String,
    #[serde(default)]
    pub images: Vec<ArticleImage>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArticleImage {
    /// A relative path already used by the supplied HTML, e.g. images/1.jpg.
    pub path: String,
    pub media_type: String,
    pub bytes: Vec<u8>,
}

/// Build a self-contained, offline EPUB from a locally extracted article.
/// Fetching the page and obtaining permission to visit it belong to the shell.
pub fn build_article_epub(article: &Article) -> Result<Vec<u8>> {
    if !article.source_url.starts_with("https://") && !article.source_url.starts_with("http://") {
        return Err(Error::Validation(
            "Article source must be an HTTP or HTTPS URL".into(),
        ));
    }
    if article.title.trim().is_empty() || article.html.len() > MAX_XML_BYTES {
        return Err(Error::Validation(
            "Article title is empty or content is too large".into(),
        ));
    }
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let stored = FileOptions::default().compression_method(CompressionMethod::Stored);
    let deflated = FileOptions::default().compression_method(CompressionMethod::Deflated);
    writer.start_file("mimetype", stored)?;
    writer.write_all(b"application/epub+zip")?;
    writer.start_file("META-INF/container.xml", deflated)?;
    writer.write_all(br#"<?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#)?;
    let mut image_items = String::new();
    let mut names = std::collections::BTreeSet::new();
    for (index, image) in article.images.iter().enumerate() {
        let path = normalize_archive_entry_path(&image.path)?;
        if !path.starts_with("images/")
            || !names.insert(path.clone())
            || image.bytes.len() as u64 > MAX_RESOURCE_BYTES
            || !image.media_type.starts_with("image/")
        {
            return Err(Error::Validation("Article image is invalid".into()));
        }
        writer.start_file(format!("EPUB/{path}"), deflated)?;
        writer.write_all(&image.bytes)?;
        image_items.push_str(&format!(
            "<item id=\"image{index}\" href=\"{}\" media-type=\"{}\"/>",
            escape_xml(&path),
            escape_xml(&image.media_type)
        ));
    }
    let title = escape_xml(article.title.trim());
    let identifier = format!(
        "kodi-article:{}",
        hex::encode(Sha256::digest(article.source_url.as_bytes()))
    );
    let package = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">{identifier}</dc:identifier><dc:title>{title}</dc:title><dc:creator>{}</dc:creator><dc:language>en</dc:language><dc:source>{}</dc:source><meta property="dcterms:modified">2000-01-01T00:00:00Z</meta></metadata><manifest><item id="chapter" href="article.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>{image_items}</manifest><spine><itemref idref="chapter"/></spine></package>"#,
        escape_xml(&article.author),
        escape_xml(&article.source_url)
    );
    writer.start_file("EPUB/package.opf", deflated)?;
    writer.write_all(package.as_bytes())?;
    writer.start_file("EPUB/article.xhtml", deflated)?;
    writer.write_all(format!(r#"<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title><meta charset="utf-8"/></head><body><article><h1>{title}</h1>{}</article></body></html>"#, article.html).as_bytes())?;
    writer.start_file("EPUB/nav.xhtml", deflated)?;
    writer.write_all(format!(r#"<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="article.xhtml">{title}</a></li></ol></nav></body></html>"#).as_bytes())?;
    Ok(writer.finish()?.into_inner())
}

pub(crate) fn escape_xml(text: &str) -> String {
    let text = text.chars().filter(|c| matches!(*c, '\t' | '\n' | '\r' | '\u{20}'..='\u{d7ff}' | '\u{e000}'..='\u{fffd}' | '\u{10000}'..='\u{10ffff}')).collect::<String>();
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
