use kodi_reader_core::{Library, LibraryStore};
use std::path::Path;

/// Selected documents are independent imports: retain every successful result,
/// continue past invalid files, and let the shell report all failures together.
pub(crate) fn import_selected<I, P>(store: &mut LibraryStore, paths: I) -> (Library, Vec<String>)
where
    I: IntoIterator<Item = P>,
    P: AsRef<Path>,
{
    let mut failures = Vec::new();
    for path in paths {
        let path = path.as_ref();
        if let Err(error) = store.import_document(path) {
            let name = path
                .file_name()
                .unwrap_or(path.as_os_str())
                .to_string_lossy();
            failures.push(format!("{name}: {error}"));
        }
    }
    (store.snapshot(), failures)
}

#[cfg(test)]
mod tests {
    use super::*;
    use kodi_reader_core::{build_article_epub, Article};

    #[test]
    fn failed_selection_does_not_hide_or_skip_successful_imports() {
        let directory = tempfile::tempdir().unwrap();
        let mut paths = Vec::new();
        for title in ["First", "Broken", "Last"] {
            let path = directory.path().join(format!("{title}.epub"));
            let bytes = if title == "Broken" {
                b"not a ZIP archive".to_vec()
            } else {
                build_article_epub(&Article {
                    title: title.into(),
                    author: "Author".into(),
                    source_url: "https://example.com".into(),
                    html: "<p>Reading text.</p>".into(),
                    images: Vec::new(),
                })
                .unwrap()
            };
            std::fs::write(&path, bytes).unwrap();
            paths.push(path);
        }
        let root = directory.path().join("library");
        let mut store = LibraryStore::open(root.clone()).unwrap();
        let (snapshot, failures) = import_selected(&mut store, paths);
        assert_eq!(snapshot.books.len(), 2);
        assert!(snapshot.books.values().any(|book| book.title == "First"));
        assert!(snapshot.books.values().any(|book| book.title == "Last"));
        assert_eq!(failures.len(), 1);
        assert!(failures[0].starts_with("Broken.epub:"));
        assert_eq!(LibraryStore::open(root).unwrap().snapshot(), snapshot);
    }
}
