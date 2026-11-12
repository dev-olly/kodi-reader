use crate::{Error, Result};
use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};

const URI_COMPONENT: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

pub(crate) struct ArchiveReference {
    /// Literal canonical ZIP name; never parse this as a URI a second time.
    pub path: String,
    /// A canonical URI fragment, separate from any '#' in the literal filename.
    fragment: Option<String>,
}

impl ArchiveReference {
    pub fn href(&self) -> String {
        let path = self
            .path
            .split('/')
            .map(|part| utf8_percent_encode(part, URI_COMPONENT).to_string())
            .collect::<Vec<_>>()
            .join("/");
        match &self.fragment {
            Some(fragment) => format!("{path}#{fragment}"),
            None => path,
        }
    }
}

fn decoded(path: &str) -> Result<String> {
    let decoded = percent_decode_str(path)
        .decode_utf8()
        .map_err(|_| Error::UnsafePath(path.into()))?;
    if decoded.contains(['\\', '\0', ':']) || decoded.starts_with('/') {
        return Err(Error::UnsafePath(path.into()));
    }
    Ok(decoded.into_owned())
}

/// Normalizes a relative archive path, rejecting roots, Windows paths and any
/// attempt to escape the archive. Decode only once; no filesystem is consulted.
pub fn normalize_archive_path(path: &str) -> Result<String> {
    let path = decoded(path)?;
    normalize_archive_entry_path(&path)
}

/// ZIP directory entries and canonical parser paths are literal names, not URL
/// references. In particular, `%20` names a percent sign followed by `20` here.
pub(crate) fn normalize_archive_entry_path(path: &str) -> Result<String> {
    if path.contains(['\\', '\0', ':']) || path.starts_with('/') {
        return Err(Error::UnsafePath(path.into()));
    }
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.pop().is_none() {
                    return Err(Error::UnsafePath(path.into()));
                }
            }
            value => parts.push(value),
        }
    }
    if parts.is_empty() {
        return Err(Error::UnsafePath(path.into()));
    }
    Ok(parts.join("/"))
}

/// Resolve an OPF/nav URI reference against the literal canonical ZIP name of
/// its containing document. Returns a canonical archive-relative URI: filename
/// delimiters are percent-encoded and a navigation fragment stays separate.
/// Pass the result directly to `LibraryStore::resource`; do not encode it again.
pub fn resolve_archive_href(document_path: &str, href: &str) -> Result<String> {
    Ok(resolve_archive_reference(document_path, href)?.href())
}

pub(crate) fn resolve_archive_reference(
    document_path: &str,
    href: &str,
) -> Result<ArchiveReference> {
    let (without_fragment, fragment) = href
        .split_once('#')
        .map_or((href, None), |(a, b)| (a, Some(b)));
    let without_query = without_fragment.split('?').next().unwrap_or("");
    let document_path = normalize_archive_entry_path(document_path)?;
    let path = if without_query.is_empty() {
        document_path
    } else {
        let base = document_path.rsplit_once('/').map_or("", |(base, _)| base);
        // The href is a URI reference; the containing document path has already
        // been resolved to a literal ZIP name and must not be decoded again.
        let reference = decoded(without_query)?;
        let joined = if base.is_empty() {
            reference
        } else {
            format!("{base}/{reference}")
        };
        normalize_archive_entry_path(&joined)?
    };
    let fragment = fragment
        .filter(|fragment| !fragment.is_empty())
        .map(|fragment| {
            let decoded = percent_decode_str(fragment)
                .decode_utf8()
                .map_err(|_| Error::UnsafePath(href.into()))?;
            Ok::<_, Error>(utf8_percent_encode(&decoded, URI_COMPONENT).to_string())
        })
        .transpose()?;
    Ok(ArchiveReference { path, fragment })
}

pub(crate) fn safe_relative_file(path: &str) -> Result<std::path::PathBuf> {
    // Filesystem paths do not have URL encoding. Refuse rather than decode them.
    if path.is_empty() || path.contains(['\\', '\0', ':']) || path.starts_with('/') {
        return Err(Error::UnsafePath(path.into()));
    }
    let mut output = std::path::PathBuf::new();
    for component in path.split('/') {
        if component.is_empty() || component == "." || component == ".." {
            return Err(Error::UnsafePath(path.into()));
        }
        output.push(component);
    }
    Ok(output)
}

pub(crate) fn content_filename(id: &str) -> String {
    id.replace(':', "-")
}

pub(crate) fn mime_type(path: &str) -> &'static str {
    match path
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "xhtml" | "xht" => "application/xhtml+xml",
        "html" | "htm" => "text/html",
        "css" => "text/css",
        "js" | "mjs" => "text/javascript",
        "json" => "application/json",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "mp3" => "audio/mpeg",
        "m4a" | "mp4" => "audio/mp4",
        "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        "pdf" => "application/pdf",
        "epub" => "application/epub+zip",
        "xml" | "opf" | "ncx" => "application/xml",
        _ => "application/octet-stream",
    }
}
