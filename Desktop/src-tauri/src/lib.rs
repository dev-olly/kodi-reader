mod book_merge;
mod chapter;
mod layout;
mod library_operations;
mod narration_state;
mod reader;
mod service_commands;
mod sketch_files;
mod sync_preferences;

use base64::Engine;
use kodi_reader_core::{Book, Library, LibraryStore, ReaderSettings};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    sync::Mutex,
};
use tauri::{Emitter, Manager, State, Webview};

pub(crate) type Result<T> = std::result::Result<T, String>;

pub(crate) struct NativeState {
    pub library: Mutex<LibraryStore>,
    pub reader: Mutex<Option<reader::ReaderSession>>,
    pub bounds: Mutex<Bounds>,
    pub sketches: Mutex<std::collections::HashMap<String, SketchSession>>,
    pub opening: std::sync::atomic::AtomicU64,
    pub open_gate: tokio::sync::Mutex<()>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize)]
pub(crate) struct Bounds {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone)]
pub(crate) struct SketchSession {
    pub book_id: String,
    pub annotation_id: String,
    pub sketch_id: String,
}

pub(crate) fn ui(view: &Webview) -> Result<()> {
    if view.label() == "main-ui" {
        Ok(())
    } else {
        Err("This operation is only available to Kodi Reader's interface.".into())
    }
}

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> Result<std::sync::MutexGuard<'_, T>> {
    mutex.lock().map_err(|_| {
        "A native service stopped unexpectedly. Restart Kodi Reader to recover.".into()
    })
}

pub(crate) fn changed(app: &tauri::AppHandle, library: Library) -> Result<Library> {
    app.emit_to("main-ui", "library-changed", &library)
        .map_err(|e| e.to_string())?;
    Ok(library)
}

#[tauri::command]
fn library_get(view: Webview, state: State<NativeState>) -> Result<Library> {
    ui(&view)?;
    Ok(lock(&state.library)?.snapshot())
}

