//! Three-way editor transactions preserve native updates made while a draft is
//! open. Conflicts are explicit so the renderer can retain its unsaved draft.
use kodi_reader_core::Book;
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};

pub fn merge_book(current: &Book, base: Option<&Book>, edited: Book) -> Result<Book, String> {
    if edited.id != current.id || base.is_some_and(|value| value.id != current.id) {
        return Err("This draft belongs to a different document. Your draft was kept.".into());
    }
    let current_value = serde_json::to_value(current).map_err(|error| error.to_string())?;
    let mut edited_value = serde_json::to_value(edited).map_err(|error| error.to_string())?;
    let mut base_value = base
        .map(serde_json::to_value)
        .transpose()
        .map_err(|error| error.to_string())?;
    let current_object = current_value
        .as_object()
        .ok_or("Invalid current document")?;
    let edited_object = edited_value
        .as_object_mut()
        .ok_or("Invalid edited document")?;
    // Pin service/native fields before diffing. A stale frontend snapshot must
    // never rewind reading progress, relocate an import, or erase bookkeeping.
    let mut preserved: BTreeSet<&str> = [
        "id",
        "kind",
        "importedRelativePath",
        "coverPath",
        "addedAt",
        "lastOpenedAt",
        "position",
        "progress",
    ]
    .into_iter()
    .collect();
    preserved.extend(current.extra.keys().map(String::as_str));
    if let Some(base) = base {
        preserved.extend(base.extra.keys().map(String::as_str));
    }
    // Unknown top-level additions from an editor are bookkeeping too. Only
    // typed, explicitly editable Book fields participate in editor transactions.
    let typed: BTreeSet<&str> = [
        "id",
        "kind",
        "title",
        "author",
        "importedRelativePath",
        "coverPath",
        "addedAt",
        "lastOpenedAt",
        "progress",
        "position",
        "annotations",
        "bookmarks",
        "reminders",
        "chats",
        "readingMarker",
        "sourceUrl",
    ]
    .into_iter()
    .collect();
    let extra_keys: Vec<String> = edited_object
        .keys()
        .filter(|key| !typed.contains(key.as_str()))
        .cloned()
        .collect();
    preserved.extend(extra_keys.iter().map(String::as_str));
    for key in preserved {
        set_optional(edited_object, key, current_object.get(key));
        if let Some(object) = base_value.as_mut().and_then(Value::as_object_mut) {
            set_optional(object, key, current_object.get(key));
        }
    }
    let merged = merge_value(
        Some(&current_value),
        base_value.as_ref(),
        Some(&edited_value),
        "document",
    )?
    .ok_or("An editor transaction cannot remove the document")?;
    validate_unique_ids(&merged, "document")?;
    serde_json::from_value(merged)
        .map_err(|error| format!("The edited document could not be saved: {error}"))
}

fn set_optional(object: &mut Map<String, Value>, key: &str, value: Option<&Value>) {
    if let Some(value) = value {
        object.insert(key.into(), value.clone());
    } else {
        object.remove(key);
    }
}

fn conflict(path: &str) -> String {
    format!("This document changed while you were editing ({path}). Your draft was kept. Reload the latest version and try again.")
}

