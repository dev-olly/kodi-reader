//! Checked, bounded outline traversal. lopdf's convenience outline traversal
//! assumes valid destination arrays and acyclic linked lists; imported PDFs are
//! untrusted, so malformed optional outlines must not prevent reading the pages.
use crate::TocEntry;
use lopdf::{Dictionary, Document, Object, ObjectId};
use std::collections::{BTreeMap, BTreeSet};

const MAX_OUTLINE_NODES: usize = 10_000;
const MAX_DEPTH: usize = 64;

pub(crate) fn table_of_contents(
    document: &Document,
    pages: &BTreeMap<u32, ObjectId>,
) -> Vec<TocEntry> {
    let Ok(catalog) = document.catalog() else {
        return Vec::new();
    };
    let Some(root) = catalog
        .get(b"Outlines")
        .ok()
        .and_then(|value| dictionary(document, value))
    else {
        return Vec::new();
    };
    let Ok(first) = root.get(b"First") else {
        return Vec::new();
    };
    let mut walker = Walker {
        document,
        pages: pages.iter().map(|(number, id)| (*id, *number)).collect(),
        names: BTreeMap::new(),
        visited: BTreeSet::new(),
        remaining: MAX_OUTLINE_NODES,
    };
    if let Some(destinations) = catalog
        .get(b"Dests")
        .ok()
        .and_then(|value| dictionary(document, value))
    {
        for (name, value) in destinations.iter().take(MAX_OUTLINE_NODES) {
            walker.names.insert(name.clone(), value);
        }
    }
    if let Some(tree) = catalog
        .get(b"Names")
        .ok()
        .and_then(|value| dictionary(document, value))
        .and_then(|names| names.get(b"Dests").ok())
    {
        let mut remaining = MAX_OUTLINE_NODES;
        walker.read_name_tree(tree, 0, &mut remaining, &mut BTreeSet::new());
    }
    walker.outline_list(first, 0)
}

fn dictionary<'a>(document: &'a Document, value: &'a Object) -> Option<&'a Dictionary> {
    document.dereference(value).ok()?.1.as_dict().ok()
}

struct Walker<'a> {
    document: &'a Document,
    pages: BTreeMap<ObjectId, u32>,
    names: BTreeMap<Vec<u8>, &'a Object>,
    visited: BTreeSet<ObjectId>,
    remaining: usize,
}

impl<'a> Walker<'a> {
    fn read_name_tree(
        &mut self,
        value: &'a Object,
        depth: usize,
        remaining: &mut usize,
        visited: &mut BTreeSet<ObjectId>,
    ) {
        if depth >= MAX_DEPTH || *remaining == 0 {
            return;
        }
        *remaining -= 1;
        let Ok((id, value)) = self.document.dereference(value) else {
            return;
        };
        if id.is_some_and(|id| !visited.insert(id)) {
            return;
        }
        let Ok(node) = value.as_dict() else {
            return;
        };
        if let Some(names) = node
            .get(b"Names")
            .ok()
            .and_then(|value| self.document.dereference(value).ok())
            .and_then(|(_, value)| value.as_array().ok())
        {
            for pair in names.chunks_exact(2) {
                if *remaining == 0 {
                    break;
                }
                *remaining -= 1;
                if let Ok((_, Object::String(name, _))) = self.document.dereference(&pair[0]) {
                    self.names.insert(name.clone(), &pair[1]);
                }
            }
        }
        if let Some(children) = node
            .get(b"Kids")
            .ok()
            .and_then(|value| self.document.dereference(value).ok())
            .and_then(|(_, value)| value.as_array().ok())
        {
            for child in children {
                self.read_name_tree(child, depth + 1, remaining, visited);
                if *remaining == 0 {
                    break;
                }
            }
        }
    }

    fn outline_list(&mut self, first: &'a Object, depth: usize) -> Vec<TocEntry> {
        let mut entries = Vec::new();
        if depth >= MAX_DEPTH {
            return entries;
        }
        let mut next = Some(first);
        while let Some(value) = next.take() {
            if self.remaining == 0 {
                break;
            }
            self.remaining -= 1;
            let Ok((id, value)) = self.document.dereference(value) else {
                break;
            };
            if id.is_some_and(|id| !self.visited.insert(id)) {
                break;
            }
            let Ok(node) = value.as_dict() else {
                break;
            };
            next = node.get(b"Next").ok();
            let children = node
                .get(b"First")
                .ok()
                .map(|child| self.outline_list(child, depth + 1))
                .unwrap_or_default();
            let title = node
                .get(b"Title")
                .ok()
                .and_then(|value| self.document.dereference(value).ok())
                .and_then(|(_, value)| {
                    (value.as_str().ok()?.len() <= 32 * 1024)
                        .then(|| lopdf::decode_text_string(value).ok())
                        .flatten()
                })
                .map(|title| title.trim().to_owned())
                .filter(|title| !title.is_empty());
            let destination = node.get(b"Dest").ok().or_else(|| {
                let action = dictionary(self.document, node.get(b"A").ok()?)?;
                // URI, JavaScript, Launch and remote-document actions are not
                // local reading targets and are never executed here.
                (action.get(b"S").ok()?.as_name().ok()? == b"GoTo")
                    .then(|| action.get(b"D").ok())
                    .flatten()
            });
            let href = destination
                .and_then(|value| self.destination_page(value, 0))
                .map(|page| format!("#page={page}"))
                // An outline grouping may have children without its own Dest.
                .or_else(|| {
                    (!node.has(b"Dest") && !node.has(b"A"))
                        .then(|| children.first().map(|child| child.href.clone()))
                        .flatten()
                });
            if let (Some(title), Some(href)) = (title, href) {
                entries.push(TocEntry {
                    title,
                    href,
                    children,
                });
            } else {
                // Keep usable descendants when an optional parent is damaged.
                entries.extend(children);
            }
        }
        entries
    }

    fn destination_page(&self, value: &Object, depth: usize) -> Option<u32> {
        if depth >= MAX_DEPTH {
            return None;
        }
        let (_, value) = self.document.dereference(value).ok()?;
        match value {
            Object::Array(values) => {
                let target = values.first()?;
                match target {
                    Object::Reference(id) => self.pages.get(id).copied().or_else(|| {
                        let (id, _) = self.document.dereference(target).ok()?;
                        self.pages.get(&id?).copied()
                    }),
                    // Some producers use a zero-based local page index, which
                    // PDF.js also accepts. Do not mistake it for a page object ID.
                    Object::Integer(index)
                        if *index >= 0 && (*index as u64) < self.pages.len() as u64 =>
                    {
                        u32::try_from(*index).ok()?.checked_add(1)
                    }
                    _ => None,
                }
            }
            Object::Dictionary(value) => self.destination_page(value.get(b"D").ok()?, depth + 1),
            Object::Name(name) | Object::String(name, _) => {
                self.destination_page(self.names.get(name)?, depth + 1)
            }
            _ => None,
        }
    }
}
