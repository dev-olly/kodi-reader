use crate::epub::escape_xml;
use crate::store::{atomic_write, confined_file};
use crate::{Annotation, Book, Error, LibraryStore, Result};
use pulldown_cmark::{html, CowStr, Event, Options, Parser, Tag, TagEnd};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use zip::{write::FileOptions, CompressionMethod, ZipWriter};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ExportFormat {
    Markdown,
    Html,
    Docx,
    Notion,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportResult {
    pub path: PathBuf,
    pub assets_directory: Option<PathBuf>,
    pub annotation_count: usize,
}

#[derive(Clone)]
struct Asset {
    relative: String,
    bytes: Vec<u8>,
    mime_type: String,
}

struct Section {
    quote: String,
    chapter: Option<String>,
    markdown: String,
    assets: Vec<Asset>,
}

impl LibraryStore {
    /// Export all book annotations, or one explicitly selected annotation.
    /// Assets are copied, never moved; export does not mutate reading data.
    pub fn export_notes(
        &self,
        book_id: &str,
        annotation_id: Option<&str>,
        destination: &Path,
        format: ExportFormat,
    ) -> Result<ExportResult> {
        let book = self.book(book_id)?;
        let annotations = book
            .annotations
            .iter()
            .filter(|note| annotation_id.is_none_or(|id| id == note.id))
            .collect::<Vec<_>>();
        if annotation_id.is_some() && annotations.is_empty() {
            return Err(Error::Validation("Note not found".into()));
        }
        let stem = destination
            .file_stem()
            .and_then(|value| value.to_str())
            .filter(|value| !value.is_empty())
            .unwrap_or("Kodi Notes");
        let assets_name = format!("{stem}-assets");
        let sections = annotations
            .iter()
            .map(|note| section(self.root(), book, note, &assets_name))
            .collect::<Result<Vec<_>>>()?;
        let assets = sections
            .iter()
            .flat_map(|section| section.assets.iter())
            .cloned()
            .collect::<Vec<_>>();
        let parent = destination.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent)?;
        let assets_directory = if assets.is_empty() {
            None
        } else {
            Some(parent.join(&assets_name))
        };
        // Stage the complete asset set before publishing the main document.
        // Existing exports can be replaced after the shell's Save dialog agrees.
        if let Some(directory) = &assets_directory {
            fs::create_dir_all(directory)?;
            let canonical = fs::canonicalize(directory)?;
            let canonical_parent = fs::canonicalize(parent)?;
            if !canonical.starts_with(&canonical_parent) {
                return Err(Error::UnsafePath(directory.display().to_string()));
            }
            for asset in &assets {
                let name = asset
                    .relative
                    .rsplit('/')
                    .next()
                    .ok_or_else(|| Error::UnsafePath(asset.relative.clone()))?;
                atomic_write(&directory.join(name), &asset.bytes)?;
            }
        }
        let output = match format {
            ExportFormat::Markdown | ExportFormat::Notion => {
                markdown_document(book, &sections).into_bytes()
            }
            ExportFormat::Html => html_document(book, &sections).into_bytes(),
            ExportFormat::Docx => docx_document(book, &sections)?,
        };
        atomic_write(destination, &output)?;
        Ok(ExportResult {
            path: destination.to_path_buf(),
            assets_directory,
            annotation_count: annotations.len(),
        })
    }
}