fn merge_value(
    current: Option<&Value>,
    base: Option<&Value>,
    edited: Option<&Value>,
    path: &str,
) -> Result<Option<Value>, String> {
    // Modification clocks describe the merged content, rather than competing
    // user intent. Independent changes may both advance the same timestamp.
    if path.ends_with(".modifiedAt") {
        if let (Some(a), Some(b)) = (
            current.and_then(Value::as_f64),
            edited.and_then(Value::as_f64),
        ) {
            return Ok(Some(serde_json::json!(a.max(b))));
        }
    }
    if path.ends_with(".createdAt") && current.is_some() {
        return Ok(current.cloned());
    }
    // Option is intentional: a missing field is different from JSON null.
    if edited == base {
        return Ok(current.cloned());
    }
    if current == base || edited == current {
        return Ok(edited.cloned());
    }
    match (current, base, edited) {
        (Some(Value::Object(current)), base, Some(Value::Object(edited)))
            if base.is_none_or(Value::is_object) =>
        {
            let base = base.and_then(Value::as_object);
            let keys: BTreeSet<&str> = current
                .keys()
                .chain(edited.keys())
                .chain(base.into_iter().flat_map(|value| value.keys()))
                .map(String::as_str)
                .collect();
            let mut merged = Map::new();
            for key in keys {
                let path = format!("{path}.{key}");
                if let Some(value) = merge_value(
                    current.get(key),
                    base.and_then(|value| value.get(key)),
                    edited.get(key),
                    &path,
                )? {
                    merged.insert(key.into(), value);
                }
            }
            Ok(Some(Value::Object(merged)))
        }
        (Some(Value::Array(current)), base, Some(Value::Array(edited)))
            if base.is_none_or(Value::is_array) =>
        {
            let base = base
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or_default();
            if !is_id_array(current) || !is_id_array(base) || !is_id_array(edited) {
                return Err(conflict(path));
            }
            let current_map = index_by_id(current, path)?;
            let base_map = index_by_id(base, path)?;
            let edited_map = index_by_id(edited, path)?;
            // Preserve current order and append new editor items in their order.
            let mut order = Vec::new();
            let mut seen = BTreeSet::new();
            for item in current.iter().chain(edited.iter()).chain(base.iter()) {
                let id = item["id"].as_str().unwrap();
                if seen.insert(id) {
                    order.push(id);
                }
            }
            let mut merged = Vec::new();
            for id in order {
                let path = format!("{path}[id={id}]");
                if let Some(value) = merge_value(
                    current_map.get(id).copied(),
                    base_map.get(id).copied(),
                    edited_map.get(id).copied(),
                    &path,
                )? {
                    merged.push(value);
                }
            }
            Ok(Some(Value::Array(merged)))
        }
        _ => Err(conflict(path)),
    }
}

fn is_id_array(values: &[Value]) -> bool {
    values.iter().all(|value| {
        value
            .get("id")
            .and_then(Value::as_str)
            .is_some_and(|id| !id.is_empty())
    })
}

fn index_by_id<'a>(
    values: &'a [Value],
    path: &str,
) -> Result<BTreeMap<&'a str, &'a Value>, String> {
    let mut map = BTreeMap::new();
    for value in values {
        let id = value["id"].as_str().ok_or_else(|| conflict(path))?;
        if map.insert(id, value).is_some() {
            return Err(format!(
                "Duplicate item identifier in {path}. Your draft was kept."
            ));
        }
    }
    Ok(map)
}

