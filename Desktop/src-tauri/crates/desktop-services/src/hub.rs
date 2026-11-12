//! Application-facing service facade. No local library lock is held during network I/O.
use crate::{
    ai::{AiService, ChatRequest},
    audio::{Ffmpeg, ModelManager, ModelSpec, RecordingResult},
    auth::{AuthService, OsCredentialStore},
    sync::{DriveAuthorization, DriveJournal, DriveTransport, PendingDriveAuthorization},
    CancellationToken, PublicConfig,
};
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

pub struct ServiceHub {
    pub config: PublicConfig,
    pub auth: Arc<AuthService>,
    pub ai: AiService,
    pub models: ModelManager,
    pub drive: tokio::sync::Mutex<DriveAuthorization>,
    root: PathBuf,
    pending_drive: tokio::sync::Mutex<Option<PendingDriveAuthorization>>,
    #[cfg(feature = "native-audio")]
    recording: Mutex<Option<crate::audio::Recording>>,
    #[cfg(feature = "native-audio")]
    playback: Mutex<crate::playback::PlaybackOwner<crate::audio::Playback>>,
    #[cfg(feature = "native-audio")]
    playback_start_gate: Mutex<()>,
    #[cfg(feature = "speech")]
    narrator: Mutex<Option<crate::audio::speech::PocketSpeech>>,
    #[cfg(feature = "speech")]
    transcriber: Mutex<Option<crate::audio::speech::WhisperSpeech>>,
}
impl ServiceHub {
    pub(crate) fn data_root(&self) -> &Path {
        &self.root
    }
    pub fn new(root: PathBuf) -> Result<Self> {
        Self::with_config(root, PublicConfig::from_env()?)
    }
    pub fn with_config(root: PathBuf, config: PublicConfig) -> Result<Self> {
        let store = Arc::new(OsCredentialStore::new("com.olly.KodiReader.desktop"));
        Ok(Self {
            auth: Arc::new(AuthService::new(config.clone(), store.clone())?),
            ai: AiService::new(config.clone())?,
            models: ModelManager::new(root.join("Models"))?,
            drive: tokio::sync::Mutex::new(DriveAuthorization::new(config.clone(), store)?),
            config,
            root,
            pending_drive: tokio::sync::Mutex::new(None),
            #[cfg(feature = "native-audio")]
            recording: Mutex::new(None),
            #[cfg(feature = "native-audio")]
            playback: Mutex::new(Default::default()),
            #[cfg(feature = "native-audio")]
            playback_start_gate: Mutex::new(()),
            #[cfg(feature = "speech")]
            narrator: Mutex::new(None),
            #[cfg(feature = "speech")]
            transcriber: Mutex::new(None),
        })
    }
    pub async fn status(&self) -> Value {
        let account = self
            .drive
            .lock()
            .await
            .connected_account()
            .map(str::to_owned);
        json!({"auth":self.auth.status(),"configured":self.config.supabase_url.is_some()&&self.config.supabase_publishable_key.is_some(),"paymentsEnabled":self.config.payments_enabled,"googleConfigured":self.config.google_client_id.is_some(),"googleAccount":account,"nativeAudio":cfg!(feature="native-audio"),"speechAvailable":cfg!(feature="speech")})
    }
    pub async fn send_code(&self, email: &str) -> Result<Value> {
        self.auth.send_code(email).await?;
        Ok(json!({"sent":true}))
    }
    pub async fn verify_code(&self, email: &str, code: &str) -> Result<Value> {
        Ok(serde_json::to_value(
            self.auth.verify_code(email, code).await?,
        )?)
    }
    pub async fn sign_out(&self) -> Result<Value> {
        self.auth.sign_out().await?;
        Ok(serde_json::to_value(self.auth.status())?)
    }
    pub async fn delete_account(&self) -> Result<Value> {
        self.auth.delete_account().await?;
        Ok(serde_json::to_value(self.auth.status())?)
    }
    pub async fn stream_chat(
        &self,
        request: ChatRequest,
        cancel: CancellationToken,
        on_delta: impl FnMut(String) + Send,
    ) -> Result<()> {
        let token = self.auth.access_token().await?;
        self.ai.stream(request, &token, cancel, on_delta).await
    }
    pub async fn drive_begin(&self) -> Result<String> {
        let pending = self.drive.lock().await.begin().await?;
        let url = pending.authorization_url.clone();
        *self.pending_drive.lock().await = Some(pending);
        Ok(url)
    }
    pub async fn drive_complete(&self, cancel: CancellationToken) -> Result<Value> {
        let pending = self
            .pending_drive
            .lock()
            .await
            .take()
            .context("Start Google Drive sign-in first")?;
        Ok(serde_json::to_value(
            self.drive.lock().await.complete(pending, cancel).await?,
        )?)
    }
    pub async fn drive_disconnect(&self) -> Result<()> {
        self.pending_drive.lock().await.take();
        self.drive.lock().await.disconnect()
    }
    pub async fn drive_transport(&self) -> Result<DriveTransport> {
        DriveTransport::new(self.drive.lock().await.access_token().await?)
    }
    pub fn ffmpeg(&self) -> Result<Ffmpeg> {
        let executable = std::env::var_os("KODI_FFMPEG_PATH")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::current_exe().ok().and_then(|p| {
                    p.parent().map(|p| {
                        p.join(if cfg!(windows) {
                            "kodi-ffmpeg.exe"
                        } else {
                            "kodi-ffmpeg"
                        })
                    })
                })
            })
            .context("Could not locate bundled audio codec")?;
        Ffmpeg::new(executable)
    }
    pub fn model_catalog(&self) -> Result<Vec<ModelSpec>> {
        Ok(serde_json::from_str(include_str!("model-catalog.json"))?)
    }
    pub async fn install_model(
        &self,
        id: &str,
        cancel: CancellationToken,
        progress: impl FnMut(u64, u64) + Send,
    ) -> Result<PathBuf> {
        let spec = self
            .model_catalog()?
            .into_iter()
            .find(|s| s.id == id)
            .context("Unknown speech model")?;
        self.models.install(&spec, cancel, progress).await
    }
    #[cfg(feature = "native-audio")]
    pub fn record_start(&self) -> Result<()> {
        let mut recording = self.recording.lock().unwrap();
        if recording.is_some() {
            bail!("A recording is already active");
        }
        self.audio_stop()?;
        *recording = Some(crate::audio::Recording::start()?);
        Ok(())
    }
    #[cfg(feature = "native-audio")]
    pub fn record_start_for(
        &self,
        book_id: &str,
        annotation_id: &str,
        audio_id: &str,
    ) -> Result<()> {
        let mut recording = self.recording.lock().unwrap();
        if recording.is_some() {
            bail!("A recording is already active");
        }
        self.audio_stop()?;
        let pending = crate::audio::PendingRecording::new(book_id, annotation_id, audio_id, 0)?;
        *recording = Some(crate::audio::Recording::start_persistent(
            self.root.join("Audio/.pending"),
            pending,
        )?);
        Ok(())
    }
    pub fn recover_recordings(&self) -> Result<crate::audio::RecordingRecoveryReport> {
        #[cfg(feature = "native-audio")]
        if self.recording.lock().unwrap().is_some() {
            bail!("Finish the active recording before recovering interrupted recordings");
        }
        let directory = self.root.join("Audio/.pending");
        if !directory.exists()
            || !std::fs::read_dir(directory)?
                .filter_map(std::result::Result::ok)
                .any(|entry| entry.path().extension().and_then(|s| s.to_str()) == Some("json"))
        {
            return Ok(crate::audio::RecordingRecoveryReport::default());
        }
        crate::audio::recover_pending_recordings(&self.root, &self.ffmpeg()?)
    }
    /// Call only after the core library durably contains this audio attachment.
    pub fn confirm_recording(&self, audio_id: &str) -> Result<()> {
        crate::audio::confirm_pending_recording(&self.root, audio_id)
    }
    #[cfg(feature = "native-audio")]
    pub fn record_pause(&self, paused: bool) -> Result<()> {
        self.recording
            .lock()
            .unwrap()
            .as_ref()
            .context("No recording is active")?
            .pause(paused);
        Ok(())
    }
    #[cfg(feature = "native-audio")]
    pub fn record_finish(&self, relative_path: &str) -> Result<RecordingResult> {
        let destination = self.local_path(relative_path)?;
        let recording = self
            .recording
            .lock()
            .unwrap()
            .take()
            .context("No recording is active")?;
        recording.finish(&self.ffmpeg()?, &destination)
    }
    #[cfg(feature = "native-audio")]
    pub fn audio_play(&self, relative_path: &str, rate: f32) -> Result<Value> {
        let request = self.playback_request();
        self.audio_play_requested(relative_path, rate, &request)
    }
    /// Capture before dispatching a blocking worker so Stop also invalidates
    /// requests that have not started decoding yet.
    #[cfg(feature = "native-audio")]
    pub fn playback_request(&self) -> crate::PlaybackRequest {
        let (request, previous) = self.playback.lock().unwrap().request();
        drop(previous);
        request
    }
    #[cfg(feature = "native-audio")]
    pub fn audio_play_requested(
        &self,
        relative_path: &str,
        rate: f32,
        request: &crate::PlaybackRequest,
    ) -> Result<Value> {
        self.audio_play_requested_from(
            relative_path,
            rate,
            request,
            0.,
            Arc::new(std::sync::atomic::AtomicBool::new(false)),
        )
    }
    /// Apply a narration resume position and pause state before native output
    /// begins, while retaining the same atomic recording/playback ownership.
    #[cfg(feature = "native-audio")]
    pub fn audio_play_requested_from(
        &self,
        relative_path: &str,
        rate: f32,
        request: &crate::PlaybackRequest,
        offset: f64,
        paused: Arc<std::sync::atomic::AtomicBool>,
    ) -> Result<Value> {
        let _start = self.playback_start_gate.lock().unwrap();
        if !self.playback.lock().unwrap().is_current(request) {
            bail!("Playback request was cancelled or superseded");
        }
        if self.recording.lock().unwrap().is_some() {
            bail!("Finish recording before playing audio");
        }
        if let Some(previous) = self.playback.lock().unwrap().finish(request) {
            previous.stop()?;
        }
        let source = self.local_path(relative_path)?;
        let playback = crate::audio::Playback::prepare_with_pause(
            self.ffmpeg()?,
            source,
            rate,
            request.cancellation_token(),
            paused,
        )?;
        let duration = playback.duration;
        // Same lock order as recording start: recording, then playback.
        let recording = self.recording.lock().unwrap();
        if recording.is_some() {
            bail!("Finish recording before playing audio");
        }
        let mut owner = self.playback.lock().unwrap();
        if !owner.is_current(request) {
            bail!("Playback request was cancelled or superseded");
        }
        playback.seek(offset.clamp(0., duration));
        playback.begin()?;
        match owner.install(request, playback) {
            Ok(previous) => drop(previous),
            Err(prepared) => {
                drop(prepared);
                bail!("Playback request was cancelled or superseded");
            }
        }
        Ok(json!({"duration":duration}))
    }
    /// Finish a narration passage while retaining the ownership of the run.
    #[cfg(feature = "native-audio")]
    pub fn audio_finish_requested(&self, request: &crate::PlaybackRequest) -> Result<()> {
        let playback = self.playback.lock().unwrap().finish(request);
        if let Some(playback) = playback {
            playback.stop()?;
        }
        Ok(())
    }
    #[cfg(feature = "native-audio")]
    pub fn audio_pause(&self, paused: bool) -> Result<()> {
        self.playback
            .lock()
            .unwrap()
            .playback
            .as_ref()
            .context("No audio is playing")?
            .pause(paused);
        Ok(())
    }
    #[cfg(feature = "native-audio")]
    pub fn audio_seek(&self, seconds: f64) -> Result<()> {
        self.playback
            .lock()
            .unwrap()
            .playback
            .as_ref()
            .context("No audio is playing")?
            .seek(seconds);
        Ok(())
    }
    #[cfg(feature = "native-audio")]
    pub fn audio_position(&self) -> Value {
        self.playback
            .lock()
            .unwrap()
            .playback
            .as_ref()
            .map(|p| json!({"position":p.position(),"duration":p.duration}))
            .unwrap_or(json!({"position":0,"duration":0}))
    }
    #[cfg(feature = "native-audio")]
    pub fn audio_stop(&self) -> Result<()> {
        let playback = self.playback.lock().unwrap().cancel();
        if let Some(p) = playback {
            p.stop()?;
        }
        Ok(())
    }
    pub fn local_path(&self, relative: &str) -> Result<PathBuf> {
        let path = Path::new(relative);
        if path.is_absolute()
            || path
                .components()
                .any(|c| !matches!(c, std::path::Component::Normal(_)))
        {
            bail!("Audio paths must remain inside Kodi's library");
        }
        let result = self.root.join(path);
        let mut ancestor = result.as_path();
        while !ancestor.exists() {
            ancestor = ancestor.parent().context("Invalid audio path")?;
        }
        if !ancestor
            .canonicalize()?
            .starts_with(self.root.canonicalize()?)
        {
            bail!("Audio path escapes the library");
        }
        Ok(result)
    }
    #[cfg(feature = "speech")]
    pub fn transcribe(&self, relative_path: &str, cancel: CancellationToken) -> Result<String> {
        let mut engine = self.transcriber.lock().unwrap();
        if engine.is_none() {
            let spec = self
                .model_catalog()?
                .into_iter()
                .find(|s| s.id == "whisper-base")
                .context("Whisper model manifest is missing")?;
            if !self.models.verified(&spec)? {
                bail!("Download the transcription model in Settings before transcribing");
            }
            *engine = Some(crate::audio::speech::WhisperSpeech::load(
                &self.models.model_directory("whisper-base")?,
                None,
            )?);
        }
        let wav = tempfile::Builder::new().suffix(".wav").tempfile()?;
        self.ffmpeg()?
            .transcribe_wave(&self.local_path(relative_path)?, wav.path())?;
        engine.as_ref().unwrap().transcribe(wav.path(), cancel)
    }
    #[cfg(feature = "speech")]
    pub fn narrate(
        &self,
        text: &str,
        voice: &str,
        speed: f32,
        cancel: CancellationToken,
    ) -> Result<String> {
        if !["anna", "azelma", "charles", "george"].contains(&voice) {
            bail!("Unknown narration voice");
        }
        let mut engine = self.narrator.lock().unwrap();
        if engine.is_none() {
            let catalog = self.model_catalog()?;
            for id in ["pocket-tts", "narration-voices"] {
                let spec = catalog
                    .iter()
                    .find(|s| s.id == id)
                    .context("Narration model manifest is missing")?;
                if !self.models.verified(spec)? {
                    bail!("Download the narration model and voices in Settings before listening");
                }
            }
            *engine = Some(crate::audio::speech::PocketSpeech::load(
                &self.models.model_directory("pocket-tts")?,
            )?);
        }
        let voice = self
            .models
            .model_directory("narration-voices")?
            .join(format!("{voice}.wav"));
        let relative = format!("Narration/{}.wav", uuid::Uuid::new_v4());
        let destination = self.root.join(&relative);
        std::fs::create_dir_all(destination.parent().unwrap())?;
        engine
            .as_ref()
            .unwrap()
            .synthesize(text, &voice, speed, &destination, cancel)?;
        Ok(relative)
    }
    #[cfg(feature = "speech")]
    pub fn narration_duration(&self, relative: &str) -> Result<f64> {
        let path = self.local_path(relative)?;
        let wave = sherpa_onnx::Wave::read(path.to_str().context("Invalid narration path")?)
            .context("Could not read narrated audio")?;
        if wave.sample_rate() <= 0 {
            bail!("Narrated audio has an invalid sample rate");
        }
        Ok(wave.samples().len() as f64 / wave.sample_rate() as f64)
    }
    pub fn remove_model(&self, id: &str) -> Result<()> {
        #[cfg(feature = "speech")]
        {
            if ["pocket-tts", "narration-voices"].contains(&id) {
                self.narrator.lock().unwrap().take();
            }
            if id == "whisper-base" {
                self.transcriber.lock().unwrap().take();
            }
        }
        self.models.remove(id)
    }
    /// Return a received batch to the shell; commit only after applying its entities durably.
    pub async fn sync_fetch(
        &self,
        device_id: &str,
        ai_enabled: bool,
    ) -> Result<crate::sync::FetchBatch> {
        let transport = self.drive_transport().await?;
        let account = transport.account().await?;
        let root = self.root.join("Sync");
        let journal = DriveJournal::load(&root, &account.id, device_id)?;
        transport
            .fetch(&journal, ai_enabled, &root.join("Chunks"))
            .await
    }
}
