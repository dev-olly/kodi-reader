use crate::{changed, layout, lock, ui, Bounds, NativeState, Result};
use kodi_reader_core::{DocumentKind, Locator};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{Emitter, Manager, State, Webview};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReaderSession {
    pub session_id: String,
    pub book_id: String,
    pub document_id: String,
    pub url: String,
    pub kind: DocumentKind,
    pub spine_index: usize,
    pub total_spines: usize,
    pub initial_locator: Option<Locator>,
    pub fragment: Option<String>,
    pub narration: Option<Value>,
}

pub(crate) fn origin() -> &'static str {
    if cfg!(windows) {
        "http://kodi.localhost"
    } else {
        "kodi://localhost"
    }
}

pub(crate) fn script_json(value: &Value) -> String {
    value
        .to_string()
        .replace('<', "\\u003c")
        .replace('>', "\\u003e")
        .replace('&', "\\u0026")
        .replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029")
}

/// Caller holds open_gate. Invalidate pending downloads too: they do not own
/// an active ReaderSession yet, but must not reopen a just-removed document.
pub(crate) fn begin_book_removal(state: &NativeState, book_id: &str) -> Result<bool> {
    lock(&state.library)?
        .book(book_id)
        .map_err(|error| error.to_string())?;
    state
        .opening
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    Ok(lock(&state.reader)?
        .as_ref()
        .is_some_and(|session| session.book_id == book_id))
}

fn require_current_open(state: &NativeState, generation: u64) -> Result<()> {
    if state.opening.load(std::sync::atomic::Ordering::SeqCst) != generation {
        return Err("A newer document has been opened.".into());
    }
    Ok(())
}

