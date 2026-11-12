use crate::narration_state::{validate_options, NarrationPlan};
use crate::{changed, lock, ui, NativeState, Result};
use kodi_desktop_services::{
    ai::{ChatRequest, Message},
    CancellationToken, ServiceHub,
};
use kodi_reader_core::{ExportFormat, Library};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use tauri::{Emitter, Manager, State, Webview};

pub(crate) struct Services {
    hub: Arc<ServiceHub>,
    requests: Mutex<std::collections::HashMap<String, CancellationToken>>,
    recording: Mutex<Option<(String, String, String, String)>>,
    paused: Mutex<bool>,
    narration: Mutex<Option<CancellationToken>>,
    narration_ticket: Mutex<Option<String>>,
    narration_options: Mutex<(String, f32)>,
    narration_pause_signal: Mutex<Arc<std::sync::atomic::AtomicBool>>,
    narration_playback: Mutex<Option<(crate::reader::ReaderSession, NarrationPlan)>>,
    sync_status: Mutex<Value>,
    updates_configured: bool,
    playback_generation: std::sync::atomic::AtomicU64,
    playback_state_gate: Mutex<()>,
    playback_path: Mutex<Option<String>>,
    sync_preferences: Mutex<crate::sync_preferences::SyncPreferences>,
    sync_preferences_path: PathBuf,
    sync_gate: tokio::sync::Mutex<()>,
    sync_epoch: std::sync::atomic::AtomicU64,
}

pub(crate) fn setup(app: &tauri::AppHandle, root: PathBuf) -> anyhow::Result<()> {
    let sync_preferences_path = root.join("Sync/preferences.json");
    let sync_preferences =
        crate::sync_preferences::SyncPreferences::load(&sync_preferences_path).unwrap_or_default();
    let updates_configured = app
        .config()
        .plugins
        .0
        .get("updater")
        .is_some_and(|c| c["pubkey"].as_str().is_some_and(|s| !s.is_empty()));
    app.manage(Services {
        hub: Arc::new(ServiceHub::new(root)?),
        requests: Mutex::new(Default::default()),
        recording: Mutex::new(None),
        paused: Mutex::new(false),
        narration: Mutex::new(None),
        narration_ticket: Mutex::new(None),
        narration_options: Mutex::new(("anna".into(), 1.)),
        narration_pause_signal: Mutex::new(Arc::new(std::sync::atomic::AtomicBool::new(false))),
        narration_playback: Mutex::new(None),
        sync_status: Mutex::new(json!({"connected":false,"phase":"Off"})),
        updates_configured,
        playback_generation: std::sync::atomic::AtomicU64::new(0),
        playback_state_gate: Mutex::new(()),
        playback_path: Mutex::new(None),
        sync_preferences: Mutex::new(sync_preferences),
        sync_preferences_path,
        sync_gate: tokio::sync::Mutex::new(()),
        sync_epoch: std::sync::atomic::AtomicU64::new(0),
    });
    if updates_configured {
        app.plugin(tauri_plugin_updater::Builder::new().build())?;
    }
    let background = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut ticks = tokio::time::interval(std::time::Duration::from_secs(30));
        ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticks.tick().await;
            let state = background.state::<Services>();
            let prefs = match state.sync_preferences.lock() {
                Ok(p) => p.clone(),
                Err(_) => continue,
            };
            let account = state.hub.status().await;
            if prefs.permits_account(account["googleAccount"].as_str()) {
                let _ = perform_sync(background.clone(), prefs.mode, prefs.sync_ai_history, false)
                    .await;
            }
        }
    });
    let handle = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let services = handle.state::<Services>();
        match services.hub.recover_recordings() {
            Ok(report) => {
                for recovered in report.recordings {
                    let state = handle.state::<NativeState>();
                    let result = (|| -> Result<Library> {
                        let mut store = lock(&state.library)?;
                        let relative = recovered
                            .recording
                            .path
                            .strip_prefix(store.root())
                            .map_err(|_| "Recovered audio is outside the library")?
                            .to_string_lossy()
                            .replace('\\', "/");
                        store.mutate(|library|{let note=library.books.get_mut(&recovered.book_id).and_then(|b|b.annotations.iter_mut().find(|a|a.id.eq_ignore_ascii_case(&recovered.annotation_id))).ok_or_else(||kodi_reader_core::Error::Validation("A recovered recording has no matching note; its recovery files were preserved.".into()))?;
                            if !note.audio_recordings.iter().any(|a|a["id"].as_str().is_some_and(|id|id.eq_ignore_ascii_case(&recovered.audio_id))){note.audio_recordings.push(json!({"id":recovered.audio_id,"title":"Recovered audio note","path":relative,"createdAt":recovered.created_at,"modifiedAt":kodi_reader_core::now(),"duration":recovered.recording.duration,"waveform":recovered.recording.waveform}));note.note.get_or_insert_default().push_str(&format!("\n\n[Recovered audio note](kodi-audio://{})\n",recovered.audio_id));note.modified_at=kodi_reader_core::now();}Ok(())}).map_err(|e|e.to_string())
                    })();
                    match result {
                        Ok(library) => {
                            let _ = services.hub.confirm_recording(&recovered.audio_id);
                            let _ = changed(&handle, library);
                        }
                        Err(error) => {
                            let _ = handle.emit_to("main-ui", "native-error", error);
                        }
                    }
                }
                for error in report.errors {
                    let _ = handle.emit_to("main-ui", "native-error", error);
                }
            }
            Err(error) => {
                let _ = handle.emit_to("main-ui", "native-error", error.to_string());
            }
        }
    });
    Ok(())
}
pub(crate) fn local_day() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

pub(crate) async fn ensure_document(app: &tauri::AppHandle, book_id: &str) -> Result<()> {
    let state = app.state::<NativeState>();
    let (book, exists) = {
        let store = lock(&state.library)?;
        let book = store
            .snapshot()
            .books
            .get(book_id)
            .cloned()
            .ok_or("Document not found")?;
        let exists = store.root().join(&book.imported_relative_path).is_file();
        (book, exists)
    };
    if exists {
        return Ok(());
    }
    if !book.extra.contains_key("cloudFile") {
        return Err(
            "This document is not downloaded. Import its original EPUB or PDF to read it.".into(),
        );
    }
    let hub = app.state::<Services>().hub.clone();
    let relative = hub
        .download_synced_book(&serde_json::to_value(book).map_err(|e| e.to_string())?)
        .await
        .map_err(|e| e.to_string())?;
    let snapshot = lock(&state.library)?
        .mutate(|library| {
            if let Some(book) = library.books.get_mut(book_id) {
                book.imported_relative_path = relative;
                book.extra.insert("offlineAvailable".into(), json!(true));
            }
            Ok(())
        })
        .map_err(|e| e.to_string())?;
    changed(app, snapshot)?;
    Ok(())
}