fn section(root: &Path, book: &Book, note: &Annotation, assets_name: &str) -> Result<Section> {
    let mut assets = Vec::new();
    let mut replacements = BTreeMap::new();
    for (kind, media) in [
        ("sketch", &note.sketches),
        ("audio", &note.audio_recordings),
    ] {
        for item in media {
            let Some(id) = string(item, "id") else {
                continue;
            };
            let title = string(item, "title").unwrap_or(if kind == "audio" {
                "Audio note"
            } else {
                "Sketch"
            });
            let paths = if kind == "sketch" {
                vec![string(item, "previewPath"), string(item, "scenePath")]
            } else {
                vec![string(item, "path")]
            };
            let mut links = Vec::new();
            for (index, path) in paths.into_iter().enumerate() {
                let Some(path) = path else {
                    continue;
                };
                let source = confined_file(root, path)?;
                let bytes = fs::read(&source)?;
                let extension = source
                    .extension()
                    .and_then(|value| value.to_str())
                    .unwrap_or("bin")
                    .to_ascii_lowercase();
                let safe_id = uuid::Uuid::parse_str(id)
                    .map(|id| id.to_string())
                    .unwrap_or_else(|_| hex::encode(sha2::Sha256::digest(id.as_bytes())));
                let relative = format!(
                    "{assets_name}/{}-{safe_id}-{index}.{extension}",
                    safe_component(&note.id)
                );
                let mime = crate::paths::mime_type(path).to_string();
                let label = markdown_escape(title);
                links.push(
                    if kind == "sketch" && index == 0 && mime.starts_with("image/") {
                        format!("![{label}]({})", url_path(&relative))
                    } else {
                        format!("[{label}]({})", url_path(&relative))
                    },
                );
                assets.push(Asset {
                    relative,
                    bytes,
                    mime_type: mime,
                });
            }
            if let Some(transcript) =
                string(item, "transcript").filter(|text| !text.trim().is_empty())
            {
                links.push(format!("**Transcript**\n\n{transcript}"));
            }
            let replacement = if links.is_empty() {
                format!("*{} (attachment unavailable)*", markdown_escape(title))
            } else {
                links.join("\n\n")
            };
            replacements.insert(
                format!("kodi-{kind}://{id}").to_ascii_lowercase(),
                replacement,
            );
        }
    }
    for reminder in &book.reminders {
        replacements.insert(
            format!("kodi-reminder://{}", reminder.id).to_ascii_lowercase(),
            format!(
                "- [{}] {}",
                if reminder.completed { "x" } else { " " },
                markdown_escape(&reminder.title)
            ),
        );
    }
    let mut fenced = false;
    let mut fence_char = '`';
    let mut fence_len = 0usize;
    let mut used = BTreeSet::new();
    let mut markdown = String::new();
    for line in note.note.as_deref().unwrap_or("").lines() {
        let trimmed = line.trim();
        if let Some(marker) = trimmed
            .chars()
            .next()
            .filter(|value| *value == '`' || *value == '~')
        {
            let count = trimmed.chars().take_while(|value| *value == marker).count();
            if count >= 3 {
                if !fenced {
                    fenced = true;
                    fence_char = marker;
                    fence_len = count;
                } else if marker == fence_char
                    && count >= fence_len
                    && trimmed[count..].trim().is_empty()
                {
                    fenced = false;
                }
            }
        }
        let target = (!fenced).then(|| reference_target(trimmed)).flatten();
        if let Some(target) = target {
            let target = target.to_ascii_lowercase();
            if let Some(replacement) = replacements.get(&target) {
                used.insert(target);
                markdown.push_str(replacement);
            } else {
                markdown.push_str(line);
            }
        } else {
            markdown.push_str(line);
        }
        markdown.push('\n');
    }
    // Legacy notes may attach media without inserting an inline reference.
    for (key, replacement) in replacements {
        if !used.contains(&key) && !key.starts_with("kodi-reminder://") {
            markdown.push('\n');
            markdown.push_str(&replacement);
            markdown.push('\n');
        }
    }
    Ok(Section {
        quote: note.text.clone(),
        chapter: note.chapter_title.clone(),
        markdown,
        assets,
    })
}

use sha2::Digest;

fn string<'a>(object: &'a Value, name: &str) -> Option<&'a str> {
    object.get(name).and_then(Value::as_str)
}

fn reference_target(line: &str) -> Option<&str> {
    let start = line.rfind("](kodi-")? + 2;
    if !line.starts_with('[') || !line.ends_with(')') {
        return None;
    }
    Some(&line[start..line.len() - 1])
}

fn safe_component(text: &str) -> String {
    let value = text
        .chars()
        .filter(|value| value.is_ascii_alphanumeric() || *value == '-')
        .take(80)
        .collect::<String>();
    if value.is_empty() {
        "note".into()
    } else {
        value
    }
}

fn markdown_escape(text: &str) -> String {
    text.replace('\\', "\\\\")
        .replace('[', "\\[")
        .replace(']', "\\]")
        .replace('*', "\\*")
        .replace('_', "\\_")
        .replace('\n', " ")
}