#[tauri::command]
pub(crate) async fn open_book(
    view: Webview,
    app: tauri::AppHandle,
    book_id: String,
    spine_index: Option<usize>,
    initial_locator: Option<Locator>,
    fragment: Option<String>,
    narration: Option<Value>,
) -> Result<ReaderSession> {
    ui(&view)?;
    if let Some(request) = &narration {
        crate::service_commands::validate_narration(&app, request)?;
    } else {
        crate::service_commands::stop_narration(&app);
    }
    let generation = app
        .state::<NativeState>()
        .opening
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        + 1;
    crate::service_commands::ensure_document(&app, &book_id).await?;
    if let Some(request) = &narration {
        crate::service_commands::validate_narration(&app, request)?;
    }
    let state = app.state::<NativeState>();
    let _opening = state.open_gate.lock().await;
    require_current_open(&state, generation)?;
    let (book, publication) = {
        let store = lock(&state.library)?;
        let snapshot = store.snapshot();
        (
            snapshot
                .books
                .get(&book_id)
                .cloned()
                .ok_or("Document not found")?,
            store.publication(&book_id).map_err(|e| e.to_string())?,
        )
    };
    let total = publication.reading_order.len().max(1);
    validate_open_target(book.kind, total, spine_index, initial_locator.as_ref())?;
    let index = spine_index
        .or_else(|| initial_locator.as_ref().map(|l| l.spine_index))
        .or_else(|| book.position.as_ref().map(|p| p.spine_index))
        .unwrap_or(0);
    validate_open_target(book.kind, total, Some(index), None)?;
    let token = uuid::Uuid::new_v4().to_string();
    let path = if book.kind == DocumentKind::Epub {
        format!(
            "book/{token}/{}",
            publication.reading_order[index]
                .href
                .split('#')
                .next()
                .unwrap_or_default()
        )
    } else {
        format!("pdf/{token}/index.html")
    };
    let session = ReaderSession {
        session_id: token,
        book_id,
        document_id: uuid::Uuid::new_v4().to_string(),
        url: format!("{}/{path}", origin()),
        kind: book.kind,
        spine_index: index,
        total_spines: total,
        initial_locator,
        fragment,
        narration,
    };
    require_current_open(&state, generation)?;
    *lock(&state.reader)? = Some(session.clone());
    if session.narration.is_some() {
        app.emit_to("main-ui", "reader-session", &session)
            .map_err(|e| e.to_string())?;
    }
    let bounds = *lock(&state.bounds)?;
    if let Some(existing) = app.get_webview("book-reader") {
        existing
            .navigate(
                session
                    .url
                    .parse()
                    .map_err(|e: url::ParseError| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
        layout::position(&existing, bounds)?;
    } else {
        let window = app
            .get_window("main-ui")
            .ok_or("The main window is unavailable")?;
        let handle = app.clone();
        let builder=tauri::webview::WebviewBuilder::new("book-reader",tauri::WebviewUrl::External(session.url.parse().map_err(|e:url::ParseError|e.to_string())?))
            .initialization_script("window.__KODI_INVOKE__=(command,args)=>window.__TAURI_INTERNALS__.invoke(command,args);")
            .on_navigation(move |url| {
                let state=handle.state::<NativeState>();
                state.reader.lock().ok().and_then(|s|s.clone()).is_some_and(|s|url.as_str().starts_with(&format!("{}/book/{}/",origin(),s.session_id))||url.as_str().starts_with(&format!("{}/pdf/{}/",origin(),s.session_id)))
            })
            .on_new_window(|_,_|tauri::webview::NewWindowResponse::Deny);
        // Commands are async: WebView2 creation must never block its UI thread.
        let native = window
            .add_child(
                builder,
                tauri::LogicalPosition::new(bounds.x, bounds.y),
                tauri::LogicalSize::new(bounds.width.max(1.), bounds.height.max(1.)),
            )
            .map_err(|e| e.to_string())?;
        layout::mount(&native)?;
        layout::position(&native, bounds)?;
    }
    // Restore a removed card only after its document, target and native view
    // have opened successfully. A failed attempt keeps local visibility intact.
    {
        let mut store = lock(&state.library)?;
        let snapshot = store
            .mutate(|l| {
                if let Some(b) = l.books.get_mut(&session.book_id) {
                    b.last_opened_at = kodi_reader_core::now();
                    b.extra.remove("removedFromLibrary");
                }
                Ok(())
            })
            .map_err(|e| e.to_string())?;
        changed(&app, snapshot)?;
    }
    Ok(session)
}

#[tauri::command]
pub(crate) async fn reader_bounds(
    view: Webview,
    app: tauri::AppHandle,
    state: State<'_, NativeState>,
    session_id: String,
    bounds: Bounds,
) -> Result<()> {
    ui(&view)?;
    let _transition = state.open_gate.lock().await;
    if lock(&state.reader)?.as_ref().map(|s| s.session_id.as_str()) != Some(session_id.as_str()) {
        return Ok(());
    }
    if [bounds.x, bounds.y, bounds.width, bounds.height]
        .iter()
        .any(|v| !v.is_finite() || *v < 0. || *v > 32768.)
    {
        return Err("Invalid reader bounds".into());
    }
    *lock(&state.bounds)? = bounds;
    if let Some(reader) = app.get_webview("book-reader") {
        layout::position(&reader, bounds)?;
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ReaderActionOutcome {
    Applied,
    Superseded,
}

async fn action_context<'a>(
    gate: &'a tokio::sync::Mutex<()>,
    current: &std::sync::Mutex<Option<ReaderSession>>,
    requested: &str,
) -> Result<(tokio::sync::MutexGuard<'a, ()>, Option<ReaderSession>)> {
    // Await before reading the session: an opening/close already in progress
    // must finish before this command decides which document it may operate on.
    let transition = gate.lock().await;
    let session = lock(current)?
        .as_ref()
        .filter(|session| session.session_id == requested)
        .cloned();
    Ok((transition, session))
}

fn take_matching_session(
    current: &mut Option<ReaderSession>,
    requested: &str,
) -> Option<ReaderSession> {
    if current
        .as_ref()
        .is_some_and(|session| session.session_id == requested)
    {
        current.take()
    } else {
        None
    }
}

#[tauri::command]
pub(crate) async fn reader_action(
    view: Webview,
    app: tauri::AppHandle,
    state: State<'_, NativeState>,
    session_id: String,
    action: String,
    payload: Option<Value>,
) -> Result<ReaderActionOutcome> {
    ui(&view)?;
    let allowed = [
        "close",
        "nextPage",
        "previousPage",
        "goToPosition",
        "goToFragment",
        "goToPage",
        "goToEnd",
        "setHighlights",
        "setReminders",
        "setReadingMarker",
        "setReadingMarkerPlacement",
        "clearSelection",
        "configure",
        "notifyState",
        "restoreReferencePosition",
        "setNarrationRange",
    ];
    if !allowed.contains(&action.as_str()) {
        return Err("Unsupported reader action".into());
    }
    let (_transition, session) =
        action_context(&state.open_gate, &state.reader, &session_id).await?;
    let Some(session) = session else {
        // Trusted UI effects queued before a chapter transition are expected.
        // They may neither change the replacement nor raise a user-facing error.
        return Ok(ReaderActionOutcome::Superseded);
    };
    if action == "close" {
        state
            .opening
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        if let Some(reader) = app.get_webview("book-reader") {
            reader.close().map_err(|e| e.to_string())?;
        }
        take_matching_session(&mut *lock(&state.reader)?, &session.session_id);
        return Ok(ReaderActionOutcome::Applied);
    }
    if action == "goToFragment" || action == "restoreReferencePosition" {
        crate::service_commands::pause_narration(&app);
    }
    let guarded = action_script(&session, &action, payload);
    app.get_webview("book-reader")
        .ok_or("The reader is closed")?
        .eval(guarded)
        .map_err(|e| e.to_string())?;
    Ok(ReaderActionOutcome::Applied)
}

fn action_script(session: &ReaderSession, action: &str, payload: Option<Value>) -> String {
    let mut payload = payload.unwrap_or(Value::Null);
    if action == "goToPosition"
        && session.kind == DocumentKind::Epub
        && payload.get("start").is_some()
    {
        payload = payload["start"].clone();
    }
    let script = if action == "nextPage" || action == "previousPage" {
        let event = if action == "nextPage" {
            "reachedEnd"
        } else {
            "reachedStart"
        };
        format!("if(window.__reader && !window.__reader.{action}()) window.__kodiPost({{type:'{event}'}});")
    } else {
        format!(
            "window.__reader && window.__reader.{action}({});",
            script_json(&payload)
        )
    };
    guard_script(session, &script)
}

fn guard_script(session: &ReaderSession, script: &str) -> String {
    format!(
        "if(window.__KODI_BOOT__ && window.__KODI_BOOT__.sessionId==={} && window.__KODI_BOOT__.documentId==={}){{{script}}}",
        script_json(&json!(session.session_id)),
        script_json(&json!(session.document_id))
    )
}

#[tauri::command]
pub(crate) async fn reader_event(
    view: Webview,
    app: tauri::AppHandle,
    state: State<'_, NativeState>,
    session_id: String,
    document_id: String,
    message: Value,
) -> Result<()> {
    if view.label() != "book-reader" {
        return Err("Reader events require the active publication view.".into());
    }
    if message.to_string().len() > 1024 * 1024 {
        return Err("Reader event is too large".into());
    }
    let kind = message["type"].as_str().ok_or("Invalid reader event")?;
    let allowed = [
        "domReady",
        "ready",
        "pageChanged",
        "selection",
        "selectionCleared",
        "readingMarkerPlaced",
        "readingMarkerRequested",
        "highlightTapped",
        "reminderTapped",
        "reminderFocusChanged",
        "highlightsResolved",
        "link",
        "reachedEnd",
        "reachedStart",
        "error",
        "narrationPassages",
    ];
    if !allowed.contains(&kind) {
        return Err("Unsupported reader event".into());
    }
    let _transition = state.open_gate.lock().await;
    let session = event_session(
        &mut *lock(&state.reader)?,
        &session_id,
        &document_id,
        kind,
        &message,
    )?;
    if kind == "pageChanged" || kind == "readingMarkerPlaced" {
        let mut locator = event_locator(&session, kind, &message)?;
        let progress = message["progression"].as_f64().unwrap_or(0.).clamp(0., 1.);
        let total_progress = (session.spine_index as f64 + progress) / session.total_spines as f64;
        if kind == "pageChanged" {
            locator.total_progression = Some(total_progress);
        }
        let snapshot = lock(&state.library)?
            .mutate(|library| {
                if let Some(book) = library.books.get_mut(&session.book_id) {
                    if kind == "readingMarkerPlaced" {
                        book.reading_marker = Some(locator);
                    } else {
                        book.position = Some(locator);
                        book.progress = total_progress;
                        book.last_opened_at = kodi_reader_core::now();
                    }
                }
                Ok(())
            })
            .map_err(|e| e.to_string())?;
        changed(&app, snapshot)?;
    }
    if kind == "narrationPassages" {
        crate::service_commands::narrate_passages(app.clone(), message.clone())?;
    }
    app.emit_to("main-ui","reader-event",json!({"sessionId":session.session_id,"bookId":session.book_id,"documentId":session.document_id,"message":message})).map_err(|e|e.to_string())
}

fn validate_open_target(
    kind: DocumentKind,
    total: usize,
    spine_index: Option<usize>,
    locator: Option<&Locator>,
) -> Result<()> {
    if locator.is_some_and(|locator| locator.kind != kind) {
        return Err("The reading target belongs to another document type.".into());
    }
    if let (Some(index), Some(locator)) = (spine_index, locator) {
        if index != locator.spine_index {
            return Err("The reading target belongs to another chapter or page.".into());
        }
    }
    if spine_index
        .or_else(|| locator.map(|locator| locator.spine_index))
        .is_some_and(|index| index >= total)
    {
        return Err(if kind == DocumentKind::Pdf {
            "This PDF page does not exist."
        } else {
            "This chapter does not exist."
        }
        .into());
    }
    Ok(())
}

fn event_locator(session: &ReaderSession, event: &str, message: &Value) -> Result<Locator> {
    let target = message
        .get("spineIndex")
        .map(|value| {
            value
                .as_u64()
                .and_then(|value| usize::try_from(value).ok())
                .ok_or("Invalid reader page or chapter")
        })
        .transpose()?
        .unwrap_or(session.spine_index);
    let start = message
        .get("position")
        .or_else(|| message.get("start"))
        .cloned()
        .unwrap_or(json!({"elementPath":[],"offset":0}));
    let mut value = message
        .get("locator")
        .cloned()
        .unwrap_or_else(|| json!({"start":start}));
    let object = value.as_object_mut().ok_or("Invalid reader position")?;
    object.entry("kind").or_insert(json!(session.kind));
    object.entry("spineIndex").or_insert(json!(target));
    let locator: Locator = serde_json::from_value(value).map_err(|_| "Invalid reader position")?;
    // A PDF marker may be placed on the second page of a visible spread.
    // Position events and all EPUB markers belong to the active spine itself.
    if locator.kind != session.kind
        || locator.spine_index >= session.total_spines
        || (session.kind == DocumentKind::Epub || event == "pageChanged")
            && locator.spine_index != session.spine_index
        || message.get("spineIndex").is_some() && locator.spine_index != target
    {
        return Err("The reader position belongs to another chapter or page.".into());
    }
    if locator.start.element_path.len() > 256
        || locator
            .end
            .as_ref()
            .is_some_and(|end| end.element_path.len() > 256)
        || locator
            .total_progression
            .is_some_and(|progress| !(0. ..=1.).contains(&progress))
    {
        return Err("Invalid reader position".into());
    }
    Ok(locator)
}

fn event_session(
    current: &mut Option<ReaderSession>,
    session_id: &str,
    document_id: &str,
    kind: &str,
    message: &Value,
) -> Result<ReaderSession> {
    let session = current.as_mut().ok_or("The reader is closed")?;
    if session.session_id != session_id || session.document_id != document_id {
        return Err("Stale reader event".into());
    }
    // Validate and update the actual active record in one reader-lock scope.
    // Never write an earlier cloned session over a replacement chapter/book.
    let mut candidate = session.clone();
    if candidate.kind == DocumentKind::Pdf && kind == "pageChanged" {
        let page = message["spineIndex"].as_u64().ok_or("Invalid PDF page")? as usize;
        let count = message["pageCount"]
            .as_u64()
            .ok_or("Invalid PDF page count")? as usize;
        if count == 0 || count > 100000 || page >= count {
            return Err("Invalid PDF page position".into());
        }
        candidate.spine_index = page;
        candidate.total_spines = count;
    }
    if kind == "pageChanged" || kind == "readingMarkerPlaced" {
        event_locator(&candidate, kind, message)?;
    }
    *session = candidate.clone();
    Ok(candidate)
}

pub(crate) fn refresh(app: &tauri::AppHandle) -> Result<()> {
    let state = app.state::<NativeState>();
    let Some(session) = lock(&state.reader)?.clone() else {
        return Ok(());
    };
    let Some(view) = app.get_webview("book-reader") else {
        return Ok(());
    };
    let boot = boot(app, &session)?;
    view.eval(guard_script(
        &session,
        &format!(
            "window.__kodiRefresh && window.__kodiRefresh({});",
            script_json(&boot)
        ),
    ))
    .map_err(|e| e.to_string())
}

fn boot(app: &tauri::AppHandle, session: &ReaderSession) -> Result<Value> {
    let state = app.state::<NativeState>();
    let library = lock(&state.library)?.snapshot();
    let book = library
        .books
        .get(&session.book_id)
        .ok_or("Document not found")?;
    Ok(
        json!({"sessionId":session.session_id,"documentId":session.document_id,"bookId":session.book_id,"kind":session.kind,"spineIndex":session.spine_index,"position":session.initial_locator.as_ref().or(book.position.as_ref()),"fragment":session.fragment,"narration":session.narration,"annotations":book.annotations,"reminders":book.reminders,"readingMarker":book.reading_marker,"settings":library.settings,"pdfUrl":format!("{}/document/{}",origin(),session.session_id)}),
    )
}

pub(crate) fn protocol(
    app: &tauri::AppHandle,
    caller: &str,
    request: tauri::http::Request<Vec<u8>>,
) -> tauri::http::Response<Vec<u8>> {
    match response(app, caller, request.uri().path()) {
        Ok((bytes, mime, csp)) => {
            let mut builder = tauri::http::Response::builder()
                .header("Content-Type", mime)
                .header("X-Content-Type-Options", "nosniff")
                .header("Cache-Control", "no-store");
            if let Some(csp) = csp {
                builder = builder.header("Content-Security-Policy", csp);
            }
            builder.body(bytes).unwrap()
        }
        Err(_) => tauri::http::Response::builder()
            .status(404)
            .header("Content-Type", "text/plain")
            .body(b"This publication resource is unavailable.".to_vec())
            .unwrap(),
    }
}

fn response(
    app: &tauri::AppHandle,
    caller: &str,
    path: &str,
) -> Result<(Vec<u8>, String, Option<String>)> {
    let state = app.state::<NativeState>();
    let route = path.trim_start_matches('/');
    if let Some(relative) = route.strip_prefix("media/") {
        if caller != "main-ui" {
            return Err("Media access requires the interface".into());
        }
        let (_, relative) = relative.split_once('/').ok_or("Invalid media path")?;
        let relative = percent_encoding::percent_decode_str(relative)
            .decode_utf8()
            .map_err(|e| e.to_string())?;
        let root = lock(&state.library)?.root().to_path_buf();
        let full = crate::safe_relative(&root, &relative)?;
        let mime = match relative
            .rsplit('.')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str()
        {
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "webp" => "image/webp",
            "gif" => "image/gif",
            "svg" => "image/svg+xml",
            _ => "application/octet-stream",
        };
        return Ok((
            std::fs::read(full).map_err(|e| e.to_string())?,
            mime.into(),
            None,
        ));
    }
    let asset_route = route
        .strip_prefix("pdf/vendor/pdfjs/")
        .map(|p| format!("vendor/pdfjs/{p}"));
    if let Some(asset) = route.strip_prefix("asset/").or(asset_route.as_deref()) {
        if !asset.starts_with("vendor/pdfjs/") {
            return Err("Unknown asset".into());
        }
        let (bytes, mime) = bundled_asset(app, asset)?;
        return Ok((bytes, mime, None));
    }
    let session = lock(&state.reader)?.clone().ok_or("The reader is closed")?;
    if caller != "book-reader" {
        return Err("Publication access requires the reader view".into());
    }
    if route == format!("document/{}", session.session_id) {
        let store = lock(&state.library)?;
        let library = store.snapshot();
        let book = library
            .books
            .get(&session.book_id)
            .ok_or("Document not found")?;
        let full = crate::safe_relative(store.root(), &book.imported_relative_path)?;
        return Ok((
            std::fs::read(full).map_err(|e| e.to_string())?,
            "application/pdf".into(),
            None,
        ));
    }
    let prefix = format!("book/{}/", session.session_id);
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    let csp=format!("default-src 'none'; script-src 'nonce-{nonce}'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; media-src 'self'; connect-src 'self' ipc: http://ipc.localhost https://ipc.localhost; worker-src 'self' blob:; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'");
    if let Some(path) = route.strip_prefix(&prefix) {
        if path == "__runtime/reader.js" {
            return Ok((
                include_bytes!("../../public/vendor/reader/reader.js").to_vec(),
                "text/javascript".into(),
                None,
            ));
        }
        if path == "__runtime/reader.css" {
            return Ok((
                include_bytes!("../../public/vendor/reader/reader.css").to_vec(),
                "text/css".into(),
                None,
            ));
        }
        let resource = lock(&state.library)?
            .resource(&session.book_id, path)
            .map_err(|e| e.to_string())?;
        if !resource.media_type.contains("html") {
            return Ok((resource.bytes, resource.media_type, Some(csp)));
        }
        let html = crate::chapter::decode(&resource.bytes)?;
        let runtime_root = format!("{}/{prefix}__runtime", origin());
        let source = format!(
            "window.__KODI_BOOT__={};{}",
            script_json(&boot(app, &session)?),
            include_str!("../../public/vendor/reader/bridge.js")
        );
        let source = if resource.media_type.contains("xhtml") {
            format!("<![CDATA[{source}]]>")
        } else {
            source
        };
        let ns = if resource.media_type.contains("xhtml") {
            " xmlns=\"http://www.w3.org/1999/xhtml\""
        } else {
            ""
        };
        let tags=format!("<meta{ns} http-equiv=\"Content-Security-Policy\" content=\"{csp}\"/><script{ns} nonce=\"{nonce}\">{source}</script><link{ns} rel=\"stylesheet\" href=\"{runtime_root}/reader.css\"/><script{ns} nonce=\"{nonce}\" src=\"{runtime_root}/reader.js\"></script>");
        let html = crate::chapter::inject(&html, &tags)?;
        return Ok((
            html.into_bytes(),
            format!("{}; charset=utf-8", resource.media_type),
            Some(csp),
        ));
    }
    let pdf_prefix = format!("pdf/{}/", session.session_id);
    if let Some(path) = route.strip_prefix(&pdf_prefix) {
        let (bytes, mime) = bundled_asset(app, &format!("pdf-viewer/{path}"))?;
        if path == "index.html" {
            let html = String::from_utf8(bytes).map_err(|e| e.to_string())?;
            let script = format!(
                "<script nonce=\"{nonce}\">window.__KODI_BOOT__={};</script>",
                script_json(&boot(app, &session)?)
            );
            let html = html.replacen("<head>", &format!("<head>{script}"), 1);
            // PDF viewer is bundled trusted code, loaded in the restricted book view.
            let pdf_csp=format!("default-src 'none'; script-src 'self' 'nonce-{nonce}'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; font-src 'self' data:; connect-src 'self' ipc: http://ipc.localhost https://ipc.localhost; worker-src 'self' blob:; object-src 'none'; frame-src 'none'; base-uri 'none'");
            return Ok((html.into_bytes(), "text/html".into(), Some(pdf_csp)));
        }
        return Ok((bytes, mime, None));
    }
    Err("Unknown publication resource".into())
}

fn bundled_asset(app: &tauri::AppHandle, path: &str) -> Result<(Vec<u8>, String)> {
    if path
        .split('/')
        .any(|p| p.is_empty() || p == ".." || p == ".")
        || path.contains('\\')
    {
        return Err("Invalid bundled asset path".into());
    }
    if let Some(asset) = app.asset_resolver().get(path.to_string()) {
        return Ok((asset.bytes, asset.mime_type));
    }
    #[cfg(debug_assertions)]
    {
        // Vite serves the UI in development, so the embedded asset map can be
        // empty. Reader resources still come only from our vendored public tree.
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../public");
        let full = crate::safe_relative(&root, path)?;
        let mime = match full.extension().and_then(|e| e.to_str()).unwrap_or("") {
            "js" | "mjs" => "text/javascript",
            "css" => "text/css",
            "html" => "text/html",
            "wasm" => "application/wasm",
            "ttf" => "font/ttf",
            "woff" => "font/woff",
            "woff2" => "font/woff2",
            "svg" => "image/svg+xml",
            "png" => "image/png",
            _ => "application/octet-stream",
        };
        Ok((std::fs::read(full).map_err(|e| e.to_string())?, mime.into()))
    }
    #[cfg(not(debug_assertions))]
    Err("Missing bundled reader asset".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    };

    fn session(id: &str, document: &str, kind: DocumentKind) -> ReaderSession {
        ReaderSession {
            session_id: id.into(),
            document_id: document.into(),
            book_id: "book".into(),
            url: "kodi://localhost/book/test/chapter.xhtml".into(),
            kind,
            spine_index: 0,
            total_spines: 10,
            initial_locator: None,
            fragment: None,
            narration: None,
        }
    }

    fn cloud_only_state() -> (tempfile::TempDir, Arc<NativeState>, String) {
        let directory = tempfile::tempdir().unwrap();
        let mut store =
            kodi_reader_core::LibraryStore::open(directory.path().to_path_buf()).unwrap();
        let book = store
            .import_article(&kodi_reader_core::Article {
                title: "Pending cloud download".into(),
                author: "Test".into(),
                source_url: "https://example.org/pending".into(),
                html: "<p>Reading fixture.</p>".into(),
                images: vec![],
            })
            .unwrap();
        store.remove_local_download(&book.id).unwrap();
        store
            .update_book(&book.id, |book| {
                book.extra
                    .insert("cloudFile".into(), json!({"hash":"fixture"}));
                Ok(())
            })
            .unwrap();
        let state = Arc::new(NativeState {
            library: Mutex::new(store),
            reader: Mutex::new(None),
            bounds: Mutex::new(Bounds::default()),
            sketches: Mutex::new(Default::default()),
            opening: std::sync::atomic::AtomicU64::new(0),
            open_gate: tokio::sync::Mutex::new(()),
        });
        (directory, state, book.id)
    }

    #[test]
    fn removal_cancels_pending_cloud_open_even_without_an_active_reader() {
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            for delete_data in [false, true] {
                let (_directory, state, book_id) = cloud_only_state();
                let generation = state.opening.fetch_add(1, Ordering::SeqCst) + 1;
                let (download_started, started) = tokio::sync::oneshot::channel();
                let (finish_download, download_finished) = tokio::sync::oneshot::channel();
                let pending = {
                    let state = state.clone();
                    let book_id = book_id.clone();
                    tokio::spawn(async move {
                        download_started.send(()).unwrap();
                        download_finished.await.unwrap();
                        let _transition = state.open_gate.lock().await;
                        // This is the same check open_book makes immediately
                        // after a download resolves, before any visible state.
                        require_current_open(&state, generation)?;
                        lock(&state.library)?
                            .update_book(&book_id, |book| {
                                book.extra.remove("removedFromLibrary");
                                Ok(())
                            })
                            .map_err(|error| error.to_string())?;
                        let mut replacement = session("stale", "stale-doc", DocumentKind::Epub);
                        replacement.book_id = book_id;
                        *lock(&state.reader)? = Some(replacement);
                        Ok::<_, String>(())
                    })
                };
                started.await.unwrap();
                {
                    let _transition = state.open_gate.lock().await;
                    assert!(lock(&state.reader).unwrap().is_none());
                    assert!(!begin_book_removal(&state, &book_id).unwrap());
                    let mut store = lock(&state.library).unwrap();
                    if delete_data {
                        store.delete_book(&book_id).unwrap();
                    } else {
                        store.remove_from_library(&book_id).unwrap();
                    }
                }
                finish_download.send(()).unwrap();
                assert!(pending.await.unwrap().is_err());
                assert!(lock(&state.reader).unwrap().is_none());
                let store = lock(&state.library).unwrap();
                if delete_data {
                    assert!(store.book(&book_id).is_err());
                } else {
                    assert_eq!(
                        store.book(&book_id).unwrap().extra["removedFromLibrary"],
                        true
                    );
                }
            }
        });
    }

    #[test]
    fn rejected_removal_does_not_cancel_an_existing_pending_open() {
        let (_directory, state, _book_id) = cloud_only_state();
        let generation = state.opening.fetch_add(1, Ordering::SeqCst) + 1;
        let _transition = state.open_gate.blocking_lock();
        assert!(begin_book_removal(&state, "missing-book").is_err());
        assert!(require_current_open(&state, generation).is_ok());
    }

    #[test]
    fn scripts_escape_html_and_unicode_line_separators() {
        let script = script_json(&json!({"text":"</script>\u{2028}&"}));
        assert!(!script.contains('<'));
        assert!(!script.contains('\u{2028}'));
        assert!(script.contains("\\u003c"));
    }

    #[test]
    fn queued_stale_close_cannot_close_a_replacement_session() {
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            let gate = Arc::new(tokio::sync::Mutex::new(()));
            let current = Arc::new(Mutex::new(Some(session(
                "old",
                "old-doc",
                DocumentKind::Epub,
            ))));
            let native_closed = Arc::new(AtomicBool::new(false));
            let opening = gate.lock().await;
            let stale_close = {
                let gate = gate.clone();
                let current = current.clone();
                let native_closed = native_closed.clone();
                tokio::spawn(async move {
                    let (_transition, captured) =
                        action_context(&gate, &current, "old").await.unwrap();
                    if let Some(captured) = captured {
                        native_closed.store(true, Ordering::SeqCst);
                        take_matching_session(&mut current.lock().unwrap(), &captured.session_id);
                        ReaderActionOutcome::Applied
                    } else {
                        ReaderActionOutcome::Superseded
                    }
                })
            };
            tokio::task::yield_now().await;
            *current.lock().unwrap() = Some(session("replacement", "new-doc", DocumentKind::Epub));
            drop(opening);
            assert_eq!(stale_close.await.unwrap(), ReaderActionOutcome::Superseded);
            assert!(!native_closed.load(Ordering::SeqCst));
            assert_eq!(
                current.lock().unwrap().as_ref().unwrap().session_id,
                "replacement"
            );
        });
    }

    #[test]
    fn accepted_close_keeps_its_gate_until_native_work_finishes() {
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            let gate = Arc::new(tokio::sync::Mutex::new(()));
            let current = Arc::new(Mutex::new(Some(session(
                "old",
                "old-doc",
                DocumentKind::Epub,
            ))));
            let (transition, captured) = action_context(&gate, &current, "old").await.unwrap();
            let replacement_started = Arc::new(AtomicBool::new(false));
            let replacement = {
                let gate = gate.clone();
                let current = current.clone();
                let replacement_started = replacement_started.clone();
                tokio::spawn(async move {
                    let _transition = gate.lock().await;
                    replacement_started.store(true, Ordering::SeqCst);
                    *current.lock().unwrap() =
                        Some(session("replacement", "new-doc", DocumentKind::Pdf));
                })
            };
            tokio::task::yield_now().await;
            assert!(!replacement_started.load(Ordering::SeqCst));
            assert!(take_matching_session(
                &mut current.lock().unwrap(),
                &captured.unwrap().session_id
            )
            .is_some());
            drop(transition);
            replacement.await.unwrap();
            assert_eq!(
                current.lock().unwrap().as_ref().unwrap().session_id,
                "replacement"
            );
        });
    }

    #[test]
    fn captured_actions_keep_both_old_identity_guards_and_document_kind() {
        let captured = session("old-session", "old-document", DocumentKind::Epub);
        let replacement = session("new-session", "new-document", DocumentKind::Pdf);
        let payload = json!({"kind":"epub","spineIndex":4,"start":{"elementPath":[1],"offset":9}});
        let script = action_script(&captured, "goToPosition", Some(payload.clone()));
        assert!(script.contains("sessionId===\"old-session\""));
        assert!(script.contains("documentId===\"old-document\""));
        assert!(!script.contains(&replacement.document_id));
        assert!(script.contains("goToPosition({\"elementPath\":[1],\"offset\":9})"));
        let pdf_script = action_script(&replacement, "goToPosition", Some(payload));
        assert!(pdf_script.contains("\"spineIndex\":4"));
        let refresh = guard_script(&captured, "window.__kodiRefresh({});");
        assert!(refresh.contains("sessionId===\"old-session\""));
        assert!(refresh.contains("documentId===\"old-document\""));
    }

    #[test]
    fn stale_pdf_event_never_overwrites_or_updates_the_replacement() {
        let mut current = Some(session("new-session", "new-document", DocumentKind::Pdf));
        let message = json!({"spineIndex":3,"pageCount":5});
        assert!(event_session(
            &mut current,
            "old-session",
            "old-document",
            "pageChanged",
            &message
        )
        .is_err());
        assert_eq!(current.as_ref().unwrap().session_id, "new-session");
        assert_eq!(current.as_ref().unwrap().spine_index, 0);
        assert!(event_session(
            &mut current,
            "new-session",
            "old-document",
            "pageChanged",
            &message
        )
        .is_err());
        let updated = event_session(
            &mut current,
            "new-session",
            "new-document",
            "pageChanged",
            &message,
        )
        .unwrap();
        assert_eq!(updated.spine_index, 3);
        assert_eq!(current.as_ref().unwrap().spine_index, 3);
        assert_eq!(current.as_ref().unwrap().total_spines, 5);
        assert!(event_session(
            &mut current,
            "new-session",
            "new-document",
            "pageChanged",
            &json!({"spineIndex":5,"pageCount":5})
        )
        .is_err());
        assert_eq!(current.as_ref().unwrap().spine_index, 3);
    }

    #[test]
    fn trusted_action_outcomes_have_a_stable_wire_contract() {
        assert_eq!(
            serde_json::to_value(ReaderActionOutcome::Applied).unwrap(),
            json!("applied")
        );
        assert_eq!(
            serde_json::to_value(ReaderActionOutcome::Superseded).unwrap(),
            json!("superseded")
        );
    }

    #[test]
    fn open_targets_validate_pdf_pages_epub_chapters_and_conflicting_locator_indexes() {
        for kind in [DocumentKind::Epub, DocumentKind::Pdf] {
            assert!(validate_open_target(kind, 3, Some(2), None).is_ok());
            assert!(validate_open_target(kind, 3, Some(3), None).is_err());
            let mut locator = Locator {
                kind,
                spine_index: 1,
                ..Default::default()
            };
            locator
                .extra
                .insert("desktopChapterEnd".into(), json!(true));
            assert!(validate_open_target(kind, 3, Some(1), Some(&locator)).is_ok());
            assert!(validate_open_target(kind, 3, Some(0), Some(&locator)).is_err());
            locator.kind = if kind == DocumentKind::Epub {
                DocumentKind::Pdf
            } else {
                DocumentKind::Epub
            };
            assert!(validate_open_target(kind, 3, None, Some(&locator)).is_err());
        }
    }

    #[test]
    fn persisted_reader_positions_cannot_retarget_another_document_kind_or_epub_spine() {
        let active = session("active", "document", DocumentKind::Epub);
        assert!(event_locator(
            &active,
            "pageChanged",
            &json!({"locator":{"kind":"pdf","spineIndex":0,"start":{"elementPath":[],"offset":0}}})
        )
        .is_err());
        assert!(event_locator(
            &active,
            "pageChanged",
            &json!({"locator":{"kind":"epub","spineIndex":1,"start":{"elementPath":[],"offset":0}}})
        )
        .is_err());
        assert!(event_locator(&active, "pageChanged", &json!({"spineIndex":"0"})).is_err());
        let position = event_locator(
            &active,
            "pageChanged",
            &json!({"spineIndex":0,"position":{"elementPath":[1,2],"offset":4}}),
        )
        .unwrap();
        assert_eq!(position.kind, DocumentKind::Epub);
        assert_eq!(position.start.offset, 4);
    }

    #[test]
    fn pdf_marker_on_second_spread_page_is_valid_but_invalid_event_does_not_mutate_session() {
        let mut active = Some(session("active", "document", DocumentKind::Pdf));
        let marker = event_locator(
            active.as_ref().unwrap(),
            "readingMarkerPlaced",
            &json!({"spineIndex":1,"start":{"elementPath":[],"offset":0}}),
        )
        .unwrap();
        assert_eq!(marker.spine_index, 1);
        assert!(event_locator(
            active.as_ref().unwrap(),
            "readingMarkerPlaced",
            &json!({"spineIndex":10})
        )
        .is_err());
        let invalid = json!({"spineIndex":3,"pageCount":5,"locator":{"kind":"epub","spineIndex":3,"start":{"elementPath":[],"offset":0}}});
        assert!(event_session(&mut active, "active", "document", "pageChanged", &invalid).is_err());
        assert_eq!(active.as_ref().unwrap().spine_index, 0);
        assert_eq!(active.as_ref().unwrap().total_spines, 10);
    }
}