#[tauri::command]
async fn import_documents(
    view: Webview,
    app: tauri::AppHandle,
    paths: Vec<String>,
) -> Result<Library> {
    ui(&view)?;
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<NativeState>();
        let mut store = lock(&state.library)?;
        let (snapshot, failures) = library_operations::import_selected(&mut store, paths);
        // Publish committed successes even when a different selected file fails.
        let snapshot = changed(&app, snapshot)?;
        if !failures.is_empty() {
            return Err(format!(
                "Some documents could not be imported:\n{}",
                failures.join("\n")
            ));
        }
        Ok(snapshot)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
fn book_rename(
    view: Webview,
    app: tauri::AppHandle,
    state: State<NativeState>,
    book_id: String,
    title: String,
) -> Result<Library> {
    ui(&view)?;
    if title.trim().is_empty() || title.len() > 1000 {
        return Err("Enter a document title between 1 and 1,000 characters.".into());
    }
    let result = lock(&state.library)?
        .mutate(|library| {
            let book = library
                .books
                .get_mut(&book_id)
                .ok_or_else(|| kodi_reader_core::Error::Validation("Document not found".into()))?;
            book.title = title.trim().into();
            Ok(())
        })
        .map_err(|e| e.to_string())?;
    changed(&app, result)
}

#[tauri::command]
async fn book_delete(
    view: Webview,
    app: tauri::AppHandle,
    state: State<'_, NativeState>,
    book_id: String,
    delete_data: bool,
) -> Result<Library> {
    ui(&view)?;
    let _transition = state.open_gate.lock().await;
    // Cancel pending opens, even before a download has created its reader.
    // Finish native reader ownership before removing its backing document.
    let active = reader::begin_book_removal(&state, &book_id)?;
    if active {
        if let Some(reader) = app.get_webview("book-reader") {
            reader.close().map_err(|error| error.to_string())?;
        }
        *lock(&state.reader)? = None;
    }
    if !delete_data {
        let mut store = lock(&state.library)?;
        store
            .remove_from_library(&book_id)
            .map_err(|error| error.to_string())?;
        return changed(&app, store.snapshot());
    }
    let (snapshot, cleanup_errors) = {
        let mut store = lock(&state.library)?;
        let errors = store
            .delete_book(&book_id)
            .map_err(|error| error.to_string())?;
        (store.snapshot(), errors)
    };
    let snapshot = changed(&app, snapshot)?;
    if !cleanup_errors.is_empty() {
        return Err(format!(
            "The document was removed, but some local files could not be cleaned up:\n{}",
            cleanup_errors.join("\n")
        ));
    }
    Ok(snapshot)
}

#[tauri::command]
fn library_save_book(
    view: Webview,
    app: tauri::AppHandle,
    state: State<NativeState>,
    book: Book,
    base: Option<Book>,
) -> Result<Library> {
    ui(&view)?;
    let result = lock(&state.library)?
        .mutate(|library| {
            let old = library
                .books
                .get(&book.id)
                .ok_or_else(|| kodi_reader_core::Error::Validation("Document not found".into()))?;
            if old.imported_relative_path != book.imported_relative_path
                || old.cover_path != book.cover_path
                || old.kind != book.kind
            {
                return Err(kodi_reader_core::Error::Validation(
                    "Document file locations cannot be changed by the editor".into(),
                ));
            }
            let merged = book_merge::merge_book(old, base.as_ref(), book)
                .map_err(kodi_reader_core::Error::Validation)?;
            library.books.insert(merged.id.clone(), merged);
            Ok(())
        })
        .map_err(|e| e.to_string())?;
    let _ = reader::refresh(&app);
    changed(&app, result)
}

#[tauri::command]
fn settings_save(
    view: Webview,
    app: tauri::AppHandle,
    state: State<NativeState>,
    settings: ReaderSettings,
    goal_minutes: u32,
) -> Result<Library> {
    ui(&view)?;
    if !(5..=1440).contains(&goal_minutes) {
        return Err("The daily goal must be between 5 minutes and 24 hours.".into());
    }
    let result = lock(&state.library)?
        .mutate(|library| {
            library.settings = settings;
            library.goal_minutes = goal_minutes;
            Ok(())
        })
        .map_err(|e| e.to_string())?;
    let _ = reader::refresh(&app);
    changed(&app, result)
}

#[tauri::command]
fn read_activity(
    view: Webview,
    app: tauri::AppHandle,
    state: State<NativeState>,
    seconds: u64,
    date: Option<String>,
) -> Result<Library> {
    ui(&view)?;
    if seconds > 60 {
        return Err("Reading activity must be recorded in intervals of at most 60 seconds.".into());
    }
    let date = date.unwrap_or_else(service_commands::local_day);
    let result = lock(&state.library)?
        .add_reading_seconds(&date, seconds)
        .map_err(|e| e.to_string())?;
    changed(&app, result)
}

#[tauri::command]
fn publication_get(
    view: Webview,
    state: State<NativeState>,
    book_id: String,
) -> Result<kodi_reader_core::Publication> {
    ui(&view)?;
    lock(&state.library)?
        .publication(&book_id)
        .map_err(|e| e.to_string())
}

fn safe_relative(root: &Path, relative: &str) -> Result<PathBuf> {
    let path = Path::new(relative);
    if path.is_absolute()
        || path
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
    {
        return Err("Invalid library resource path.".into());
    }
    let base = root.canonicalize().map_err(|e| e.to_string())?;
    let full = root.join(path).canonicalize().map_err(|e| e.to_string())?;
    if !full.starts_with(&base) {
        return Err("This file is outside the library.".into());
    }
    Ok(full)
}

#[tauri::command]
fn media_read(view: Webview, state: State<NativeState>, relative_path: String) -> Result<String> {
    ui(&view)?;
    let root = lock(&state.library)?.root().to_path_buf();
    let full = safe_relative(&root, &relative_path)?;
    let data = std::fs::read(full).map_err(|e| e.to_string())?;
    if data.len() > 64 * 1024 * 1024 {
        return Err("Use the audio player to open recordings larger than 64 MiB.".into());
    }
    Ok(base64::engine::general_purpose::STANDARD.encode(data))
}

#[tauri::command]
fn media_url(view: Webview, state: State<NativeState>, relative_path: String) -> Result<String> {
    ui(&view)?;
    safe_relative(lock(&state.library)?.root(), &relative_path)?;
    let token = lock(&state.reader)?
        .as_ref()
        .map(|s| s.session_id.clone())
        .unwrap_or_else(|| "library".into());
    Ok(format!(
        "{}/media/{}/{}",
        reader::origin(),
        token,
        percent_encoding::utf8_percent_encode(&relative_path, percent_encoding::NON_ALPHANUMERIC)
    ))
}

#[tauri::command]
fn sketch_load(
    view: Webview,
    state: State<NativeState>,
    book_id: String,
    annotation_id: String,
    sketch_id: String,
) -> Result<Value> {
    ui(&view)?;
    read_sketch(
        &state,
        &SketchSession {
            book_id,
            annotation_id,
            sketch_id,
        },
    )
}

fn read_sketch(state: &NativeState, session: &SketchSession) -> Result<Value> {
    sketch_files::read(&*lock(&state.library)?, session)
}

fn save_sketch(
    app: &tauri::AppHandle,
    session: &SketchSession,
    scene: Value,
    preview: Option<String>,
) -> Result<Library> {
    let state = app.state::<NativeState>();
    let mut store = lock(&state.library)?;
    let library = sketch_files::save(&mut store, session, scene, preview)?;
    changed(app, library)
}

#[tauri::command]
fn sketch_save(
    view: Webview,
    app: tauri::AppHandle,
    book_id: String,
    annotation_id: String,
    sketch_id: String,
    scene: Value,
    preview: Option<String>,
) -> Result<Library> {
    ui(&view)?;
    save_sketch(
        &app,
        &SketchSession {
            book_id,
            annotation_id,
            sketch_id,
        },
        scene,
        preview,
    )
}

#[tauri::command]
async fn sketch_open(
    view: Webview,
    app: tauri::AppHandle,
    state: State<'_, NativeState>,
    book_id: String,
    annotation_id: String,
    sketch_id: String,
) -> Result<()> {
    ui(&view)?;
    let label = format!("sketch-{}", uuid::Uuid::new_v4());
    let session = SketchSession {
        book_id,
        annotation_id,
        sketch_id,
    };
    let scene = read_sketch(&state, &session)?;
    lock(&state.sketches)?.insert(label.clone(), session);
    let boot = format!("window.__SKETCH_SCENE__={};window.__kodiExcalidraw={{postMessage:function(message){{window.__TAURI_INTERNALS__.invoke('sketch_event',{{message:message}}).catch(console.error);}}}};", reader::script_json(&scene));
    let native = tauri::WebviewWindowBuilder::new(
        &app,
        &label,
        tauri::WebviewUrl::App("vendor/excalidraw/index.html".into()),
    )
    .title("Draw · Kodi Reader")
    .inner_size(1000., 740.)
    .initialization_script(&boot)
    .build()
    .map_err(|e| e.to_string())?;
    let window = native.clone();
    let handle = app.clone();
    let current = label.clone();
    native.on_window_event(move|event|{
        if let tauri::WindowEvent::CloseRequested{api,..}=event {
            if handle.state::<NativeState>().sketches.lock().ok().is_some_and(|s|s.contains_key(&current)) {
                api.prevent_close();
                let _=window.eval("window.__excalidraw.checkpoint().then(value=>window.__TAURI_INTERNALS__.invoke('sketch_event',{message:{type:'closeCheckpoint',...value}}));");
            }
        }
    });
    Ok(())
}

#[tauri::command]
fn sketch_event(
    view: Webview,
    app: tauri::AppHandle,
    state: State<NativeState>,
    message: Value,
) -> Result<()> {
    let session = lock(&state.sketches)?
        .get(view.label())
        .cloned()
        .ok_or("The sketch session has ended.")?;
    match message["type"].as_str().unwrap_or("") {
        "ready" => {
            let scene = read_sketch(&state, &session)?;
            view.eval(format!(
                "window.__excalidraw.load({});",
                reader::script_json(&scene)
            ))
            .map_err(|e| e.to_string())?;
        }
        "sceneChanged" | "change" if message.get("scene").is_none() => {
            view.eval("window.__excalidraw.checkpoint().then(value=>window.__TAURI_INTERNALS__.invoke('sketch_event',{message:{type:'checkpoint',...value}}));").map_err(|e|e.to_string())?;
        }
        "sceneChanged" | "change" | "checkpoint" | "closeCheckpoint" => {
            if message["type"] == "closeCheckpoint"
                && !sketch_files::exists(&*lock(&state.library)?, &session)
            {
                // Deletion is intentional. Let a stale drawing window close
                // without recreating its removed attachment or trapping it open.
                lock(&state.sketches)?.remove(view.label());
                if let Some(window) = app.get_webview_window(view.label()) {
                    window.close().map_err(|error| error.to_string())?;
                }
                return Ok(());
            }
            let scene = message.get("scene").cloned().unwrap_or(Value::Null);
            let scene = if let Some(text) = scene.as_str() {
                serde_json::from_str(text).map_err(|e| e.to_string())?
            } else {
                scene
            };
            if scene.is_object() {
                save_sketch(
                    &app,
                    &session,
                    scene,
                    message["preview"].as_str().map(str::to_owned),
                )?;
            }
            if message["type"] == "closeCheckpoint" {
                lock(&state.sketches)?.remove(view.label());
                if let Some(window) = app.get_webview_window(view.label()) {
                    window.close().map_err(|e| e.to_string())?;
                }
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            if let Some(view) = app.get_webview_window("main-ui") {
                let _ = view.show();
                let _ = view.set_focus();
            }
            let app = app.clone();
            tauri::async_runtime::spawn_blocking(move || {
                let state = app.state::<NativeState>();
                if let Ok(mut store) = state.library.lock() {
                    let paths = args.into_iter().skip(1).filter(|a| {
                        let a = a.to_lowercase();
                        a.ends_with(".epub") || a.ends_with(".pdf")
                    });
                    let (snapshot, failures) =
                        library_operations::import_selected(&mut store, paths);
                    let _ = changed(&app, snapshot);
                    if !failures.is_empty() {
                        let _ = app.emit_to(
                            "main-ui",
                            "native-error",
                            format!(
                                "Some documents could not be imported:\n{}",
                                failures.join("\n")
                            ),
                        );
                    }
                };
            });
        }))
        .plugin(tauri_plugin_dialog::init())
        .register_uri_scheme_protocol("kodi", |ctx, request| {
            reader::protocol(ctx.app_handle(), ctx.webview_label(), request)
        })
        .setup(|app| {
            let root = if cfg!(debug_assertions) {
                std::env::var_os("KODI_DESKTOP_DATA_DIR")
                    .map(PathBuf::from)
                    .unwrap_or(app.path().app_data_dir()?)
            } else {
                app.path().app_data_dir()?
            };
            let store = LibraryStore::open(root.clone())?;
            app.manage(NativeState {
                library: Mutex::new(store),
                reader: Mutex::new(None),
                bounds: Mutex::new(Bounds {
                    x: 260.,
                    y: 80.,
                    width: 900.,
                    height: 650.,
                }),
                sketches: Mutex::new(Default::default()),
                opening: std::sync::atomic::AtomicU64::new(0),
                open_gate: tokio::sync::Mutex::new(()),
            });
            service_commands::setup(app.handle(), root)?;
            let open = tauri::menu::MenuItem::with_id(
                app,
                "open",
                "Open documents…",
                true,
                Some("CmdOrCtrl+O"),
            )?;
            let quit = tauri::menu::MenuItem::with_id(
                app,
                "quit",
                "Quit Kodi Reader",
                true,
                Some("CmdOrCtrl+Q"),
            )?;
            let file = tauri::menu::Submenu::with_items(app, "File", true, &[&open, &quit])?;
            // Predefined items route editing actions to the native first
            // responder, including focused WKWebView inputs on macOS. Keep
            // Tauri's standard platform support/shortcut behavior intact.
            let edit = tauri::menu::Submenu::with_items(
                app,
                "Edit",
                true,
                &[
                    &tauri::menu::PredefinedMenuItem::undo(app, None)?,
                    &tauri::menu::PredefinedMenuItem::redo(app, None)?,
                    &tauri::menu::PredefinedMenuItem::separator(app)?,
                    &tauri::menu::PredefinedMenuItem::cut(app, None)?,
                    &tauri::menu::PredefinedMenuItem::copy(app, None)?,
                    &tauri::menu::PredefinedMenuItem::paste(app, None)?,
                    &tauri::menu::PredefinedMenuItem::select_all(app, None)?,
                ],
            )?;
            let menu = tauri::menu::Menu::with_items(app, &[&file, &edit])?;
            app.set_menu(menu)?;
            app.on_menu_event(|app, event| {
                if event.id().as_ref() == "open" {
                    use tauri_plugin_dialog::DialogExt;
                    let handle = app.clone();
                    app.dialog()
                        .file()
                        .add_filter("Books and documents", &["epub", "pdf"])
                        .pick_files(move |paths| {
                            if let Some(paths) = paths {
                                tauri::async_runtime::spawn_blocking(move || {
                                    let state = handle.state::<NativeState>();
                                    if let Ok(mut store) = state.library.lock() {
                                        let mut selected = Vec::new();
                                        let mut failures = Vec::new();
                                        for path in paths {
                                            match path.into_path() {
                                                Ok(path) => selected.push(path),
                                                Err(error) => failures.push(error.to_string()),
                                            }
                                        }
                                        let (snapshot, import_failures) =
                                            library_operations::import_selected(
                                                &mut store, selected,
                                            );
                                        failures.extend(import_failures);
                                        let _ = changed(&handle, snapshot);
                                        if !failures.is_empty() {
                                            let _ = handle.emit_to(
                                                "main-ui",
                                                "native-error",
                                                format!(
                                                    "Some documents could not be imported:\n{}",
                                                    failures.join("\n")
                                                ),
                                            );
                                        }
                                    };
                                });
                            }
                        });
                } else if event.id().as_ref() == "quit" {
                    if let Some(window) = app.get_window("main-ui") {
                        let _ = window.close();
                    }
                }
            });
            if let Some(view) = app.get_webview("main-ui") {
                layout::mount(&view).map_err(anyhow::Error::msg)?;
            }
            let paths: Vec<_> = std::env::args()
                .skip(1)
                .filter(|a| {
                    let a = a.to_lowercase();
                    a.ends_with(".epub") || a.ends_with(".pdf")
                })
                .collect();
            if !paths.is_empty() {
                let state = app.state::<NativeState>();
                let mut store = state.library.lock().unwrap();
                for path in paths {
                    if let Err(error) = store.import_document(Path::new(&path)) {
                        eprintln!("Could not import document: {error}");
                    }
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            library_get,
            import_documents,
            book_rename,
            book_delete,
            library_save_book,
            settings_save,
            read_activity,
            publication_get,
            media_read,
            media_url,
            sketch_load,
            sketch_save,
            sketch_open,
            sketch_event,
            reader::open_book,
            reader::reader_bounds,
            reader::reader_action,
            reader::reader_event,
            service_commands::export_notes,
            service_commands::source_url_import,
            service_commands::auth_status,
            service_commands::auth_send_code,
            service_commands::auth_verify_code,
            service_commands::auth_sign_out,
            service_commands::auth_delete_account,
            service_commands::ai_chat,
            service_commands::ai_cancel,
            service_commands::ai_credits,
            service_commands::ai_credit_packs,
            service_commands::ai_checkout,
            service_commands::ai_purchase_status,
            service_commands::drive_status,
            service_commands::drive_connect,
            service_commands::drive_sync,
            service_commands::drive_disconnect,
            service_commands::audio_record_start,
            service_commands::audio_record_pause,
            service_commands::audio_record_finish,
            service_commands::audio_play,
            service_commands::audio_stop,
            service_commands::audio_pause,
            service_commands::audio_seek,
            service_commands::audio_position,
            service_commands::audio_export,
            service_commands::audio_transcribe,
            service_commands::narration_start,
            service_commands::narration_pause,
            service_commands::narration_update,
            service_commands::narration_seek,
            service_commands::narration_stop,
            service_commands::models_status,
            service_commands::models_install,
            service_commands::updates_check,
            service_commands::updates_install,
            service_commands::open_external,
            service_commands::models_remove
        ])
        .run(tauri::generate_context!())
        .expect("Kodi Reader could not start");
}