#[tauri::command]
pub(crate) async fn export_notes(
    view: Webview,
    app: tauri::AppHandle,
    book_id: String,
    annotation_id: Option<String>,
    format: ExportFormat,
    destination: String,
) -> Result<String> {
    ui(&view)?;
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<NativeState>();
        let store = lock(&state.library)?;
        let result = store
            .export_notes(
                &book_id,
                annotation_id.as_deref(),
                Path::new(&destination),
                format,
            )
            .map_err(|e| e.to_string())?;
        Ok(result.path.to_string_lossy().into_owned())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn source_url_import(
    view: Webview,
    app: tauri::AppHandle,
    url: String,
) -> Result<Library> {
    ui(&view)?;
    let url: url::Url = url.parse().map_err(|e: url::ParseError| e.to_string())?;
    if !["https", "http"].contains(&url.scheme())
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("Enter a complete HTTP or HTTPS webpage URL.".into());
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()
        .map_err(|e| e.to_string())?;
    let mut response = client
        .get(url.clone())
        .header("User-Agent", "KodiReader/0.1 ReaderMode")
        .send()
        .await
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?;
    let final_url = response.url().clone();
    if response.content_length().unwrap_or(0) > 10 * 1024 * 1024 {
        return Err("This webpage exceeds the 10 MiB article limit.".into());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        if bytes.len() + chunk.len() > 10 * 1024 * 1024 {
            return Err("This webpage exceeds the article limit.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let base = final_url.clone();
    let mut article = tauri::async_runtime::spawn_blocking(move || {
        let product = readability::extractor::extract(&mut std::io::Cursor::new(bytes), &base)
            .map_err(|e| format!("This webpage could not be converted: {e}"))?;
        Ok::<_, String>(kodi_reader_core::Article {
            title: product.title,
            author: String::new(),
            source_url: base.to_string(),
            html: product.content,
            images: vec![],
        })
    })
    .await
    .map_err(|e| e.to_string())??;
    let image_pattern =
        regex::Regex::new(r#"(?is)<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#).unwrap();
    let images = image_pattern
        .captures_iter(&article.html)
        .take(32)
        .map(|c| (c[0].to_owned(), c[1].to_owned()))
        .collect::<Vec<_>>();
    let srcset = regex::Regex::new(r#"(?is)\s+srcset\s*=\s*(?:"[^"]*"|'[^']*')"#).unwrap();
    let mut total_image_bytes = 0usize;
    for (tag, src) in images {
        if src.starts_with("data:") {
            continue;
        }
        let Ok(image_url) = final_url.join(&src.replace("&amp;", "&")) else {
            continue;
        };
        if !["http", "https"].contains(&image_url.scheme()) {
            continue;
        }
        let Ok(mut image) = client
            .get(image_url.clone())
            .send()
            .await
            .and_then(|r| r.error_for_status())
        else {
            continue;
        };
        let mime = image
            .headers()
            .get("content-type")
            .and_then(|h| h.to_str().ok())
            .unwrap_or("")
            .split(';')
            .next()
            .unwrap_or("")
            .to_owned();
        let ext = match mime.as_str() {
            "image/png" => "png",
            "image/jpeg" => "jpg",
            "image/gif" => "gif",
            "image/webp" => "webp",
            "image/svg+xml" => "svg",
            _ => continue,
        };
        if image.content_length().unwrap_or(0) > 8 * 1024 * 1024 {
            continue;
        }
        let mut data = Vec::new();
        let mut failed = false;
        loop {
            match image.chunk().await {
                Ok(Some(chunk)) => {
                    if data.len() + chunk.len() > 8 * 1024 * 1024
                        || total_image_bytes + data.len() + chunk.len() > 24 * 1024 * 1024
                    {
                        failed = true;
                        break;
                    }
                    data.extend_from_slice(&chunk);
                }
                Ok(None) => break,
                Err(_) => {
                    failed = true;
                    break;
                }
            }
        }
        if failed || data.is_empty() {
            continue;
        }
        total_image_bytes += data.len();
        let path = format!(
            "images/{}.{}",
            kodi_desktop_services::sync::sha256(image_url.as_str().as_bytes()),
            ext
        );
        let replacement = srcset
            .replace_all(&tag.replace(&src, &path), "")
            .into_owned();
        article.html = article.html.replace(&tag, &replacement);
        article.images.push(kodi_reader_core::ArticleImage {
            path,
            media_type: mime,
            bytes: data,
        });
    }
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<NativeState>();
        let mut store = lock(&state.library)?;
        store.import_article(&article).map_err(|e| e.to_string())?;
        changed(&app, store.snapshot())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub(crate) async fn auth_status(view: Webview, state: State<'_, Services>) -> Result<Value> {
    ui(&view)?;
    let status = state.hub.status().await;
    let auth = state.hub.auth.status();
    Ok(
        json!({"configured":status["configured"],"signedIn":auth.account.is_some(),"email":auth.account.as_ref().and_then(|a|a.email.clone()),"userId":auth.account.as_ref().map(|a|a.id.clone()),"secureStorage":!auth.session_only,"paymentsEnabled":status["paymentsEnabled"]}),
    )
}
#[tauri::command]
pub(crate) async fn auth_send_code(
    view: Webview,
    state: State<'_, Services>,
    email: String,
) -> Result<Value> {
    ui(&view)?;
    state.hub.send_code(&email).await.map_err(|e| e.to_string())
}
#[tauri::command]
pub(crate) async fn auth_verify_code(
    view: Webview,
    state: State<'_, Services>,
    email: String,
    code: String,
) -> Result<Value> {
    ui(&view)?;
    state
        .hub
        .verify_code(&email, &code)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub(crate) async fn auth_sign_out(view: Webview, state: State<'_, Services>) -> Result<Value> {
    ui(&view)?;
    for request in lock(&state.requests)?.values() {
        request.cancel();
    }
    state.hub.sign_out().await.map_err(|e| e.to_string())
}
#[tauri::command]
pub(crate) async fn auth_delete_account(
    view: Webview,
    state: State<'_, Services>,
) -> Result<Value> {
    ui(&view)?;
    for request in lock(&state.requests)?.values() {
        request.cancel();
    }
    state.hub.delete_account().await.map_err(|e| e.to_string())
}

#[tauri::command]
pub(crate) async fn ai_chat(
    view: Webview,
    app: tauri::AppHandle,
    book_id: String,
    thread_id: String,
    text: String,
    references: Option<Vec<Value>>,
    request_id: Option<String>,
) -> Result<String> {
    ui(&view)?;
    if text.trim().is_empty() || text.len() > 64000 {
        return Err("Enter a question of at most 64,000 characters.".into());
    }
    let services = app.state::<Services>();
    let hub = services.hub.clone();
    let request_id = request_id
        .map(|id| uuid::Uuid::parse_str(&id))
        .transpose()
        .map_err(|_| "Invalid AI request identifier")?
        .unwrap_or_else(uuid::Uuid::new_v4);
    let cancel = CancellationToken::new();
    lock(&services.requests)?.insert(request_id.to_string(), cancel.clone());
    let state = app.state::<NativeState>();
    let book = lock(&state.library)?
        .snapshot()
        .books
        .get(&book_id)
        .cloned()
        .ok_or("Document not found")?;
    let thread = book
        .chats
        .iter()
        .find(|t| t.id == thread_id)
        .ok_or("Conversation not found")?;
    let mut messages = vec![Message {
        role: "system".into(),
        content: format!(
            "You are a reading assistant. Use plain, simple language. Be concise and straightforward by default: give the shortest clear, complete answer, usually a few sentences or a brief list. Start with the answer and skip preambles, repetition, and unsolicited examples or extended explanations. Provide more detail, examples, or a different style or format when the user asks for them. Ground answers in supplied passages. The document is {} by {}.",
            book.title, book.author
        ),
    }];
    for message in &thread.messages {
        if let (Some(role), Some(content)) = (message["role"].as_str(), message["text"].as_str()) {
            if ["user", "assistant"].contains(&role) {
                messages.push(Message {
                    role: role.into(),
                    content: content.into(),
                });
            }
        }
    }
    let refs = references.unwrap_or_default();
    let prompt = if refs.is_empty() {
        text.clone()
    } else {
        format!(
            "{}\n\nAttached passages:\n{}",
            text,
            refs.iter()
                .map(|r| r["text"]
                    .as_str()
                    .or_else(|| r["quote"].as_str())
                    .unwrap_or(""))
                .collect::<Vec<_>>()
                .join("\n\n")
        )
    };
    messages.push(Message {
        role: "user".into(),
        content: prompt,
    });
    let snapshot=lock(&state.library)?.mutate(|library|{
        let thread=library.books.get_mut(&book_id).and_then(|b|b.chats.iter_mut().find(|t|t.id==thread_id)).ok_or_else(||kodi_reader_core::Error::Validation("Conversation not found".into()))?;
        thread.messages.push(json!({"id":uuid::Uuid::new_v4().to_string(),"role":"user","text":text,"createdAt":kodi_reader_core::now(),"references":refs}));thread.modified_at=kodi_reader_core::now();Ok(())
    }).map_err(|e|e.to_string())?;
    changed(&app, snapshot)?;
    let id = request_id.to_string();
    let result_id = id.clone();
    tauri::async_runtime::spawn(async move {
        let mut answer = String::new();
        let result = hub
            .stream_chat(
                ChatRequest {
                    request_id,
                    messages,
                },
                cancel,
                |delta| {
                    answer.push_str(&delta);
                    let _ = app.emit_to(
                        "main-ui",
                        "ai-delta",
                        json!({"requestId":id,"bookId":book_id,"threadId":thread_id,"text":delta}),
                    );
                },
            )
            .await;
        if !answer.is_empty() {
            let state = app.state::<NativeState>();
            if let Ok(mut store) = state.library.lock() {
                if let Ok(snapshot)=store.mutate(|library|{if let Some(thread)=library.books.get_mut(&book_id).and_then(|b|b.chats.iter_mut().find(|t|t.id==thread_id)){thread.messages.push(json!({"id":uuid::Uuid::new_v4().to_string(),"role":"assistant","text":answer,"createdAt":kodi_reader_core::now(),"incomplete":result.is_err()}));thread.modified_at=kodi_reader_core::now();}Ok(())}){let _=changed(&app,snapshot);}
            };
        }
        let _=app.emit_to("main-ui","ai-done",json!({"requestId":id,"bookId":book_id,"threadId":thread_id,"error":result.err().map(|e|e.to_string())}));
        if let Ok(mut requests) = app.state::<Services>().requests.lock() {
            requests.remove(&id);
        }
    });
    Ok(result_id)
}
#[tauri::command]
pub(crate) fn ai_cancel(view: Webview, state: State<Services>) -> Result<()> {
    ui(&view)?;
    for cancel in lock(&state.requests)?.values() {
        cancel.cancel();
    }
    Ok(())
}

#[tauri::command]
pub(crate) async fn ai_credits(view: Webview, state: State<'_, Services>) -> Result<Value> {
    ui(&view)?;
    let token = state
        .hub
        .auth
        .access_token()
        .await
        .map_err(|e| e.to_string())?;
    let response = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?
        .post(format!(
            "{}/account/initialize",
            state.hub.config.ai_base_url.trim_end_matches('/')
        ))
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!(
            "Could not initialize AI credits (HTTP {}).",
            response.status().as_u16()
        ));
    }
    state
        .hub
        .ai
        .credits(&token)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub(crate) async fn ai_credit_packs(view: Webview, state: State<'_, Services>) -> Result<Value> {
    ui(&view)?;
    let token = state
        .hub
        .auth
        .access_token()
        .await
        .map_err(|e| e.to_string())?;
    state
        .hub
        .ai
        .credit_packs(&token)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub(crate) async fn ai_checkout(
    view: Webview,
    state: State<'_, Services>,
    pack: String,
    request_id: Option<String>,
) -> Result<Value> {
    ui(&view)?;
    let token = state
        .hub
        .auth
        .access_token()
        .await
        .map_err(|e| e.to_string())?;
    let id = request_id
        .map(|id| uuid::Uuid::parse_str(&id))
        .transpose()
        .map_err(|_| "Invalid checkout request identifier")?
        .unwrap_or_else(uuid::Uuid::new_v4);
    let url = state
        .hub
        .ai
        .checkout(&token, &pack, id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(json!({"url":url,"requestId":id}))
}
#[tauri::command]
pub(crate) async fn ai_purchase_status(
    view: Webview,
    state: State<'_, Services>,
    purchase_id: String,
) -> Result<Value> {
    ui(&view)?;
    let id = uuid::Uuid::parse_str(&purchase_id).map_err(|_| "Invalid purchase identifier")?;
    let token = state
        .hub
        .auth
        .access_token()
        .await
        .map_err(|e| e.to_string())?;
    state
        .hub
        .ai
        .purchase(&token, id)
        .await
        .map_err(|e| e.to_string())
}

pub(crate) fn open_url(value: &str) -> Result<()> {
    let url: url::Url = value.parse().map_err(|e: url::ParseError| e.to_string())?;
    if !["https", "http"].contains(&url.scheme()) || url.host_str().is_none() {
        return Err("Only web links can be opened externally.".into());
    }
    #[cfg(target_os = "windows")]
    let mut command = {
        let mut c = std::process::Command::new("rundll32.exe");
        c.arg("url.dll,FileProtocolHandler");
        c
    };
    #[cfg(target_os = "linux")]
    let mut command = std::process::Command::new("xdg-open");
    #[cfg(target_os = "macos")]
    let mut command = std::process::Command::new("/usr/bin/open");
    command
        .arg(url.as_str())
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}
#[tauri::command]
pub(crate) fn open_external(view: Webview, url: String) -> Result<()> {
    ui(&view)?;
    open_url(&url)
}

#[tauri::command]
pub(crate) async fn drive_status(view: Webview, state: State<'_, Services>) -> Result<Value> {
    ui(&view)?;
    let status = state.hub.status().await;
    let mut value = lock(&state.sync_status)?.clone();
    value["connected"] = json!(status["googleAccount"].is_string());
    let prefs = lock(&state.sync_preferences)?;
    value["mode"] = json!(if prefs.mode == "off" {
        "notesOnly"
    } else {
        prefs.mode.as_str()
    });
    value["syncAIHistory"] = json!(prefs.sync_ai_history);
    if prefs.mode != "off"
        && !prefs.permits_account(status["googleAccount"].as_str())
        && status["googleAccount"].is_string()
    {
        value["phase"] = json!("Sync needs attention");
        value["message"]=json!("Your Drive account changed. Choose Sync Now to copy this library to the current account.");
    }
    Ok(value)
}
#[tauri::command]
pub(crate) async fn drive_connect(
    view: Webview,
    app: tauri::AppHandle,
    state: State<'_, Services>,
) -> Result<Value> {
    ui(&view)?;
    state
        .sync_epoch
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let _gate = state.sync_gate.lock().await;
    let url = state.hub.drive_begin().await.map_err(|e| e.to_string())?;
    open_url(&url)?;
    let result = state
        .hub
        .drive_complete(CancellationToken::new())
        .await
        .map_err(|e| e.to_string())?;
    *lock(&state.sync_status)? =
        json!({"connected":true,"phase":"Connected","email":result["email"]});
    let _ = app.emit_to("main-ui", "sync-state", lock(&state.sync_status)?.clone());
    Ok(result)
}
#[tauri::command]
pub(crate) async fn drive_disconnect(view: Webview, state: State<'_, Services>) -> Result<()> {
    ui(&view)?;
    state
        .sync_epoch
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let _gate = state.sync_gate.lock().await;
    let disabled = crate::sync_preferences::SyncPreferences::default();
    disabled
        .save(&state.sync_preferences_path)
        .map_err(|e| e.to_string())?;
    *lock(&state.sync_preferences)? = disabled;
    state
        .hub
        .drive_disconnect()
        .await
        .map_err(|e| e.to_string())?;
    *lock(&state.sync_status)? = json!({"connected":false,"phase":"Off"});
    Ok(())
}

#[tauri::command]
pub(crate) async fn drive_sync(
    view: Webview,
    app: tauri::AppHandle,
    mode: String,
    sync_ai_history: bool,
) -> Result<Value> {
    ui(&view)?;
    perform_sync(app, mode, sync_ai_history, true).await
}

async fn perform_sync(
    app: tauri::AppHandle,
    mode: String,
    sync_ai_history: bool,
    save_preferences: bool,
) -> Result<Value> {
    if !["notesOnly", "booksAndNotes"].contains(&mode.as_str()) {
        return Err("Choose Notes only or Books and notes.".into());
    }
    let state = app.state::<NativeState>();
    let services = app.state::<Services>();
    let _gate = services.sync_gate.lock().await;
    let epoch = services
        .sync_epoch
        .load(std::sync::atomic::Ordering::SeqCst);
    let account = services.hub.status().await;
    let account_id = account["googleAccount"]
        .as_str()
        .ok_or("Connect Google Drive before syncing.")?
        .to_owned();
    // A background tick may have queued before a disconnect/account change.
    // Recheck authorization after acquiring the same gate used by both actions.
    if !save_preferences {
        let prefs = lock(&services.sync_preferences)?;
        if !prefs.permits_account(Some(&account_id))
            || prefs.mode != mode
            || prefs.sync_ai_history != sync_ai_history
        {
            return Err("Background sync settings changed before this attempt started.".into());
        }
    }
    let before = lock(&state.library)?.snapshot();
    *lock(&services.sync_status)? =
        json!({"connected":true,"phase":"Syncing","mode":mode,"syncAIHistory":sync_ai_history});
    let _ = app.emit_to(
        "main-ui",
        "sync-state",
        lock(&services.sync_status)?.clone(),
    );
    let mut snapshot = serde_json::to_value(&before).map_err(|e| e.to_string())?;
    if let Some(session) = lock(&state.reader)?.as_ref() {
        snapshot["desktopEditingBookIds"] = json!([session.book_id]);
    }
    let result: Result<Value>=async {
            let prepared=services.hub.prepare_sync(snapshot,&mode,sync_ai_history).await.map_err(|e|e.to_string())?;
            if prepared.journal.account_id!=account_id{return Err("The Drive account changed before sync completed.".into());}
            if services.sync_epoch.load(std::sync::atomic::Ordering::SeqCst)!=epoch{return Err("Sync was stopped before applying remote changes.".into());}
            let incoming: Library =
                serde_json::from_value(prepared.library.clone()).map_err(|e| e.to_string())?;
            if incoming.books!=before.books {
                let library=lock(&state.library)?.mutate(|library|{
                if library.books!=before.books {return Err(kodi_reader_core::Error::Validation("Your library changed during sync. Local edits were kept; run Sync Now again when you finish editing.".into()));}
                library.books=incoming.books;
                Ok(())
            }).map_err(|e|e.to_string())?;
                changed(&app, library)?;
            }else if lock(&state.library)?.snapshot().books!=before.books{return Err("Your library changed during sync. Local edits were kept and will sync on the next attempt.".into());}
            prepared.commit().await.map_err(|e| e.to_string())?;
            if services.sync_epoch.load(std::sync::atomic::Ordering::SeqCst)!=epoch{return Err("Sync was stopped before saving preferences.".into());}
            if save_preferences {let prefs=crate::sync_preferences::SyncPreferences{mode:mode.clone(),sync_ai_history,account_id:Some(account_id),..Default::default()};prefs.save(&services.sync_preferences_path).map_err(|e|e.to_string())?;*lock(&services.sync_preferences)?=prefs;}
            let status = json!({"connected":true,"phase":"Synced","mode":mode,"syncAIHistory":sync_ai_history,"lastSuccessfulSync":kodi_reader_core::now()});
            Ok(status)
    }.await;
    if services
        .sync_epoch
        .load(std::sync::atomic::Ordering::SeqCst)
        != epoch
    {
        return Err("Sync was stopped.".into());
    }
    match result {
        Ok(status) => {
            *lock(&services.sync_status)? = status.clone();
            let _ = app.emit_to("main-ui", "sync-state", &status);
            Ok(status)
        }
        Err(error) => {
            let status = json!({"connected":true,"phase":"Sync needs attention","message":error});
            *lock(&services.sync_status)? = status.clone();
            let _ = app.emit_to("main-ui", "sync-state", &status);
            Err(error.to_string())
        }
    }
}

#[tauri::command]
pub(crate) async fn audio_record_start(
    view: Webview,
    app: tauri::AppHandle,
    book_id: String,
    annotation_id: String,
) -> Result<Value> {
    ui(&view)?;
    stop_narration(&app);
    let state = app.state::<NativeState>();
    if !lock(&state.library)?
        .snapshot()
        .books
        .get(&book_id)
        .is_some_and(|b| b.annotations.iter().any(|a| a.id == annotation_id))
    {
        return Err("Note not found".into());
    }
    let hub = app.state::<Services>().hub.clone();
    hub.ffmpeg().map_err(|e| e.to_string())?;
    let id = uuid::Uuid::new_v4().to_string();
    let context = (book_id.clone(), annotation_id.clone(), id.clone());
    tauri::async_runtime::spawn_blocking(move || {
        hub.record_start_for(&context.0, &context.1, &context.2)
    })
    .await
    .map_err(|e| e.to_string())?
    .map_err(|e| e.to_string())?;
    let relative = format!(
        "Audio/{}/{annotation_id}/{id}.m4a",
        kodi_desktop_services::sync::sha256(book_id.as_bytes())
    );
    *lock(&app.state::<Services>().recording)? = Some((book_id, annotation_id, id, relative));
    *lock(&app.state::<Services>().paused)? = false;
    let result = json!({"recording":true,"phase":"recording","paused":false});
    let _ = app.emit_to("main-ui", "audio-state", &result);
    Ok(result)
}
#[tauri::command]
pub(crate) fn audio_record_pause(
    view: Webview,
    app: tauri::AppHandle,
    state: State<Services>,
    paused: Option<bool>,
) -> Result<Value> {
    ui(&view)?;
    let next = paused.unwrap_or(!*lock(&state.paused)?);
    state.hub.record_pause(next).map_err(|e| e.to_string())?;
    *lock(&state.paused)? = next;
    let status = json!({"recording":true,"paused":next,"phase":if next{"paused"}else{"recording"}});
    let _ = app.emit_to("main-ui", "audio-state", &status);
    Ok(status)
}
#[tauri::command]
pub(crate) async fn audio_record_finish(view: Webview, app: tauri::AppHandle) -> Result<Library> {
    ui(&view)?;
    let services = app.state::<Services>();
    let (book, annotation, id, path) = lock(&services.recording)?
        .take()
        .ok_or("There is no active recording")?;
    let hub = services.hub.clone();
    let relative = path.clone();
    let recording = match tauri::async_runtime::spawn_blocking(move || hub.record_finish(&relative))
        .await
        .map_err(|e| e.to_string())?
    {
        Ok(value) => value,
        Err(error) => {
            let _=app.emit_to("main-ui","audio-state",json!({"recording":false,"phase":"idle","error":"The recording could not finish. Its recovery files were kept; restart Kodi Reader after resolving the audio error."}));
            return Err(error.to_string());
        }
    };
    let state = app.state::<NativeState>();
    let snapshot=lock(&state.library)?.mutate(|library|{let note=library.books.get_mut(&book).and_then(|b|b.annotations.iter_mut().find(|a|a.id==annotation)).ok_or_else(||kodi_reader_core::Error::Validation("Note not found".into()))?;
        note.audio_recordings.push(json!({"id":id,"title":"Audio note","path":path,"createdAt":kodi_reader_core::now(),"modifiedAt":kodi_reader_core::now(),"duration":recording.duration,"waveform":recording.waveform}));let link=format!("[Audio note](kodi-audio://{id})");let body=note.note.get_or_insert_default();if !body.contains(&link){body.push_str(&format!("\n\n{link}\n"));}note.modified_at=kodi_reader_core::now();Ok(())}).map_err(|e|e.to_string())?;
    services
        .hub
        .confirm_recording(&id)
        .map_err(|e| e.to_string())?;
    let _ = app.emit_to(
        "main-ui",
        "audio-state",
        json!({"recording":false,"phase":"idle"}),
    );
    changed(&app, snapshot)
}
#[tauri::command]
pub(crate) async fn audio_play(
    view: Webview,
    app: tauri::AppHandle,
    path: String,
    rate: f32,
) -> Result<Value> {
    ui(&view)?;
    let services = app.state::<Services>();
    let hub = services.hub.clone();
    let (generation, request) = {
        let _transition = lock(&services.playback_state_gate)?;
        stop_narration_locked(&app, &services);
        let generation = services
            .playback_generation
            .load(std::sync::atomic::Ordering::SeqCst);
        // Ownership starts before decoding. Removing a card while its stream
        // is preparing must also cancel that card's pending playback request.
        *lock(&services.playback_path)? = Some(path.clone());
        (generation, hub.playback_request())
    };
    let cancellation = request.cancellation_token();
    let playing_request = request.clone();
    let relative = path.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        hub.audio_play_requested(&relative, rate, &request)
    })
    .await
    .map_err(|e| e.to_string())
    .and_then(|result| result.map_err(|e| e.to_string()));
    if cancellation.is_cancelled() {
        return Ok(json!({"phase":"idle","cancelled":true}));
    }
    let result = match result {
        Ok(result) => result,
        Err(error) => {
            let _transition = lock(&services.playback_state_gate)?;
            if cancellation.is_cancelled()
                || services
                    .playback_generation
                    .load(std::sync::atomic::Ordering::SeqCst)
                    != generation
            {
                return Ok(json!({"phase":"idle","cancelled":true}));
            }
            *lock(&services.playback_path)? = None;
            let _ = app.emit_to(
                "main-ui",
                "audio-state",
                json!({"phase":"idle","path":path}),
            );
            return Err(error);
        }
    };
    let status = json!({"phase":"playing","duration":result["duration"],"path":path});
    {
        let _transition = lock(&services.playback_state_gate)?;
        if cancellation.is_cancelled()
            || services
                .playback_generation
                .load(std::sync::atomic::Ordering::SeqCst)
                != generation
        {
            return Ok(json!({"phase":"idle","cancelled":true}));
        }
        *lock(&services.paused)? = false;
        *lock(&services.playback_path)? = Some(path.clone());
        let _ = app.emit_to("main-ui", "audio-state", &status);
    }
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            let services = app.state::<Services>();
            let Ok(_transition) = services.playback_state_gate.lock() else {
                break;
            };
            if services
                .playback_generation
                .load(std::sync::atomic::Ordering::SeqCst)
                != generation
            {
                break;
            }
            let position = services.hub.audio_position();
            let elapsed = position["position"].as_f64().unwrap_or(0.);
            let duration = position["duration"].as_f64().unwrap_or(0.);
            if duration <= 0. || elapsed >= duration {
                let _ = services.hub.audio_finish_requested(&playing_request);
                if let Ok(mut current_path) = services.playback_path.lock() {
                    *current_path = None;
                }
                let _ = app.emit_to(
                    "main-ui",
                    "audio-state",
                    json!({"phase":"idle","path":path}),
                );
                break;
            }
            let paused = *services.paused.lock().unwrap();
            let _=app.emit_to("main-ui","audio-state",json!({"phase":if paused{"paused"}else{"playing"},"elapsed":elapsed,"duration":duration,"path":path}));
        }
    });
    Ok(status)
}
#[tauri::command]
pub(crate) fn audio_stop(view: Webview, app: tauri::AppHandle, path: Option<String>) -> Result<()> {
    ui(&view)?;
    let state = app.state::<Services>();
    let _transition = lock(&state.playback_state_gate)?;
    if !audio_target_matches(&state.playback_path, path.as_deref())? {
        return Ok(());
    }
    stop_narration_locked(&app, &state);
    Ok(())
}
#[tauri::command]
pub(crate) fn audio_pause(
    view: Webview,
    app: tauri::AppHandle,
    state: State<Services>,
    paused: bool,
    path: Option<String>,
) -> Result<Value> {
    ui(&view)?;
    let _transition = lock(&state.playback_state_gate)?;
    if !audio_target_matches(&state.playback_path, path.as_deref())? {
        return Ok(json!({"cancelled":true}));
    }
    state.hub.audio_pause(paused).map_err(|e| e.to_string())?;
    *lock(&state.paused)? = paused;
    let status = json!({"phase":if paused{"paused"}else{"playing"},"paused":paused,"path":lock(&state.playback_path)?.clone()});
    let _ = app.emit_to("main-ui", "audio-state", &status);
    Ok(status)
}
#[tauri::command]
pub(crate) fn audio_seek(
    view: Webview,
    state: State<Services>,
    seconds: f64,
    path: Option<String>,
) -> Result<()> {
    ui(&view)?;
    if !seconds.is_finite() || seconds < 0. {
        return Err("Invalid audio position".into());
    }
    let _transition = lock(&state.playback_state_gate)?;
    if !audio_target_matches(&state.playback_path, path.as_deref())? {
        return Ok(());
    }
    state.hub.audio_seek(seconds).map_err(|e| e.to_string())
}

// Call only while holding playback_state_gate, the same gate used to replace
// or stop the current source. A delayed card action cannot control newer audio.
fn audio_target_matches(current: &Mutex<Option<String>>, expected: Option<&str>) -> Result<bool> {
    match expected {
        Some(path) => Ok(lock(current)?.as_deref() == Some(path)),
        None => Ok(true),
    }
}
#[tauri::command]
pub(crate) fn audio_position(view: Webview, state: State<Services>) -> Result<Value> {
    ui(&view)?;
    let _transition = lock(&state.playback_state_gate)?;
    let mut result = state.hub.audio_position();
    result["elapsed"] = result["position"].clone();
    result["path"] = json!(lock(&state.playback_path)?.clone());
    result["paused"] = json!(*lock(&state.paused)?);
    Ok(result)
}
#[tauri::command]
pub(crate) async fn audio_export(
    view: Webview,
    app: tauri::AppHandle,
    book_id: String,
    annotation_id: String,
    audio_id: String,
    destination: String,
) -> Result<()> {
    ui(&view)?;
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<NativeState>();
        let store = lock(&state.library)?;
        let library = store.snapshot();
        let path = library
            .books
            .get(&book_id)
            .and_then(|b| b.annotations.iter().find(|a| a.id == annotation_id))
            .and_then(|a| a.audio_recordings.iter().find(|a| a["id"] == audio_id))
            .and_then(|a| a["path"].as_str())
            .ok_or("The recording is not downloaded")?;
        let source = crate::safe_relative(store.root(), path)?;
        let destination = PathBuf::from(destination);
        if !destination.is_absolute() || destination.starts_with(store.root()) {
            return Err("Choose an export destination outside Kodi Reader's library.".into());
        }
        std::fs::copy(source, destination).map_err(|e| e.to_string())?;
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub(crate) async fn audio_transcribe(
    view: Webview,
    app: tauri::AppHandle,
    book_id: String,
    annotation_id: String,
    audio_id: String,
) -> Result<Library> {
    ui(&view)?;
    let state = app.state::<NativeState>();
    let library = lock(&state.library)?.snapshot();
    let audio = library
        .books
        .get(&book_id)
        .and_then(|b| b.annotations.iter().find(|a| a.id == annotation_id))
        .and_then(|a| a.audio_recordings.iter().find(|a| a["id"] == audio_id))
        .ok_or("Recording not found")?;
    let path = audio["path"]
        .as_str()
        .ok_or("Recording file is missing")?
        .to_owned();
    let hub = app.state::<Services>().hub.clone();
    let transcript = tauri::async_runtime::spawn_blocking(move || {
        hub.transcribe(&path, CancellationToken::new())
    })
    .await
    .map_err(|e| e.to_string())?
    .map_err(|e| e.to_string())?;
    let snapshot = lock(&state.library)?
        .mutate(|library| {
            if let Some(audio) = library
                .books
                .get_mut(&book_id)
                .and_then(|b| b.annotations.iter_mut().find(|a| a.id == annotation_id))
                .and_then(|a| a.audio_recordings.iter_mut().find(|a| a["id"] == audio_id))
            {
                audio["transcript"] = json!(transcript);
                audio["modifiedAt"] = json!(kodi_reader_core::now());
            }
            Ok(())
        })
        .map_err(|e| e.to_string())?;
    changed(&app, snapshot)
}

#[tauri::command]
pub(crate) fn models_status(view: Webview, state: State<Services>) -> Result<Value> {
    ui(&view)?;
    let catalog = state.hub.model_catalog().map_err(|e| e.to_string())?;
    let statuses=catalog.iter().map(|s|json!({"kind":if s.id=="pocket-tts"{"tts"}else if s.id=="whisper-base"{"whisper"}else{s.id.as_str()},"installed":state.hub.models.verified(s).unwrap_or(false),"size":s.files.iter().map(|f|f.size).sum::<u64>()})).collect::<Vec<_>>();
    Ok(json!(statuses))
}
#[tauri::command]
pub(crate) async fn models_install(
    view: Webview,
    app: tauri::AppHandle,
    state: State<'_, Services>,
    kind: String,
) -> Result<Value> {
    ui(&view)?;
    let ids = match kind.as_str() {
        "tts" => vec!["pocket-tts", "narration-voices"],
        "whisper" => vec!["whisper-base"],
        _ => return Err("Unknown speech model".into()),
    };
    for id in ids {
        state
            .hub
            .install_model(id, CancellationToken::new(), |done, total| {
                let _ = app.emit_to(
                    "main-ui",
                    "model-progress",
                    json!({"kind":kind,"progress":if total>0{done as f64/total as f64}else{0.}}),
                );
            })
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(json!({"installed":true,"kind":kind}))
}
#[tauri::command]
pub(crate) fn models_remove(view: Webview, state: State<Services>, kind: String) -> Result<()> {
    ui(&view)?;
    let id = match kind.as_str() {
        "tts" => "pocket-tts",
        "whisper" => "whisper-base",
        _ => return Err("Unknown speech model".into()),
    };
    state.hub.remove_model(id).map_err(|e| e.to_string())
}

#[tauri::command]
pub(crate) async fn narration_start(
    view: Webview,
    app: tauri::AppHandle,
    state: State<'_, NativeState>,
    session_id: String,
    voice: String,
    rate: f32,
    locator: Option<Value>,
) -> Result<()> {
    ui(&view)?;
    let session = lock(&state.reader)?
        .clone()
        .ok_or("Open an EPUB to listen")?;
    if session.session_id != session_id || session.kind != kodi_reader_core::DocumentKind::Epub {
        return Err("Open the active EPUB to listen.".into());
    }
    validate_options(&voice, rate)?;
    let ticket = uuid::Uuid::new_v4().to_string();
    {
        let services = app.state::<Services>();
        let _transition = lock(&services.playback_state_gate)?;
        stop_narration_locked(&app, &services);
        *lock(&services.narration_ticket)? = Some(ticket.clone());
        *lock(&services.narration_options)? = (voice.clone(), rate);
    }
    // Ask the trusted reader runtime to extract immutable passage anchors. The
    // resulting event is consumed by the native narration worker.
    let start = locator
        .as_ref()
        .and_then(|l| l.get("start"))
        .cloned()
        .unwrap_or(Value::Null);
    let end = Value::Null;
    let script=format!("window.__kodiPost({{type:'narrationPassages',ticket:{},voice:{},rate:{},passages:JSON.parse(window.__reader.narrationPassages({},{},{},false))}});",crate::reader::script_json(&json!(ticket)),crate::reader::script_json(&json!(voice)),rate,session.spine_index,crate::reader::script_json(&start),crate::reader::script_json(&end));
    app.get_webview("book-reader")
        .ok_or("Reader is closed")?
        .eval(script)
        .map_err(|e| e.to_string())
}
pub(crate) fn narrate_passages(app: tauri::AppHandle, message: Value) -> Result<()> {
    let session = lock(&app.state::<NativeState>().reader)?
        .clone()
        .ok_or("The reader is closed")?;
    let services = app.state::<Services>();
    let ticket = message["ticket"]
        .as_str()
        .ok_or("Missing narration request")?
        .to_owned();
    let _transition = lock(&services.playback_state_gate)?;
    if lock(&services.narration_ticket)?.as_deref() != Some(ticket.as_str()) {
        return Err("This narration request has ended.".into());
    }
    let (voice, rate) = lock(&services.narration_options)?.clone();
    validate_options(&voice, rate)?;
    let plan = NarrationPlan::new(
        message["passages"].as_array().cloned().unwrap_or_default(),
        voice,
        rate,
        *lock(&services.paused)?,
    )?;
    launch_narration_locked(app.clone(), &services, session, plan, ticket)
}

#[tauri::command]
pub(crate) fn narration_update(
    view: Webview,
    app: tauri::AppHandle,
    state: State<NativeState>,
    session_id: String,
    voice: String,
    rate: f32,
) -> Result<()> {
    ui(&view)?;
    validate_options(&voice, rate)?;
    let session = lock(&state.reader)?
        .clone()
        .ok_or("Open an EPUB to listen")?;
    if session.session_id != session_id || session.kind != kodi_reader_core::DocumentKind::Epub {
        return Err("Open the active EPUB to change narration.".into());
    }
    let services = app.state::<Services>();
    let _transition = lock(&services.playback_state_gate)?;
    *lock(&services.narration_options)? = (voice.clone(), rate);
    let current = lock(&services.narration_playback)?.clone();
    let Some((owner, plan)) = current.filter(|(owner, _)| owner.document_id == session.document_id)
    else {
        // Also records changes made while the initial passage extraction is
        // pending. The eventual worker reads these options before starting.
        return Ok(());
    };
    if plan.voice == voice && plan.rate == rate {
        return Ok(());
    }
    let playback = services.hub.audio_position();
    let elapsed = if playback["duration"].as_f64().unwrap_or(0.) > 0. {
        playback["position"].as_f64()
    } else {
        None
    };
    let next = plan.with_options(voice, rate, elapsed, *lock(&services.paused)?)?;
    launch_narration_locked(
        app.clone(),
        &services,
        owner,
        next,
        uuid::Uuid::new_v4().to_string(),
    )
}

struct NarrationFile {
    relative: String,
    path: PathBuf,
}
impl Drop for NarrationFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}
fn render_narration_passage(
    app: &tauri::AppHandle,
    hub: &ServiceHub,
    text: &str,
    voice: &str,
    cancel: CancellationToken,
    index: usize,
) -> anyhow::Result<NarrationFile> {
    let relative = hub.narrate(text, voice, 1., cancel.clone())?;
    let path = hub.local_path(&relative)?;
    let file = NarrationFile { relative, path };
    let duration = hub.narration_duration(&file.relative)?;
    let services = app.state::<Services>();
    let _transition = services
        .playback_state_gate
        .lock()
        .map_err(|_| anyhow::anyhow!("Playback state is unavailable"))?;
    if cancel.is_cancelled() {
        anyhow::bail!("Narration was cancelled");
    }
    if let Some((_, plan)) = services
        .narration_playback
        .lock()
        .map_err(|_| anyhow::anyhow!("Narration state is unavailable"))?
        .as_mut()
    {
        plan.set_duration(index, duration);
    };
    Ok(file)
}

fn narration_source_offset(services: &Services, plan: &NarrationPlan) -> f64 {
    let playback = services.hub.audio_position();
    if playback["duration"].as_f64().unwrap_or(0.) > 0. {
        playback["position"].as_f64().unwrap_or(plan.offset)
    } else {
        plan.offset
    }
}
fn narration_audio_state(services: &Services, phase: &str, source_offset: f64) -> Value {
    services
        .narration_playback
        .lock()
        .ok()
        .and_then(|state| {
            state
                .as_ref()
                .map(|(_, plan)| plan.audio_state(phase, source_offset))
        })
        .unwrap_or_else(|| json!({"phase":phase,"kind":"narration"}))
}

#[tauri::command]
pub(crate) fn narration_seek(
    view: Webview,
    app: tauri::AppHandle,
    state: State<NativeState>,
    session_id: String,
    seconds: Option<f64>,
    delta: Option<f64>,
) -> Result<()> {
    ui(&view)?;
    let session = lock(&state.reader)?
        .clone()
        .ok_or("Open an EPUB to listen")?;
    if session.session_id != session_id || session.kind != kodi_reader_core::DocumentKind::Epub {
        return Err("Open the active EPUB to seek narration.".into());
    }
    let services = app.state::<Services>();
    let _transition = lock(&services.playback_state_gate)?;
    let (owner, plan) = lock(&services.narration_playback)?
        .clone()
        .filter(|(owner, _)| owner.document_id == session.document_id)
        .ok_or("Start narration before seeking.")?;
    let paused = *lock(&services.paused)?;
    let next = match (seconds, delta) {
        (Some(seconds), None) => plan.seek(seconds, paused)?,
        (None, Some(delta)) => {
            plan.skip(delta, narration_source_offset(&services, &plan), paused)?
        }
        _ => return Err("Choose a narration position or skip amount.".into()),
    };
    if next.index == plan.index
        && services.hub.audio_position()["duration"]
            .as_f64()
            .unwrap_or(0.)
            > 0.
    {
        services
            .hub
            .audio_seek(next.offset)
            .map_err(|error| error.to_string())?;
        if let Some((_, active)) = lock(&services.narration_playback)?.as_mut() {
            active.offset = next.offset;
        }
        let _ = app.emit_to(
            "main-ui",
            "audio-state",
            next.audio_state(if paused { "paused" } else { "playing" }, next.offset),
        );
        return Ok(());
    }
    launch_narration_locked(
        app.clone(),
        &services,
        owner,
        next,
        uuid::Uuid::new_v4().to_string(),
    )
}

// Called with playback_state_gate held. A changed voice/speed replaces only the
// current passage and retains source-time position, pending pause and chapter.
fn launch_narration_locked(
    app: tauri::AppHandle,
    services: &Services,
    session: crate::reader::ReaderSession,
    plan: NarrationPlan,
    ticket: String,
) -> Result<()> {
    stop_narration_locked(&app, services);
    *lock(&services.narration_ticket)? = Some(ticket.clone());
    *lock(&services.narration_options)? = (plan.voice.clone(), plan.rate);
    *lock(&services.paused)? = plan.paused;
    *lock(&services.narration_pause_signal)? =
        Arc::new(std::sync::atomic::AtomicBool::new(plan.paused));
    *lock(&services.narration_playback)? = Some((session.clone(), plan.clone()));
    let hub = services.hub.clone();
    let playback_request = hub.playback_request();
    let cancel = playback_request.cancellation_token();
    *lock(&services.narration)? = Some(cancel.clone());
    let _ = app.emit_to(
        "main-ui",
        "audio-state",
        plan.audio_state(
            if plan.paused { "paused" } else { "preparing" },
            plan.offset,
        ),
    );
    tauri::async_runtime::spawn_blocking(move || {
        let run = (|| -> anyhow::Result<()> {
            let mut lookahead: Option<std::thread::JoinHandle<anyhow::Result<NarrationFile>>> =
                None;
            for (index, passage) in plan.passages.iter().enumerate().skip(plan.index) {
                if cancel.is_cancelled() {
                    return Ok(());
                }
                let text = passage["text"].as_str().unwrap_or("");
                if text.is_empty() {
                    continue;
                }
                let offset = if index == plan.index { plan.offset } else { 0. };
                {
                    let services = app.state::<Services>();
                    let _transition = services
                        .playback_state_gate
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Playback state is unavailable"))?;
                    if cancel.is_cancelled() {
                        return Ok(());
                    }
                    if let Some((_, active)) = services
                        .narration_playback
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Narration state is unavailable"))?
                        .as_mut()
                    {
                        active.index = index;
                        active.offset = offset;
                    };
                }
                // Synthesize a stable 1x source. Playback speed is applied by
                // the codec so elapsed offsets stay in the same source units.
                let file = if let Some(prefetched) = lookahead.take() {
                    prefetched
                        .join()
                        .map_err(|_| anyhow::anyhow!("Speech prefetch worker stopped"))??
                } else {
                    render_narration_passage(&app, &hub, text, &plan.voice, cancel.clone(), index)?
                };
                if cancel.is_cancelled() {
                    return Ok(());
                }
                if let Some(next) = plan
                    .passages
                    .get(index + 1)
                    .and_then(|p| p["text"].as_str())
                    .filter(|s| !s.is_empty())
                {
                    let text = next.to_owned();
                    let engine = hub.clone();
                    let voice = plan.voice.clone();
                    let token = cancel.clone();
                    let application = app.clone();
                    lookahead = Some(std::thread::spawn(move || {
                        render_narration_passage(
                            &application,
                            &engine,
                            &text,
                            &voice,
                            token,
                            index + 1,
                        )
                    }));
                }
                let paused = app
                    .state::<Services>()
                    .narration_pause_signal
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Playback state is unavailable"))?
                    .clone();
                let audio = hub.audio_play_requested_from(
                    &file.relative,
                    plan.rate,
                    &playback_request,
                    offset,
                    paused,
                )?;
                let duration = audio["duration"].as_f64().unwrap_or(0.);
                {
                    let services = app.state::<Services>();
                    let _transition = services
                        .playback_state_gate
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Playback state is unavailable"))?;
                    if cancel.is_cancelled() {
                        return Ok(());
                    }
                    let paused = *services
                        .paused
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Playback state is unavailable"))?;
                    hub.audio_pause(paused)?;
                    if let Some(view) = app.get_webview("book-reader") {
                        let _ = view.eval(format!("if(window.__KODI_BOOT__?.documentId==={})window.__reader.setNarrationRange({});",crate::reader::script_json(&json!(session.document_id)),crate::reader::script_json(passage)));
                    }
                }
                while hub.audio_position()["position"]
                    .as_f64()
                    .unwrap_or(duration)
                    < duration
                    && !cancel.is_cancelled()
                {
                    let services = app.state::<Services>();
                    let transition = services
                        .playback_state_gate
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Playback state is unavailable"))?;
                    if cancel.is_cancelled() {
                        return Ok(());
                    }
                    let elapsed = hub.audio_position()["position"].as_f64().unwrap_or(0.);
                    let paused = *services
                        .paused
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Playback state is unavailable"))?;
                    let _ = app.emit_to(
                        "main-ui",
                        "audio-state",
                        narration_audio_state(
                            &services,
                            if paused { "paused" } else { "playing" },
                            elapsed,
                        ),
                    );
                    drop(transition);
                    std::thread::sleep(std::time::Duration::from_millis(250));
                }
                if cancel.is_cancelled() {
                    return Ok(());
                }
                {
                    let services = app.state::<Services>();
                    let _transition = services
                        .playback_state_gate
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Playback state is unavailable"))?;
                    if cancel.is_cancelled() {
                        return Ok(());
                    }
                    if let Some((_, active)) = services
                        .narration_playback
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Narration state is unavailable"))?
                        .as_mut()
                    {
                        active.offset = duration;
                    }
                    hub.audio_finish_requested(&playback_request)?;
                }
            }
            Ok(())
        })();
        if cancel.is_cancelled() {
            return;
        }
        if run.is_ok() && session.spine_index + 1 < session.total_spines {
            let current = app
                .state::<NativeState>()
                .reader
                .lock()
                .ok()
                .and_then(|s| s.clone());
            if current
                .as_ref()
                .is_some_and(|s| s.document_id == session.document_id)
            {
                tauri::async_runtime::spawn(async move {
                    if let Some(view) = app.get_webview("main-ui") {
                        let target = kodi_reader_core::Locator {
                            kind: kodi_reader_core::DocumentKind::Epub,
                            spine_index: session.spine_index + 1,
                            ..Default::default()
                        };
                        if let Err(error) = crate::reader::open_book(
                            view,
                            app.clone(),
                            session.book_id,
                            Some(session.spine_index + 1),
                            Some(target),
                            None,
                            Some(json!({"voice":plan.voice,"rate":plan.rate,"ticket":ticket})),
                        )
                        .await
                        {
                            if !cancel.is_cancelled() {
                                let _ = app.emit_to(
                                    "main-ui",
                                    "audio-state",
                                    json!({"phase":"idle","error":error}),
                                );
                            }
                        }
                    }
                });
                return;
            }
        }
        let services = app.state::<Services>();
        if let Ok(_transition) = services.playback_state_gate.lock() {
            if cancel.is_cancelled() {
                return;
            }
            stop_narration_locked(&app, &services);
            if let Err(error) = run {
                let _ = app.emit_to(
                    "main-ui",
                    "audio-state",
                    json!({"phase":"idle","error":error.to_string()}),
                );
            }
        };
    });
    Ok(())
}
pub(crate) fn stop_narration(app: &tauri::AppHandle) {
    let state = app.state::<Services>();
    let Ok(_transition) = state.playback_state_gate.lock() else {
        return;
    };
    stop_narration_locked(app, &state);
}
pub(crate) fn validate_narration(app: &tauri::AppHandle, request: &Value) -> Result<()> {
    let state = app.state::<Services>();
    let ticket = request["ticket"]
        .as_str()
        .ok_or("Missing narration request")?;
    if lock(&state.narration_ticket)?.as_deref() == Some(ticket) {
        Ok(())
    } else {
        Err("This narration request has ended.".into())
    }
}
fn stop_narration_locked(app: &tauri::AppHandle, state: &Services) {
    state
        .playback_generation
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    if let Ok(mut path) = state.playback_path.lock() {
        *path = None;
    }
    if let Ok(mut token) = state.narration.lock() {
        if let Some(token) = token.take() {
            token.cancel();
        }
    }
    if let Ok(mut ticket) = state.narration_ticket.lock() {
        *ticket = None;
    }
    if let Ok(mut playback) = state.narration_playback.lock() {
        *playback = None;
    }
    let _ = state.hub.audio_stop();
    if let Ok(mut paused) = state.paused.lock() {
        *paused = false;
    }
    if let Ok(signal) = state.narration_pause_signal.lock() {
        signal.store(false, std::sync::atomic::Ordering::SeqCst);
    }
    let _ = app.emit_to("main-ui", "audio-state", json!({"phase":"idle"}));
}
pub(crate) fn pause_narration(app: &tauri::AppHandle) {
    let state = app.state::<Services>();
    let Ok(_transition) = state.playback_state_gate.lock() else {
        return;
    };
    if state.narration.lock().ok().is_some_and(|n| n.is_some()) {
        if let Ok(signal) = state.narration_pause_signal.lock() {
            signal.store(true, std::sync::atomic::Ordering::SeqCst);
        }
        let _ = state.hub.audio_pause(true);
        if let Ok(mut paused) = state.paused.lock() {
            *paused = true;
        }
        let _ = app.emit_to("main-ui", "audio-state", {
            let plan = lock(&state.narration_playback)
                .ok()
                .and_then(|value| value.clone());
            let offset = plan
                .as_ref()
                .map(|(_, plan)| narration_source_offset(&state, plan))
                .unwrap_or(0.);
            narration_audio_state(&state, "paused", offset)
        });
    }
}
#[tauri::command]
pub(crate) fn narration_pause(
    view: Webview,
    app: tauri::AppHandle,
    state: State<Services>,
    session_id: String,
    paused: Option<bool>,
) -> Result<()> {
    ui(&view)?;
    let native = app.state::<NativeState>();
    if !lock(&native.reader)?.as_ref().is_some_and(|session| {
        session.session_id == session_id && session.kind == kodi_reader_core::DocumentKind::Epub
    }) {
        return Err("Open the active EPUB to pause narration.".into());
    }
    let _transition = lock(&state.playback_state_gate)?;
    if lock(&state.narration_ticket)?.is_none() {
        return Err("No narration is active.".into());
    }
    let next = paused.unwrap_or(!*lock(&state.paused)?);
    lock(&state.narration_pause_signal)?.store(next, std::sync::atomic::Ordering::SeqCst);
    if state.hub.audio_position()["duration"]
        .as_f64()
        .unwrap_or(0.)
        > 0.
    {
        state.hub.audio_pause(next).map_err(|e| e.to_string())?;
    }
    *lock(&state.paused)? = next;
    let _ = app.emit_to("main-ui", "audio-state", {
        let plan = lock(&state.narration_playback)?.clone();
        let offset = plan
            .as_ref()
            .map(|(_, plan)| narration_source_offset(&state, plan))
            .unwrap_or(0.);
        narration_audio_state(&state, if next { "paused" } else { "playing" }, offset)
    });
    Ok(())
}
#[tauri::command]
pub(crate) fn narration_stop(view: Webview, app: tauri::AppHandle) -> Result<()> {
    ui(&view)?;
    stop_narration(&app);
    Ok(())
}

#[tauri::command]
pub(crate) async fn updates_check(view: Webview, app: tauri::AppHandle) -> Result<Value> {
    ui(&view)?;
    if !app.state::<Services>().updates_configured {
        return Ok(
            json!({"available":false,"configured":false,"message":"Updates are available in signed release builds."}),
        );
    }
    use tauri_plugin_updater::UpdaterExt;
    let can_install = cfg!(windows) || std::env::var_os("APPIMAGE").is_some();
    let update = app
        .updater()
        .map_err(|e| e.to_string())?
        .check()
        .await
        .map_err(|e| e.to_string())?;
    Ok(update.map(|u|json!({"available":true,"version":u.version,"notes":u.body,"canInstall":can_install,"downloadUrl":"https://www.kodi-reader.app/#desktop-downloads"})).unwrap_or(json!({"available":false})))
}
#[tauri::command]
pub(crate) async fn updates_install(view: Webview, app: tauri::AppHandle) -> Result<()> {
    ui(&view)?;
    if !app.state::<Services>().updates_configured {
        return Err("This build has no signed update configuration.".into());
    }
    if cfg!(target_os = "linux") && std::env::var_os("APPIMAGE").is_none() {
        return Err("Download the current package to update this installation.".into());
    }
    use tauri_plugin_updater::UpdaterExt;
    let update = app
        .updater()
        .map_err(|e| e.to_string())?
        .check()
        .await
        .map_err(|e| e.to_string())?
        .ok_or("No update is available")?;
    update
        .download_and_install(|_, _| {}, || {})
        .await
        .map_err(|e| e.to_string())
}