fn url_path(text: &str) -> String {
    text.split('/')
        .map(|part| {
            percent_encoding::utf8_percent_encode(part, percent_encoding::NON_ALPHANUMERIC)
                .to_string()
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn markdown_document(book: &Book, sections: &[Section]) -> String {
    let mut output = format!(
        "# {}\n\n{}\n\n",
        markdown_escape(&book.title),
        markdown_escape(&book.author)
    );
    if let Some(source) = &book.source_url {
        output.push_str(&format!(
            "Source: <{}>\n\n",
            source.replace(['<', '>', '\n', '\r'], "")
        ));
    }
    for section in sections {
        if let Some(chapter) = &section.chapter {
            output.push_str(&format!("## {}\n\n", markdown_escape(chapter)));
        }
        for line in section.quote.lines() {
            output.push_str(&format!("> {line}\n"));
        }
        output.push('\n');
        output.push_str(&section.markdown);
        output.push_str("\n---\n\n");
    }
    output
}

/// Exported HTML treats note Markdown as content. Raw HTML and active URL
/// schemes cannot introduce scripts when the exported file is opened.
fn render_markdown(markdown: &str) -> String {
    let parser = Parser::new_ext(
        markdown,
        Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS | Options::ENABLE_STRIKETHROUGH,
    )
    .map(|event| match event {
        Event::Html(value) | Event::InlineHtml(value) => Event::Text(value),
        Event::Start(Tag::Link {
            link_type,
            dest_url,
            title,
            id,
        }) => Event::Start(Tag::Link {
            link_type,
            dest_url: safe_url(dest_url),
            title,
            id,
        }),
        Event::Start(Tag::Image {
            link_type,
            dest_url,
            title,
            id,
        }) => Event::Start(Tag::Image {
            link_type,
            dest_url: safe_url(dest_url),
            title,
            id,
        }),
        other => other,
    });
    let mut output = String::new();
    html::push_html(&mut output, parser);
    output
}

fn safe_url(value: CowStr<'_>) -> CowStr<'_> {
    let lower = value.trim().to_ascii_lowercase();
    if lower.starts_with("https://")
        || lower.starts_with("http://")
        || lower.starts_with("mailto:")
        || !lower.contains(':')
    {
        value
    } else {
        "#".into()
    }
}

fn html_document(book: &Book, sections: &[Section]) -> String {
    let mut body = format!(
        "<h1>{}</h1><p>{}</p>",
        escape_xml(&book.title),
        escape_xml(&book.author)
    );
    for section in sections {
        if let Some(chapter) = &section.chapter {
            body.push_str(&format!("<h2>{}</h2>", escape_xml(chapter)));
        }
        body.push_str(&format!(
            "<blockquote>{}</blockquote>{}<hr/>",
            escape_xml(&section.quote).replace('\n', "<br/>"),
            render_markdown(&section.markdown)
        ));
    }
    format!(
        r#"<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><title>{}</title><style>body{{font:17px/1.6 system-ui,sans-serif;max-width:760px;margin:48px auto;padding:0 24px;color:#242424}}blockquote{{border-left:3px solid #d0d0d0;padding-left:18px;color:#666}}img{{max-width:100%;height:auto}}pre{{overflow:auto;background:#f5f5f5;padding:12px}}table{{border-collapse:collapse}}td,th{{border:1px solid #ddd;padding:8px}}hr{{border:0;border-top:1px solid #ddd;margin:32px 0}}</style></head><body>{body}</body></html>"#,
        escape_xml(&book.title)
    )
}

fn docx_document(book: &Book, sections: &[Section]) -> Result<Vec<u8>> {
    let mut body = String::new();
    body.push_str(&paragraph(&book.title, Some("Title")));
    body.push_str(&paragraph(&book.author, Some("Subtitle")));
    let mut relationships = String::from(
        r#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#,
    );
    let mut embedded = Vec::new();
    let mut types = BTreeMap::new();
    let mut rel_index = 0usize;
    for section in sections {
        if let Some(chapter) = &section.chapter {
            body.push_str(&paragraph(chapter, Some("Heading1")));
        }
        body.push_str(&paragraph(&section.quote, Some("Quote")));
        body.push_str(&docx_markdown(
            &section.markdown,
            &mut relationships,
            &mut rel_index,
        ));
        for asset in &section.assets {
            rel_index += 1;
            let rel = format!("rId{rel_index}");
            let filename = asset.relative.rsplit('/').next().unwrap();
            if matches!(
                asset.mime_type.as_str(),
                "image/png" | "image/jpeg" | "image/gif"
            ) {
                let extension = filename.rsplit('.').next().unwrap_or("png");
                types.insert(extension.to_string(), asset.mime_type.clone());
                relationships.push_str(&format!(r#"<Relationship Id="{rel}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/{}"/>"#, escape_xml(filename)));
                let (image_width, image_height) = image_extent(&asset.bytes);
                body.push_str(&format!(r#"<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="{image_width}" cy="{image_height}"/><wp:docPr id="{rel_index}" name="Sketch {rel_index}"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="{rel_index}" name="{}"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="{rel}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{image_width}" cy="{image_height}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"#, escape_xml(filename)));
                embedded.push((format!("word/media/{filename}"), asset.bytes.clone()));
            } else {
                relationships.push_str(&format!(r#"<Relationship Id="{rel}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="{}" TargetMode="External"/>"#, escape_xml(&url_path(&asset.relative))));
                body.push_str(&format!(r#"<w:p><w:hyperlink r:id="{rel}"><w:r><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr><w:t>{}</w:t></w:r></w:hyperlink></w:p>"#, escape_xml(filename)));
            }
        }
    }
    relationships.push_str("</Relationships>");
    body.push_str(r#"<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>"#);
    let document = format!(
        r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>{body}</w:body></w:document>"#
    );
    let mut content_types = String::from(
        r#"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>"#,
    );
    for (extension, mime) in types {
        content_types.push_str(&format!(
            "<Default Extension=\"{}\" ContentType=\"{}\"/>",
            escape_xml(&extension),
            escape_xml(&mime)
        ));
    }
    content_types.push_str("</Types>");
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let options = FileOptions::default().compression_method(CompressionMethod::Deflated);
    let styles = r#"<?xml version="1.0" encoding="UTF-8"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/><w:pPr><w:spacing w:after="160"/></w:pPr></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:rPr><w:color w:val="666666"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="Heading 1"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="360"/></w:pPr><w:rPr><w:i/><w:color w:val="666666"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:sz w:val="20"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="360"/></w:pPr></w:style></w:styles>"#;
    for (name, content) in [
        ("[Content_Types].xml", content_types.as_str()),
        (
            "_rels/.rels",
            r#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#,
        ),
        ("word/document.xml", document.as_str()),
        ("word/_rels/document.xml.rels", relationships.as_str()),
        ("word/styles.xml", styles),
    ] {
        writer.start_file(name, options)?;
        writer.write_all(content.as_bytes())?;
    }
    for (name, bytes) in embedded {
        writer.start_file(name, options)?;
        writer.write_all(&bytes)?;
    }
    Ok(writer.finish()?.into_inner())
}

fn paragraph(text: &str, style: Option<&str>) -> String {
    let properties = style
        .map(|style| format!("<w:pPr><w:pStyle w:val=\"{style}\"/></w:pPr>"))
        .unwrap_or_default();
    let text = text
        .split('\n')
        .map(|line| format!("<w:t xml:space=\"preserve\">{}</w:t>", escape_xml(line)))
        .collect::<Vec<_>>()
        .join("<w:br/>");
    format!("<w:p>{properties}<w:r>{text}</w:r></w:p>")
}

fn rich_paragraph(runs: &str, style: Option<&str>) -> String {
    let properties = style
        .map(|style| format!("<w:pPr><w:pStyle w:val=\"{style}\"/></w:pPr>"))
        .unwrap_or_default();
    format!("<w:p>{properties}{runs}</w:p>")
}

fn word_run(
    text: &str,
    bold: bool,
    italic: bool,
    strike: bool,
    code: bool,
    link: Option<&str>,
) -> String {
    let mut properties = String::new();
    if bold {
        properties.push_str("<w:b/>");
    }
    if italic {
        properties.push_str("<w:i/>");
    }
    if strike {
        properties.push_str("<w:strike/>");
    }
    if code {
        properties.push_str("<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\"/>");
    }
    if link.is_some() {
        properties.push_str("<w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/>");
    }
    let text = text
        .split('\n')
        .map(|part| format!("<w:t xml:space=\"preserve\">{}</w:t>", escape_xml(part)))
        .collect::<Vec<_>>()
        .join("<w:br/>");
    let run = format!("<w:r><w:rPr>{properties}</w:rPr>{text}</w:r>");
    link.map(|id| format!("<w:hyperlink r:id=\"{id}\">{run}</w:hyperlink>"))
        .unwrap_or(run)
}

fn docx_markdown(
    markdown: &str,
    relationships: &mut String,
    relationship_id: &mut usize,
) -> String {
    let mut output = String::new();
    let mut runs = String::new();
    let (mut bold, mut italic, mut strike) = (false, false, false);
    let (mut code, mut list_depth, mut heading, mut quote) = (false, 0u32, false, 0u32);
    let mut link: Option<String> = None;
    let mut table_header = false;
    let mut image_depth = 0u32;
    for event in Parser::new_ext(
        markdown,
        Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS | Options::ENABLE_STRIKETHROUGH,
    ) {
        match event {
            Event::Start(Tag::Strong) => bold = true,
            Event::End(TagEnd::Strong) => bold = false,
            Event::Start(Tag::Emphasis) => italic = true,
            Event::End(TagEnd::Emphasis) => italic = false,
            Event::Start(Tag::Strikethrough) => strike = true,
            Event::End(TagEnd::Strikethrough) => strike = false,
            Event::Start(Tag::CodeBlock(_)) => code = true,
            Event::Start(Tag::Heading { .. }) => heading = true,
            Event::Start(Tag::BlockQuote(_)) => quote += 1,
            Event::End(TagEnd::BlockQuote(_)) => quote = quote.saturating_sub(1),
            Event::Start(Tag::List(_)) => list_depth += 1,
            Event::End(TagEnd::List(_)) => list_depth = list_depth.saturating_sub(1),
            Event::Start(Tag::Item) => runs.push_str(&word_run("• ", false, false, false, false, None)),
            Event::TaskListMarker(checked) => runs.push_str(&word_run(if checked { "☑ " } else { "☐ " }, false, false, false, false, None)),
            Event::Start(Tag::Link { dest_url, .. }) => {
                let destination = safe_url(dest_url).into_string();
                if destination != "#" {
                    *relationship_id += 1;
                    let id = format!("rId{relationship_id}");
                    relationships.push_str(&format!("<Relationship Id=\"{id}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"{}\" TargetMode=\"External\"/>", escape_xml(&destination)));
                    link = Some(id);
                }
            },
            Event::End(TagEnd::Link) => link = None,
            Event::Start(Tag::Image { .. }) => image_depth += 1,
            Event::End(TagEnd::Image) => image_depth = image_depth.saturating_sub(1),
            Event::Text(text) if image_depth == 0 => runs.push_str(&word_run(&text, bold || table_header, italic, strike, code, link.as_deref())),
            Event::Code(text) if image_depth == 0 => runs.push_str(&word_run(&text, bold || table_header, italic, strike, true, link.as_deref())),
            Event::SoftBreak | Event::HardBreak if image_depth == 0 => runs.push_str("<w:r><w:br/></w:r>"),
            Event::Start(Tag::Table(_)) => output.push_str("<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:color=\"DDDDDD\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"DDDDDD\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:color=\"DDDDDD\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:color=\"DDDDDD\"/></w:tblBorders></w:tblPr>"),
            Event::Start(Tag::TableHead) => { table_header = true; output.push_str("<w:tr>"); },
            Event::End(TagEnd::TableHead) => { table_header = false; output.push_str("</w:tr>"); },
            Event::Start(Tag::TableRow) => output.push_str("<w:tr>"),
            Event::End(TagEnd::TableRow) => output.push_str("</w:tr>"),
            Event::Start(Tag::TableCell) => runs.clear(),
            Event::End(TagEnd::TableCell) => {
                output.push_str(&format!("<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr>{}</w:tc>", rich_paragraph(&runs, None)));
                runs.clear();
            },
            Event::End(TagEnd::Table) => output.push_str("</w:tbl><w:p/>"),
            Event::Rule => output.push_str("<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"DDDDDD\"/></w:pBdr></w:pPr></w:p>"),
            Event::End(TagEnd::Paragraph | TagEnd::Heading(_) | TagEnd::Item | TagEnd::CodeBlock) => {
                if !runs.is_empty() {
                    let style = if code { Some("Code") } else if heading { Some("Heading1") } else if list_depth > 0 { Some("ListParagraph") } else if quote > 0 { Some("Quote") } else { None };
                    output.push_str(&rich_paragraph(&runs, style)); runs.clear();
                }
                if matches!(event, Event::End(TagEnd::CodeBlock)) { code = false; }
                if matches!(event, Event::End(TagEnd::Heading(_))) { heading = false; }
            },
            _ => {},
        }
    }
    if !runs.is_empty() {
        output.push_str(&rich_paragraph(&runs, None));
    }
    output
}

fn image_extent(bytes: &[u8]) -> (u64, u64) {
    let dimensions = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") && bytes.len() >= 24 {
        Some((
            u32::from_be_bytes(bytes[16..20].try_into().unwrap()),
            u32::from_be_bytes(bytes[20..24].try_into().unwrap()),
        ))
    } else if bytes.starts_with(b"GIF8") && bytes.len() >= 10 {
        Some((
            u16::from_le_bytes([bytes[6], bytes[7]]) as u32,
            u16::from_le_bytes([bytes[8], bytes[9]]) as u32,
        ))
    } else {
        None
    };
    let (width, height) = dimensions
        .filter(|(width, height)| *width > 0 && *height > 0)
        .unwrap_or((3, 2));
    let scale = (4_572_000. / f64::from(width)).min(7_315_200. / f64::from(height));
    (
        (f64::from(width) * scale).round() as u64,
        (f64::from(height) * scale).round() as u64,
    )
}
