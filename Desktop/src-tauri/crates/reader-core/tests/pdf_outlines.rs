use kodi_reader_core::{LibraryStore, Publication};
use lopdf::{dictionary, Document, Object, ObjectId, Stream};
use std::fs;
use tempfile::TempDir;

fn two_page_pdf() -> (Document, ObjectId, [ObjectId; 2]) {
    let mut document = Document::with_version("1.7");
    let pages_id = document.new_object_id();
    let content = document.add_object(Stream::new(dictionary! {}, Vec::new()));
    let page_one = document.add_object(dictionary! {
        "Type"=>"Page", "Parent"=>pages_id, "Contents"=>content,
        "MediaBox"=>vec![0.into(),0.into(),600.into(),800.into()]
    });
    let page_two = document.add_object(dictionary! {
        "Type"=>"Page", "Parent"=>pages_id, "Contents"=>content,
        "MediaBox"=>vec![0.into(),0.into(),600.into(),800.into()]
    });
    document.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type"=>"Pages", "Kids"=>vec![page_one.into(),page_two.into()], "Count"=>2
        }),
    );
    let catalog = document.add_object(dictionary! {"Type"=>"Catalog", "Pages"=>pages_id});
    document.trailer.set("Root", catalog);
    (document, catalog, [page_one, page_two])
}

fn import_publication(mut document: Document) -> Publication {
    let directory = TempDir::new().unwrap();
    let source = directory.path().join("outlined.pdf");
    document.save(&source).unwrap();
    let original = fs::read(&source).unwrap();
    let mut store = LibraryStore::open(directory.path().join("library")).unwrap();
    let book = store.import_document(&source).unwrap();
    let publication = store.publication(&book.id).unwrap();
    assert_eq!(
        fs::read(store.document_path(&book.id).unwrap()).unwrap(),
        original
    );
    publication
}

#[test]
fn nested_pdf_outlines_resolve_direct_and_named_targets_without_collapsing_titles() {
    let (mut document, catalog, pages) = two_page_pdf();
    let outlines = document.new_object_id();
    let parent = document.new_object_id();
    let child = document.new_object_id();
    let sibling = document.new_object_id();
    document.objects.insert(
        parent,
        Object::Dictionary(dictionary! {
            "Title"=>Object::string_literal("Page Two"), "Parent"=>outlines,
            "Dest"=>vec![pages[1].into(),Object::Name(b"Fit".to_vec())],
            "First"=>child, "Last"=>child, "Next"=>sibling
        }),
    );
    document.objects.insert(
        child,
        Object::Dictionary(dictionary! {
            "Title"=>lopdf::text_string("Überblick / 章"), "Parent"=>parent,
            "A"=>dictionary! {"S"=>"GoTo", "D"=>Object::string_literal("first-page")}
        }),
    );
    document.objects.insert(
        sibling,
        Object::Dictionary(dictionary! {
            "Title"=>Object::string_literal("Page Two"), "Parent"=>outlines, "Prev"=>parent,
            "Dest"=>Object::Name(b"legacy-page-one".to_vec())
        }),
    );
    document.objects.insert(
        outlines,
        Object::Dictionary(dictionary! {
            "Type"=>"Outlines", "First"=>parent, "Last"=>sibling, "Count"=>3
        }),
    );
    let named_target = document.add_object(dictionary! {
        "D"=>vec![pages[0].into(), Object::Name(b"Fit".to_vec())]
    });
    let leaf = document.add_object(dictionary! {
        "Names"=>vec![Object::string_literal("first-page"), named_target.into()]
    });
    let tree = document.add_object(dictionary! {"Kids"=>vec![leaf.into()]});
    let catalog = document.get_dictionary_mut(catalog).unwrap();
    catalog.set("Outlines", outlines);
    catalog.set("Names", dictionary! {"Dests"=>tree});
    catalog.set(
        "Dests",
        dictionary! {
            "legacy-page-one"=>vec![pages[0].into(),Object::Name(b"Fit".to_vec())]
        },
    );
    let publication = import_publication(document);
    assert_eq!(publication.reading_order.len(), 2);
    assert_eq!(publication.toc.len(), 2);
    assert_eq!(publication.toc[0].title, "Page Two");
    assert_eq!(publication.toc[0].href, publication.reading_order[1].href);
    assert_eq!(publication.toc[0].children[0].title, "Überblick / 章");
    assert_eq!(publication.toc[0].children[0].href, "#page=1");
    assert_eq!(publication.toc[1].title, "Page Two");
    assert_eq!(publication.toc[1].href, "#page=1");
}

#[test]
fn malformed_and_cyclic_outlines_are_bounded_and_remote_actions_are_not_local_targets() {
    let (mut document, catalog, pages) = two_page_pdf();
    let outlines = document.new_object_id();
    let broken = document.new_object_id();
    let valid = document.new_object_id();
    let remote = document.new_object_id();
    let named_loop = document.new_object_id();
    let name_tree = document.new_object_id();
    document.objects.insert(
        broken,
        Object::Dictionary(dictionary! {
            "Title"=>Object::string_literal("Broken"), "Dest"=>Vec::<Object>::new(), "Next"=>valid
        }),
    );
    document.objects.insert(
        valid,
        Object::Dictionary(dictionary! {
            "Title"=>Object::string_literal("Valid Page Two"), "First"=>valid, "Next"=>remote,
            "A"=>dictionary! {"S"=>"GoTo", "D"=>vec![pages[1].into(),Object::Name(b"Fit".to_vec())]}
        }),
    );
    document.objects.insert(remote, Object::Dictionary(dictionary! {
        "Title"=>Object::string_literal("Other document"), "Next"=>named_loop,
        "A"=>dictionary! {"S"=>"GoToR", "F"=>Object::string_literal("other.pdf"), "D"=>vec![pages[0].into(),Object::Name(b"Fit".to_vec())]}
    }));
    document.objects.insert(named_loop, Object::Dictionary(dictionary! {
        "Title"=>Object::string_literal("Cyclic named target"), "Dest"=>Object::string_literal("loop"), "Next"=>broken
    }));
    document.objects.insert(name_tree, Object::Dictionary(dictionary! {
        "Kids"=>vec![name_tree.into()],
        "Names"=>vec![Object::string_literal("loop"),Object::Dictionary(dictionary! {"D"=>Object::string_literal("loop")})]
    }));
    document
        .objects
        .insert(outlines, Object::Dictionary(dictionary! {"First"=>broken}));
    let catalog = document.get_dictionary_mut(catalog).unwrap();
    catalog.set("Outlines", outlines);
    catalog.set("Names", dictionary! {"Dests"=>name_tree});
    let publication = import_publication(document);
    assert_eq!(publication.toc.len(), 1);
    assert_eq!(publication.toc[0].title, "Valid Page Two");
    assert_eq!(publication.toc[0].href, "#page=2");
    assert!(publication.toc[0].children.is_empty());
}
