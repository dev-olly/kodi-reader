use kodi_reader_core::{resolve_archive_href, LibraryStore};
use std::io::Write;
use zip::{write::FileOptions, ZipWriter};

#[test]
fn literal_percent_names_and_spaces_remain_distinct_through_opf_nav_cover_and_uri_loading() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("percent-paths.epub");
    let mut zip = ZipWriter::new(std::fs::File::create(&source).unwrap());
    for (path, content) in [
        ("META-INF/container.xml", r#"<container><rootfiles><rootfile full-path="OPS%20Folder/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#),
        ("OPS%20Folder/package.opf", r#"<package><metadata><title>Percent and space names</title></metadata><manifest><item id="percent" href="Text/x%2520y.xhtml" media-type="application/xhtml+xml"/><item id="space" href="Text/x%20y.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="toc%2520nav.xhtml" properties="nav" media-type="application/xhtml+xml"/><item id="cover" href="Images/cover%2520image.svg" properties="cover-image" media-type="image/svg+xml"/></manifest><spine><itemref idref="percent"/><itemref idref="space"/></spine></package>"#),
        ("OPS%20Folder/toc%20nav.xhtml", r#"<html xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Navigation</title></head><body><nav epub:type="toc"><ol><li><a href="Text/x%2520y.xhtml#percent">Literal percent</a></li><li><a href="Text/x%20y.xhtml#space">Actual space</a></li></ol></nav></body></html>"#),
        ("OPS%20Folder/Text/x%20y.xhtml", "<html><head><title>Percent</title></head><body><p id=\"percent\">Literal percent chapter.</p></body></html>"),
        ("OPS%20Folder/Text/x y.xhtml", "<html><head><title>Space</title></head><body><p id=\"space\">Actual space chapter.</p></body></html>"),
        ("OPS%20Folder/Images/cover%20image.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"><title>Literal percent cover</title></svg>"),
        ("OPS%20Folder/%2e%2e/innocent.txt", "A literal percent-encoded directory name is not parent traversal."),
    ] {
        zip.start_file(path, FileOptions::default()).unwrap();
        zip.write_all(content.as_bytes()).unwrap();
    }
    zip.finish().unwrap();
    let mut store = LibraryStore::open(directory.path().join("library")).unwrap();
    let book = store.import_document(source).unwrap();
    let publication = store.publication(&book.id).unwrap();
    assert_eq!(
        publication.reading_order[0].href,
        "OPS%2520Folder/Text/x%2520y.xhtml"
    );
    assert_eq!(
        publication.reading_order[1].href,
        "OPS%2520Folder/Text/x%20y.xhtml"
    );
    assert_eq!(publication.toc[0].title, "Literal percent");
    assert_eq!(publication.toc[1].title, "Actual space");
    assert!(store.root().join(book.cover_path.unwrap()).is_file());
    let percent = store
        .resource(&book.id, &publication.reading_order[0].href)
        .unwrap()
        .bytes;
    let space = store
        .resource(&book.id, &publication.reading_order[1].href)
        .unwrap()
        .bytes;
    assert!(String::from_utf8(percent)
        .unwrap()
        .contains("Literal percent chapter"));
    assert!(String::from_utf8(space)
        .unwrap()
        .contains("Actual space chapter"));
    assert!(store
        .resource(&book.id, "OPS%2520Folder/%252e%252e/innocent.txt")
        .is_ok());
    assert!(store.resource(&book.id, "%2e%2e/innocent.txt").is_err());
}

#[test]
fn resolving_hrefs_never_redecodes_the_containing_document_path() {
    assert_eq!(
        resolve_archive_href("OPS%20Folder/toc%20nav.xhtml", "Text/x%2520y.xhtml#stop").unwrap(),
        "OPS%2520Folder/Text/x%2520y.xhtml#stop"
    );
    assert_eq!(
        resolve_archive_href("OPS%20Folder/toc%20nav.xhtml", "#stop").unwrap(),
        "OPS%2520Folder/toc%2520nav.xhtml#stop"
    );
}

#[test]
fn reserved_filename_delimiters_never_become_queries_or_navigation_fragments() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("reserved-paths.epub");
    let mut zip = ZipWriter::new(std::fs::File::create(&source).unwrap());
    for (path, content) in [
        (
            "META-INF/container.xml",
            r#"<container><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
        ),
        (
            "OPS/package.opf",
            r#"<package><metadata><title>Reserved names</title></metadata><manifest><item id="chapter" href="chapter%231%3F.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav%23%3F.xhtml" properties="nav" media-type="application/xhtml+xml"/><item id="cover" href="cover%23%3F.svg" properties="cover-image" media-type="image/svg+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#,
        ),
        (
            "OPS/nav#?.xhtml",
            r#"<html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="chapter%231%3F.xhtml#anchor%23%3F%2520">Reserved chapter</a></li></ol></nav></body></html>"#,
        ),
        (
            "OPS/chapter#1?.xhtml",
            "<html><body><p id=\"anchor#?%20\">Correct reserved filename.</p></body></html>",
        ),
        (
            "OPS/chapter",
            "This filename must never be confused with chapter#1?.xhtml.",
        ),
        (
            "OPS/cover#?.svg",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><title>Reserved cover</title></svg>",
        ),
    ] {
        zip.start_file(path, FileOptions::default()).unwrap();
        zip.write_all(content.as_bytes()).unwrap();
    }
    zip.finish().unwrap();
    let mut store = LibraryStore::open(directory.path().join("library")).unwrap();
    let book = store.import_document(source).unwrap();
    let publication = store.publication(&book.id).unwrap();
    assert_eq!(
        publication.reading_order[0].href,
        "OPS/chapter%231%3F.xhtml"
    );
    assert_eq!(
        publication.reading_order[0].title.as_deref(),
        Some("Reserved chapter")
    );
    assert_eq!(
        publication.toc[0].href,
        "OPS/chapter%231%3F.xhtml#anchor%23%3F%2520"
    );
    assert_eq!(
        publication.cover_href.as_deref(),
        Some("OPS/cover%23%3F.svg")
    );
    assert!(store.root().join(book.cover_path.unwrap()).is_file());
    for href in [
        publication.reading_order[0].href.as_str(),
        publication.toc[0].href.as_str(),
        "OPS/chapter%231%3F.xhtml?cache=one#anchor%23%3F%2520",
    ] {
        let resource = store.resource(&book.id, href).unwrap();
        assert_eq!(resource.media_type, "application/xhtml+xml");
        assert!(String::from_utf8(resource.bytes)
            .unwrap()
            .contains("Correct reserved filename."));
    }
    assert!(store
        .resource(&book.id, publication.cover_href.as_ref().unwrap())
        .is_ok());
    assert_eq!(
        resolve_archive_href("OPS/nav#?.xhtml", "chapter%231%3F.xhtml#anchor%23%3F%2520").unwrap(),
        publication.toc[0].href
    );
}