fn validate_unique_ids(value: &Value, path: &str) -> Result<(), String> {
    match value {
        Value::Array(values) => {
            if is_id_array(values) {
                index_by_id(values, path)?;
            }
            for value in values {
                validate_unique_ids(value, path)?;
            }
        }
        Value::Object(object) => {
            for (key, value) in object {
                validate_unique_ids(value, &format!("{path}.{key}"))?;
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn book() -> Book {
        serde_json::from_value(json!({
            "id":format!("epub-sha256:{}", "a".repeat(64)), "kind":"epub", "title":"Book", "author":"Author",
            "importedRelativePath":format!("Books/epub-sha256-{}.epub", "a".repeat(64)), "addedAt":10., "lastOpenedAt":20., "progress":0.,
            "annotations":[{"id":"one","locator":{"kind":"epub","spineIndex":0,"start":{"elementPath":[0],"offset":0}},"text":"Quote","note":"Original","color":"yellow","createdAt":10.,"modifiedAt":20.,"sketches":[],"audioRecordings":[]}],
            "bookmarks":[], "reminders":[], "chats":[], "cloudIdentity":"native-bookkeeping"
        })).unwrap()
    }

    #[test]
    fn note_edit_preserves_progress_and_native_bookkeeping() {
        let base = book();
        let mut current = base.clone();
        let mut edited = base.clone();
        current.position = Some(
            serde_json::from_value(
                json!({"kind":"epub","spineIndex":2,"start":{"elementPath":[1],"offset":6}}),
            )
            .unwrap(),
        );
        current.progress = 0.7;
        current.last_opened_at = 50.;
        current.extra.insert("offlineAvailable".into(), json!(true));
        edited.annotations[0].note = Some("Edited".into());
        edited.annotations[0].modified_at = 40.;
        let merged = merge_book(&current, Some(&base), edited).unwrap();
        assert_eq!(merged.position, current.position);
        assert_eq!(merged.progress, 0.7);
        assert_eq!(merged.last_opened_at, 50.);
        assert_eq!(merged.extra, current.extra);
        assert_eq!(merged.annotations[0].note.as_deref(), Some("Edited"));
    }

    #[test]
    fn service_media_append_merges_with_note_edit_and_clocks() {
        let base = book();
        let mut current = base.clone();
        let mut edited = base.clone();
        current.annotations[0]
            .audio_recordings
            .push(json!({"id":"audio","path":"Audio/take.m4a","transcript":"Words"}));
        current.annotations[0].modified_at = 45.;
        edited.annotations[0].note = Some("New thought".into());
        edited.annotations[0].modified_at = 40.;
        let merged = merge_book(&current, Some(&base), edited).unwrap();
        assert_eq!(
            merged.annotations[0].audio_recordings,
            current.annotations[0].audio_recordings
        );
        assert_eq!(merged.annotations[0].note.as_deref(), Some("New thought"));
        assert_eq!(merged.annotations[0].modified_at, 45.);
    }

    #[test]
    fn stale_note_drafts_cannot_change_native_library_visibility() {
        let base = book();
        let mut current = base.clone();
        let mut edited = base.clone();
        current
            .extra
            .insert("removedFromLibrary".into(), json!(true));
        edited.annotations[0].note = Some("Edited while removing".into());
        edited
            .extra
            .insert("removedFromLibrary".into(), json!(false));
        let merged = merge_book(&current, Some(&base), edited).unwrap();
        assert_eq!(merged.extra["removedFromLibrary"], true);
        assert_eq!(
            merged.annotations[0].note.as_deref(),
            Some("Edited while removing")
        );

        let base = merged;
        let mut current = base.clone();
        current.extra.remove("removedFromLibrary");
        let mut edited = base.clone();
        edited.annotations[0].note = Some("Edited while reopening".into());
        let merged = merge_book(&current, Some(&base), edited).unwrap();
        assert!(!merged.extra.contains_key("removedFromLibrary"));
        assert_eq!(
            merged.annotations[0].note.as_deref(),
            Some("Edited while reopening")
        );
    }

    #[test]
    fn concurrent_different_annotations_and_appends_survive() {
        let mut base = book();
        let mut second = base.annotations[0].clone();
        second.id = "two".into();
        base.annotations.push(second);
        let mut current = base.clone();
        let mut edited = base.clone();
        current.annotations[0].note = Some("Native edit one".into());
        edited.annotations[1].note = Some("Editor edit two".into());
        let mut third = current.annotations[0].clone();
        third.id = "three".into();
        current.annotations.push(third);
        let merged = merge_book(&current, Some(&base), edited).unwrap();
        assert_eq!(merged.annotations.len(), 3);
        assert_eq!(
            merged.annotations[0].note.as_deref(),
            Some("Native edit one")
        );
        assert_eq!(
            merged.annotations[1].note.as_deref(),
            Some("Editor edit two")
        );
    }

    #[test]
    fn delete_versus_edit_conflicts_and_keeps_current_data() {
        let base = book();
        let mut current = base.clone();
        let mut edited = base.clone();
        current.annotations[0].note = Some("Changed remotely".into());
        edited.annotations.clear();
        assert!(merge_book(&current, Some(&base), edited).is_err());
        assert_eq!(
            current.annotations[0].note.as_deref(),
            Some("Changed remotely")
        );
        let current = base.clone();
        let mut edited = base.clone();
        edited.annotations.clear();
        assert!(merge_book(&current, Some(&base), edited)
            .unwrap()
            .annotations
            .is_empty());
    }

    #[test]
    fn divergent_same_note_leaf_conflicts_but_independent_fields_merge() {
        let base = book();
        let mut current = base.clone();
        let mut edited = base.clone();
        current.annotations[0].note = Some("Current".into());
        edited.annotations[0].note = Some("Draft".into());
        assert!(merge_book(&current, Some(&base), edited)
            .unwrap_err()
            .contains(".note"));
        let mut edited = base.clone();
        edited.annotations[0].color = "pink".into();
        let merged = merge_book(&current, Some(&base), edited).unwrap();
        assert_eq!(merged.annotations[0].color, "pink");
        assert_eq!(merged.annotations[0].note.as_deref(), Some("Current"));
    }

    #[test]
    fn reading_marker_clear_merges_only_when_current_marker_unchanged() {
        let mut base = book();
        base.reading_marker = Some(
            serde_json::from_value(
                json!({"kind":"epub","spineIndex":0,"start":{"elementPath":[0],"offset":8}}),
            )
            .unwrap(),
        );
        let mut edited = base.clone();
        edited.reading_marker = None;
        assert!(merge_book(&base, Some(&base), edited.clone())
            .unwrap()
            .reading_marker
            .is_none());
        let mut current = base.clone();
        current.reading_marker.as_mut().unwrap().start.offset = 50;
        assert!(merge_book(&current, Some(&base), edited).is_err());
    }

    #[test]
    fn null_and_missing_are_distinct_and_unrelated_missing_fields_survive() {
        let base = json!({"key":null});
        let current = json!({});
        let edited = json!({"key":"edit"});
        assert!(merge_value(Some(&current), Some(&base), Some(&edited), "value").is_err());
        let base = json!({});
        let current = json!({"native":null});
        let edited = json!({"editor":true});
        assert_eq!(
            merge_value(Some(&current), Some(&base), Some(&edited), "value").unwrap(),
            Some(json!({"native":null,"editor":true}))
        );
    }

    #[test]
    fn duplicate_item_ids_are_rejected_and_missing_base_is_conservative() {
        let current = book();
        let mut edited = current.clone();
        edited.annotations.push(edited.annotations[0].clone());
        assert!(merge_book(&current, Some(&current), edited).is_err());
        let mut edited = current.clone();
        edited.annotations[0].note = Some("No merge base".into());
        assert!(merge_book(&current, None, edited).is_err());
        assert_eq!(
            merge_book(&current, None, current.clone()).unwrap(),
            current
        );
    }

    #[test]
    fn native_identity_and_import_paths_cannot_be_replaced_by_a_draft() {
        let base = book();
        let current = base.clone();
        let mut edited = base.clone();
        edited.imported_relative_path = "../../outside.epub".into();
        edited.cover_path = Some("../../outside.png".into());
        edited.kind = kodi_reader_core::DocumentKind::Pdf;
        edited.added_at = 999.;
        edited.title = "A new title".into();
        let merged = merge_book(&current, Some(&base), edited).unwrap();
        assert_eq!(
            merged.imported_relative_path,
            current.imported_relative_path
        );
        assert_eq!(merged.cover_path, current.cover_path);
        assert_eq!(merged.kind, current.kind);
        assert_eq!(merged.added_at, current.added_at);
        assert_eq!(merged.title, "A new title");
        let mut edited = base.clone();
        edited.id = "different".into();
        assert!(merge_book(&current, Some(&base), edited).is_err());
    }
}
