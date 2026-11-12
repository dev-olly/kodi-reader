//! Native capture/playback and local model execution; no browser codec dependency.
use crate::{atomic_write, checked, require_https, CancellationToken};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelFile {
    pub name: String,
    pub url: String,
    pub sha256: String,
    pub size: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelSpec {
    pub id: String,
    pub license: String,
    #[serde(default)]
    pub license_url: String,
    pub files: Vec<ModelFile>,
}
pub struct ModelManager {
    root: PathBuf,
    install_lock: tokio::sync::Mutex<()>,
}
impl ModelManager {
    pub fn new(root: PathBuf) -> Result<Self> {
        Ok(Self {
            root,
            install_lock: tokio::sync::Mutex::new(()),
        })
    }
    pub fn model_directory(&self, id: &str) -> Result<PathBuf> {
        safe_component(id)?;
        Ok(self.root.join(id))
    }
    pub fn verified(&self, spec: &ModelSpec) -> Result<bool> {
        let dir = self.model_directory(&spec.id)?;
        for file in &spec.files {
            safe_component(&file.name)?;
            if !verify_file(&dir.join(&file.name), file)? {
                return Ok(false);
            }
        }
        Ok(!spec.files.is_empty())
    }
    /// Downloads are hash-verified in staging. Interrupted/invalid files never replace models.
    pub async fn install(
        &self,
        spec: &ModelSpec,
        cancel: CancellationToken,
        mut progress: impl FnMut(u64, u64) + Send,
    ) -> Result<PathBuf> {
        let _guard = self.install_lock.lock().await;
        if spec.files.is_empty() || spec.license.trim().is_empty() {
            bail!("This speech model has no pinned files/license manifest");
        }
        let directory = self.model_directory(&spec.id)?;
        std::fs::create_dir_all(&directory)?;
        let total = spec.files.iter().map(|f| f.size).sum();
        let mut done = 0;
        for file in &spec.files {
            safe_component(&file.name)?;
            validate_hash(&file.sha256)?;
            let url = require_https(&file.url)?;
            if ![
                "github.com",
                "raw.githubusercontent.com",
                "creativecommons.org",
                "objects.githubusercontent.com",
                "release-assets.githubusercontent.com",
                "huggingface.co",
                "cdn-lfs.huggingface.co",
                "cas-bridge.xethub.hf.co",
            ]
            .contains(&url.host_str().unwrap_or_default())
            {
                bail!("Speech model host is not trusted");
            }
            let target = directory.join(&file.name);
            if verify_file(&target, file)? {
                done += file.size;
                progress(done, total);
                continue;
            }
            // Downloads may redirect to signed storage URLs; no Authorization header is ever sent.
            let client = reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::custom(|attempt| {
                    if attempt.previous().len() > 5 || attempt.url().scheme() != "https" {
                        attempt.stop()
                    } else {
                        attempt.follow()
                    }
                }))
                .build()?;
            let _ = url;
            download_verified(&client, file, &target, cancel.clone(), |size| {
                progress(done + size, total)
            })
            .await?;
            done += file.size;
        }
        atomic_write(
            &directory.join("model-manifest.json"),
            &serde_json::to_vec_pretty(spec)?,
        )?;
        Ok(directory)
    }
    pub fn remove(&self, id: &str) -> Result<()> {
        let _guard = self.install_lock.try_lock().map_err(|_| {
            anyhow::anyhow!("Wait for the active model download to finish before removing models")
        })?;
        let path = self.model_directory(id)?;
        if path.exists() {
            std::fs::remove_dir_all(path)?;
        }
        Ok(())
    }
}
fn partial_path(target: &Path, spec: &ModelFile) -> PathBuf {
    target.with_file_name(format!(".{}.{}.partial", spec.name, spec.sha256))
}
fn range_offset(value: &str, expected: u64) -> Result<u64> {
    let (range, total) = value
        .strip_prefix("bytes ")
        .and_then(|s| s.split_once('/'))
        .context("Invalid model download range")?;
    let (start, end) = range
        .split_once('-')
        .context("Invalid model download range")?;
    let start: u64 = start.parse()?;
    let end: u64 = end.parse()?;
    if total.parse::<u64>()? != expected || end < start || end >= expected {
        bail!("Invalid model download range");
    }
    Ok(start)
}
async fn download_verified(
    client: &reqwest::Client,
    spec: &ModelFile,
    target: &Path,
    cancel: CancellationToken,
    mut progress: impl FnMut(u64) + Send,
) -> Result<()> {
    use tokio::io::{AsyncSeekExt, AsyncWriteExt};
    let partial = partial_path(target, spec);
    let mut offset = std::fs::metadata(&partial).map(|m| m.len()).unwrap_or(0);
    if offset > spec.size {
        std::fs::remove_file(&partial)?;
        offset = 0;
    }
    if offset == spec.size && verify_file(&partial, spec)? {
        install_verified_partial(&partial, target)?;
        progress(spec.size);
        return Ok(());
    }
    if offset == spec.size {
        std::fs::remove_file(&partial)?;
        offset = 0;
    }
    let mut request = client.get(&spec.url);
    if offset > 0 {
        request = request.header("Range", format!("bytes={offset}-"));
    }
    let response = tokio::select! {_=cancel.cancelled()=>bail!("Model download cancelled"),response=request.send()=>response?};
    let mut response = checked(response).await?;
    if response.status() == reqwest::StatusCode::PARTIAL_CONTENT {
        let actual = range_offset(
            response
                .headers()
                .get("Content-Range")
                .context("Model server omitted its byte range")?
                .to_str()?,
            spec.size,
        )?;
        if actual != offset {
            bail!("Model server returned an incorrect resume offset");
        }
    } else if response.status() == reqwest::StatusCode::OK {
        offset = 0;
    } else {
        bail!("Model server returned an unsupported response");
    }
    let mut output = tokio::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(offset == 0)
        .open(&partial)
        .await?;
    output.seek(std::io::SeekFrom::Start(offset)).await?;
    let mut size = offset;
    progress(size);
    loop {
        let chunk = tokio::select! {_=cancel.cancelled()=>{output.flush().await?;bail!("Model download cancelled");},r=response.chunk()=>r?};
        let Some(bytes) = chunk else { break };
        size += bytes.len() as u64;
        if size > spec.size {
            drop(output);
            let _ = std::fs::remove_file(&partial);
            bail!("Speech model exceeds its pinned size");
        }
        output.write_all(&bytes).await?;
        output.flush().await?;
        progress(size);
    }
    output.sync_all().await?;
    drop(output);
    if size != spec.size {
        bail!("Speech model download was interrupted. Retry to resume it");
    }
    if !verify_file(&partial, spec)? {
        std::fs::remove_file(&partial)?;
        bail!("Speech model failed integrity verification");
    }
    install_verified_partial(&partial, target)
}
fn install_verified_partial(partial: &Path, target: &Path) -> Result<()> {
    // NamedTempFile::persist replaces atomically on Windows as well as Unix.
    let mut staged =
        tempfile::NamedTempFile::new_in(target.parent().context("Invalid model directory")?)?;
    std::io::copy(&mut std::fs::File::open(partial)?, &mut staged)?;
    staged.as_file().sync_all()?;
    staged.persist(target).map_err(|e| e.error)?;
    std::fs::remove_file(partial)?;
    Ok(())
}
fn safe_component(value: &str) -> Result<()> {
    if value.is_empty()
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
        || value == "."
        || value == ".."
    {
        bail!("Invalid model file name");
    }
    Ok(())
}
fn validate_hash(hash: &str) -> Result<()> {
    if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("Missing pinned model checksum");
    }
    Ok(())
}
fn verify_file(path: &Path, spec: &ModelFile) -> Result<bool> {
    use std::io::Read;
    if !path.exists() {
        return Ok(false);
    }
    if std::fs::metadata(path)?.len() != spec.size {
        return Ok(false);
    }
    let mut f = std::fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut bytes = [0; 64 * 1024];
    loop {
        let n = f.read(&mut bytes)?;
        if n == 0 {
            break;
        }
        hash.update(&bytes[..n]);
    }
    Ok(format!("{:x}", hash.finalize()) == spec.sha256)
}

#[derive(Clone)]
pub struct Ffmpeg {
    pub executable: PathBuf,
}
impl Ffmpeg {
    pub fn new(executable: PathBuf) -> Result<Self> {
        if !executable.is_file() {
            bail!("The bundled FFmpeg audio codec is missing. Reinstall Kodi Reader or configure KODI_FFMPEG_PATH");
        }
        Ok(Self { executable })
    }
    fn run(&self, args: &[std::ffi::OsString]) -> Result<()> {
        let result = std::process::Command::new(&self.executable)
            .args(["-nostdin", "-hide_banner", "-loglevel", "error"])
            .args(args)
            .output()
            .context("The bundled FFmpeg codec could not start")?;
        if !result.status.success() {
            bail!("Audio conversion failed; the original recording was preserved");
        }
        Ok(())
    }
    fn run_cancellable(
        &self,
        args: &[std::ffi::OsString],
        cancel: &CancellationToken,
    ) -> Result<()> {
        if cancel.is_cancelled() {
            bail!("Audio preparation cancelled");
        }
        let mut child = std::process::Command::new(&self.executable)
            .args(["-nostdin", "-hide_banner", "-loglevel", "error"])
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .context("The bundled FFmpeg codec could not start")?;
        loop {
            if cancel.is_cancelled() {
                let _ = child.kill();
                let _ = child.wait();
                bail!("Audio preparation cancelled");
            }
            match child.try_wait() {
                Ok(Some(status)) => {
                    if !status.success() {
                        bail!("Audio conversion failed; the original recording was preserved");
                    }
                    return Ok(());
                }
                Ok(None) => std::thread::sleep(std::time::Duration::from_millis(20)),
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(error.into());
                }
            }
        }
    }
    pub fn encode_m4a(&self, pcm: &Path, sample_rate: u32, destination: &Path) -> Result<()> {
        let parent = destination
            .parent()
            .context("Invalid recording destination")?;
        std::fs::create_dir_all(parent)?;
        let staging = tempfile::Builder::new()
            .suffix(".m4a")
            .tempfile_in(parent)?;
        let arg = |s: &str| std::ffi::OsString::from(s);
        self.run(&[
            arg("-y"),
            arg("-f"),
            arg("f32le"),
            arg("-ar"),
            arg(&sample_rate.to_string()),
            arg("-ac"),
            arg("1"),
            arg("-i"),
            pcm.as_os_str().into(),
            arg("-c:a"),
            arg("aac"),
            arg("-b:a"),
            arg("64k"),
            arg("-ar"),
            arg("44100"),
            arg("-movflags"),
            arg("+faststart"),
            staging.path().as_os_str().into(),
        ])?;
        if std::fs::metadata(staging.path())?.len() == 0 {
            bail!("Audio encoder returned an empty file; the original recording was preserved");
        }
        staging.persist(destination).map_err(|e| e.error)?;
        Ok(())
    }
    pub fn decode_pcm(
        &self,
        source: &Path,
        destination: &Path,
        sample_rate: u32,
        rate: f32,
    ) -> Result<()> {
        self.run(&Self::decode_arguments(
            source,
            destination,
            sample_rate,
            rate,
        )?)
    }
    pub fn decode_pcm_cancellable(
        &self,
        source: &Path,
        destination: &Path,
        sample_rate: u32,
        rate: f32,
        cancel: &CancellationToken,
    ) -> Result<()> {
        self.run_cancellable(
            &Self::decode_arguments(source, destination, sample_rate, rate)?,
            cancel,
        )
    }
    fn decode_arguments(
        source: &Path,
        destination: &Path,
        sample_rate: u32,
        rate: f32,
    ) -> Result<Vec<std::ffi::OsString>> {
        if !source.is_file() {
            bail!("This recording is unavailable. Download it before playing");
        }
        if !(0.5..=2.0).contains(&rate) {
            bail!("Playback speed must be between 0.5 and 2");
        }
        let a = |s: &str| std::ffi::OsString::from(s);
        Ok(vec![
            a("-y"),
            a("-i"),
            source.as_os_str().into(),
            a("-vn"),
            a("-af"),
            a(&format!("atempo={rate}")),
            a("-ar"),
            a(&sample_rate.to_string()),
            a("-ac"),
            a("1"),
            a("-f"),
            a("f32le"),
            destination.as_os_str().into(),
        ])
    }
    pub fn transcribe_wave(&self, source: &Path, destination: &Path) -> Result<()> {
        let a = |s: &str| std::ffi::OsString::from(s);
        self.run(&[
            a("-y"),
            a("-i"),
            source.as_os_str().into(),
            a("-vn"),
            a("-ac"),
            a("1"),
            a("-ar"),
            a("16000"),
            a("-c:a"),
            a("pcm_s16le"),
            destination.as_os_str().into(),
        ])
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct RecordingResult {
    pub path: PathBuf,
    pub duration: f64,
    pub waveform: Vec<f32>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingRecording {
    pub version: u32,
    pub book_id: String,
    pub annotation_id: String,
    pub audio_id: String,
    pub sample_rate: u32,
    pub created_at: f64,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoveredRecording {
    pub book_id: String,
    pub annotation_id: String,
    pub audio_id: String,
    pub created_at: f64,
    pub recording: RecordingResult,
}
#[derive(Default, Debug, Serialize)]
pub struct RecordingRecoveryReport {
    pub recordings: Vec<RecoveredRecording>,
    pub errors: Vec<String>,
}
impl PendingRecording {
    pub fn new(
        book_id: &str,
        annotation_id: &str,
        audio_id: &str,
        sample_rate: u32,
    ) -> Result<Self> {
        uuid::Uuid::parse_str(annotation_id)?;
        uuid::Uuid::parse_str(audio_id)?;
        if book_id.is_empty() {
            bail!("A recording needs a source book");
        }
        Ok(Self {
            version: 1,
            book_id: book_id.into(),
            annotation_id: annotation_id.into(),
            audio_id: audio_id.into(),
            sample_rate,
            created_at: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_secs_f64(),
        })
    }
    pub fn write_journal(&self, pending_directory: &Path) -> Result<()> {
        std::fs::create_dir_all(pending_directory)?;
        atomic_write(
            &pending_directory.join(format!("{}.json", self.audio_id)),
            &serde_json::to_vec(self)?,
        )
    }
    pub fn pcm_path(&self, pending_directory: &Path) -> PathBuf {
        pending_directory.join(format!("{}.f32le", self.audio_id))
    }
    pub fn relative_destination(&self) -> String {
        format!(
            "Audio/{}/{}/{}.m4a",
            crate::sync::sha256(self.book_id.as_bytes()),
            self.annotation_id,
            self.audio_id
        )
    }
}
/// Computes durations/waveforms from durable bytes, never from stale UI timers.
fn pcm_summary(path: &Path, sample_rate: u32) -> Result<(f64, Vec<f32>)> {
    use std::io::Read;
    if !(8000..=192000).contains(&sample_rate) {
        bail!("The pending recording has an invalid sample rate");
    }
    let size = std::fs::metadata(path)?.len();
    if size % 4 != 0 {
        bail!("The pending PCM recording is incomplete; its original bytes were preserved");
    }
    let mut file = std::io::BufReader::new(std::fs::File::open(path)?);
    let mut bytes = [0u8; 4];
    let mut peak = 0f32;
    let mut count = 0;
    let mut waveform = Vec::new();
    for _ in 0..size / 4 {
        file.read_exact(&mut bytes)?;
        let value = f32::from_le_bytes(bytes);
        if !value.is_finite() {
            bail!("The pending PCM recording contains invalid samples; its original bytes were preserved");
        }
        peak = peak.max(value.abs());
        count += 1;
        if count >= sample_rate / 10 {
            waveform.push(peak);
            count = 0;
            peak = 0.;
        }
    }
    if count > 0 {
        waveform.push(peak);
    }
    Ok((size as f64 / 4. / sample_rate as f64, waveform))
}
pub fn confirm_pending_recording(root: &Path, audio_id: &str) -> Result<()> {
    uuid::Uuid::parse_str(audio_id)?;
    let directory = root.join("Audio/.pending");
    for extension in ["json", "f32le"] {
        let file = directory.join(format!("{audio_id}.{extension}"));
        if file.exists() {
            std::fs::remove_file(file)?;
        }
    }
    Ok(())
}
pub fn recover_pending_recordings(root: &Path, ffmpeg: &Ffmpeg) -> Result<RecordingRecoveryReport> {
    let directory = root.join("Audio/.pending");
    let mut report = RecordingRecoveryReport::default();
    if !directory.exists() {
        return Ok(report);
    }
    for entry in std::fs::read_dir(&directory)? {
        let entry = entry?;
        if entry.path().extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let recovery = (|| -> Result<Option<RecoveredRecording>> {
            let pending: PendingRecording = serde_json::from_slice(&std::fs::read(entry.path())?)?;
            uuid::Uuid::parse_str(&pending.audio_id)?;
            uuid::Uuid::parse_str(&pending.annotation_id)?;
            if pending.version != 1
                || pending.book_id.is_empty()
                || entry.file_name() != std::ffi::OsStr::new(&format!("{}.json", pending.audio_id))
            {
                bail!("The pending recording journal is invalid");
            }
            let pcm = pending.pcm_path(&directory);
            let (duration, waveform) = pcm_summary(&pcm, pending.sample_rate)?;
            if duration == 0. {
                confirm_pending_recording(root, &pending.audio_id)?;
                return Ok(None);
            }
            let destination = root.join(pending.relative_destination());
            ffmpeg.encode_m4a(&pcm, pending.sample_rate, &destination)?;
            Ok(Some(RecoveredRecording {
                book_id: pending.book_id,
                annotation_id: pending.annotation_id,
                audio_id: pending.audio_id,
                created_at: pending.created_at,
                recording: RecordingResult {
                    path: destination,
                    duration,
                    waveform,
                },
            }))
        })();
        match recovery {
            Ok(Some(recording)) => report.recordings.push(recording),
            Ok(None) => {}
            Err(error) => report
                .errors
                .push(format!("{}: {error}", entry.file_name().to_string_lossy())),
        }
    }
    Ok(report)
}
#[cfg(feature = "native-audio")]
mod native {
    use super::*;
    use cpal::{
        traits::{DeviceTrait, HostTrait, StreamTrait},
        Sample,
    };
    use std::io::{Read, Seek, SeekFrom, Write};
    struct CaptureData {
        file: std::fs::File,
        path: PathBuf,
        temporary: Option<tempfile::NamedTempFile>,
        samples: u64,
        peak: f32,
        bucket: u32,
        waveform: Vec<f32>,
        failure: Option<String>,
    }
    struct CapturedAudio {
        path: PathBuf,
        _temporary: Option<tempfile::NamedTempFile>,
        sample_rate: u32,
        samples: u64,
        waveform: Vec<f32>,
    }
    pub struct Recording {
        stop: Option<std::sync::mpsc::Sender<()>>,
        worker: Option<std::thread::JoinHandle<Result<CapturedAudio>>>,
        paused: Arc<AtomicBool>,
    }
    impl Recording {
        pub fn start() -> Result<Self> {
            Self::start_internal(None)
        }
        pub fn start_persistent(directory: PathBuf, pending: PendingRecording) -> Result<Self> {
            Self::start_internal(Some((directory, pending)))
        }
        fn start_internal(persistent: Option<(PathBuf, PendingRecording)>) -> Result<Self> {
            let paused = Arc::new(AtomicBool::new(false));
            let pause_capture = paused.clone();
            let (stop, rx) = std::sync::mpsc::channel();
            let (ready, ready_rx) = std::sync::mpsc::sync_channel(1);
            let worker = std::thread::spawn(move || {
                let setup = (|| -> Result<_> {
                    let host = cpal::default_host();
                    let device = host.default_input_device().context(
                        "No microphone is available. Check system microphone privacy settings",
                    )?;
                    let config = device.default_input_config()?;
                    let sample_rate = config.sample_rate().0;
                    let channels = config.channels() as usize;
                    let (file, path, temporary) = if let Some((directory, mut pending)) = persistent
                    {
                        std::fs::create_dir_all(&directory)?;
                        pending.sample_rate = sample_rate;
                        let path = pending.pcm_path(&directory);
                        let file = std::fs::OpenOptions::new()
                            .create_new(true)
                            .write(true)
                            .open(&path)?;
                        pending.write_journal(&directory)?;
                        (file, path, None)
                    } else {
                        let file = tempfile::NamedTempFile::new()?;
                        (file.reopen()?, file.path().to_path_buf(), Some(file))
                    };
                    let shared = Arc::new(Mutex::new(CaptureData {
                        file,
                        path,
                        temporary,
                        samples: 0,
                        peak: 0.,
                        bucket: 0,
                        waveform: vec![],
                        failure: None,
                    }));
                    fn receive<T: cpal::Sample + cpal::SizedSample>(
                        input: &[T],
                        channels: usize,
                        rate: u32,
                        shared: &Arc<Mutex<CaptureData>>,
                        paused: &AtomicBool,
                    ) where
                        f32: cpal::FromSample<T>,
                    {
                        if paused.load(Ordering::Relaxed) {
                            return;
                        }
                        let mut data = shared.lock().unwrap();
                        let mut bytes = Vec::with_capacity(input.len() / channels * 4);
                        for frame in input.chunks(channels) {
                            let sample = frame.iter().map(|v| f32::from_sample(*v)).sum::<f32>()
                                / channels as f32;
                            bytes.extend_from_slice(&sample.to_le_bytes());
                            data.samples += 1;
                            data.peak = data.peak.max(sample.abs());
                            data.bucket += 1;
                            if data.bucket >= rate / 10 {
                                let peak = data.peak;
                                data.waveform.push(peak);
                                data.bucket = 0;
                                data.peak = 0.;
                            }
                        }
                        if let Err(error) = data.file.write_all(&bytes) {
                            data.failure = Some(error.to_string());
                        }
                    }
                    let s = shared.clone();
                    let p = pause_capture.clone();
                    let error_shared = shared.clone();
                    let error = move |_: cpal::StreamError| {
                        error_shared.lock().unwrap().failure =
                            Some("Microphone connection was interrupted".into());
                    };
                    let stream = match config.sample_format() {
                        cpal::SampleFormat::F32 => device.build_input_stream(
                            &config.into(),
                            move |input: &[f32], _| receive(input, channels, sample_rate, &s, &p),
                            error,
                            None,
                        )?,
                        cpal::SampleFormat::I16 => device.build_input_stream(
                            &config.into(),
                            move |input: &[i16], _| receive(input, channels, sample_rate, &s, &p),
                            error,
                            None,
                        )?,
                        cpal::SampleFormat::U16 => device.build_input_stream(
                            &config.into(),
                            move |input: &[u16], _| receive(input, channels, sample_rate, &s, &p),
                            error,
                            None,
                        )?,
                        _ => bail!("The microphone uses an unsupported sample format"),
                    };
                    stream.play()?;
                    Ok((stream, shared, sample_rate))
                })();
                let (stream, shared, rate) = match setup {
                    Ok(v) => {
                        let _ = ready.send(Ok(()));
                        v
                    }
                    Err(e) => {
                        let _ = ready.send(Err(e.to_string()));
                        return Err(e);
                    }
                };
                loop {
                    match rx.recv_timeout(Duration::from_secs(1)) {
                        Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                            let mut data = shared.lock().unwrap();
                            if let Err(error) = data.file.sync_data() {
                                data.failure = Some(error.to_string());
                                break;
                            }
                        }
                    }
                }
                drop(stream);
                let data = Arc::try_unwrap(shared)
                    .map_err(|_| anyhow::anyhow!("Microphone did not stop"))?
                    .into_inner()
                    .unwrap();
                data.file.sync_all()?;
                if let Some(error) = data.failure {
                    bail!(error);
                }
                Ok(CapturedAudio {
                    path: data.path,
                    _temporary: data.temporary,
                    sample_rate: rate,
                    samples: data.samples,
                    waveform: data.waveform,
                })
            });
            ready_rx
                .recv_timeout(Duration::from_secs(15))
                .context("Microphone initialization timed out")?
                .map_err(anyhow::Error::msg)?;
            Ok(Self {
                stop: Some(stop),
                worker: Some(worker),
                paused,
            })
        }
        pub fn pause(&self, paused: bool) {
            self.paused.store(paused, Ordering::Relaxed);
        }
        pub fn finish(mut self, ffmpeg: &Ffmpeg, destination: &Path) -> Result<RecordingResult> {
            self.stop.take();
            let captured = self
                .worker
                .take()
                .context("Recording has already finished")?
                .join()
                .map_err(|_| anyhow::anyhow!("Recording worker stopped unexpectedly"))??;
            if captured.samples == 0 {
                bail!("The recording is empty");
            }
            ffmpeg.encode_m4a(&captured.path, captured.sample_rate, destination)?;
            Ok(RecordingResult {
                path: destination.into(),
                duration: captured.samples as f64 / captured.sample_rate as f64,
                waveform: captured.waveform,
            })
        }
    }
    impl Drop for Recording {
        fn drop(&mut self) {
            self.stop.take();
            if let Some(worker) = self.worker.take() {
                let _ = worker.join();
            }
        }
    }
    type PlaybackStartAck = std::sync::mpsc::SyncSender<std::result::Result<(), String>>;
    pub struct Playback {
        stop: Option<std::sync::mpsc::Sender<PlaybackStartAck>>,
        worker: Option<std::thread::JoinHandle<Result<()>>>,
        paused: Arc<AtomicBool>,
        position: Arc<AtomicU64>,
        seek: Arc<AtomicU64>,
        sample_rate: u32,
        rate: f32,
        pub duration: f64,
    }
    impl Playback {
        pub fn start(ffmpeg: Ffmpeg, source: PathBuf, rate: f32) -> Result<Self> {
            let playback = Self::prepare(ffmpeg, source, rate, CancellationToken::new())?;
            playback.begin()?;
            Ok(playback)
        }
        /// Decode and construct the native stream without playing any samples.
        pub fn prepare(
            ffmpeg: Ffmpeg,
            source: PathBuf,
            rate: f32,
            cancel: CancellationToken,
        ) -> Result<Self> {
            Self::prepare_with_pause(
                ffmpeg,
                source,
                rate,
                cancel,
                Arc::new(AtomicBool::new(false)),
            )
        }
        /// The pause signal is shared before decoding starts, so pausing while
        /// preparation is in progress also suppresses the first output frame.
        pub fn prepare_with_pause(
            ffmpeg: Ffmpeg,
            source: PathBuf,
            rate: f32,
            cancel: CancellationToken,
            paused: Arc<AtomicBool>,
        ) -> Result<Self> {
            let position = Arc::new(AtomicU64::new(0));
            let seek = Arc::new(AtomicU64::new(u64::MAX));
            let (p, cursor, jump) = (paused.clone(), position.clone(), seek.clone());
            let (stop, rx) = std::sync::mpsc::channel::<PlaybackStartAck>();
            let (ready, ready_rx) = std::sync::mpsc::sync_channel(1);
            let worker = std::thread::spawn(move || {
                let setup = (|| -> Result<_> {
                    if cancel.is_cancelled() {
                        bail!("Audio preparation cancelled");
                    }
                    let device = cpal::default_host()
                        .default_output_device()
                        .context("No audio output device is available")?;
                    let config = device.default_output_config()?;
                    let sr = config.sample_rate().0;
                    let channels = config.channels() as usize;
                    let temp = tempfile::NamedTempFile::new()?;
                    ffmpeg.decode_pcm_cancellable(&source, temp.path(), sr, rate, &cancel)?;
                    if cancel.is_cancelled() {
                        bail!("Audio preparation cancelled");
                    }
                    let length = std::fs::metadata(temp.path())?.len() / 4;
                    let mut input = std::io::BufReader::new(temp.reopen()?);
                    let mut frame = [0u8; 4];
                    let error_slot = Arc::new(Mutex::new(None::<String>));
                    let error_copy = error_slot.clone();
                    let error = move |_: cpal::StreamError| {
                        *error_copy.lock().unwrap() = Some("Audio output was disconnected".into());
                    };
                    let mut next = move || -> f32 {
                        if p.load(Ordering::Relaxed) {
                            return 0.;
                        }
                        let target = jump.swap(u64::MAX, Ordering::Relaxed);
                        if target != u64::MAX {
                            let target = target.min(length);
                            let _ = input.seek(SeekFrom::Start(target * 4));
                            cursor.store(target, Ordering::Relaxed);
                        }
                        if input.read_exact(&mut frame).is_ok() {
                            cursor.fetch_add(1, Ordering::Relaxed);
                            f32::from_le_bytes(frame)
                        } else {
                            0.
                        }
                    };
                    let stream = match config.sample_format() {
                        cpal::SampleFormat::F32 => device.build_output_stream(
                            &config.into(),
                            move |out: &mut [f32], _| {
                                for frame in out.chunks_mut(channels) {
                                    let x = next();
                                    frame.fill(x);
                                }
                            },
                            error,
                            None,
                        )?,
                        cpal::SampleFormat::I16 => device.build_output_stream(
                            &config.into(),
                            move |out: &mut [i16], _| {
                                for frame in out.chunks_mut(channels) {
                                    let x = (next().clamp(-1., 1.) * i16::MAX as f32) as i16;
                                    frame.fill(x);
                                }
                            },
                            error,
                            None,
                        )?,
                        cpal::SampleFormat::U16 => device.build_output_stream(
                            &config.into(),
                            move |out: &mut [u16], _| {
                                for frame in out.chunks_mut(channels) {
                                    let x = ((next().clamp(-1., 1.) + 1.) * 0.5 * u16::MAX as f32)
                                        as u16;
                                    frame.fill(x);
                                }
                            },
                            error,
                            None,
                        )?,
                        _ => bail!("Unsupported output device sample format"),
                    };
                    Ok((stream, temp, sr, length, error_slot))
                })();
                let (stream, _temp, sr, length, error_slot) = match setup {
                    Ok(v) => {
                        let _ = ready.send(Ok((v.2, v.3)));
                        v
                    }
                    Err(e) => {
                        let _ = ready.send(Err(e.to_string()));
                        return Err(e);
                    }
                };
                let mut started = false;
                loop {
                    if cancel.is_cancelled() {
                        break;
                    }
                    match rx.recv_timeout(Duration::from_millis(25)) {
                        Ok(ack) => {
                            if cancel.is_cancelled() {
                                let _ = ack.send(Err("Audio preparation cancelled".into()));
                                break;
                            }
                            if !started {
                                match stream.play() {
                                    Ok(()) => started = true,
                                    Err(error) => {
                                        let _ = ack.send(Err(error.to_string()));
                                        break;
                                    }
                                }
                            }
                            let _ = ack.send(Ok(()));
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                    }
                }
                drop(stream);
                let _ = (sr, length);
                if let Some(error) = error_slot.lock().unwrap().take() {
                    bail!(error);
                }
                Ok(())
            });
            let (sr, length) = ready_rx
                .recv_timeout(Duration::from_secs(120))
                .context("Audio playback could not be prepared")?
                .map_err(anyhow::Error::msg)?;
            Ok(Self {
                stop: Some(stop),
                worker: Some(worker),
                paused,
                position,
                seek,
                sample_rate: sr,
                rate,
                duration: length as f64 / sr as f64 * rate as f64,
            })
        }
        /// The caller holds playback ownership while starting and installing.
        pub fn begin(&self) -> Result<()> {
            let (tx, rx) = std::sync::mpsc::sync_channel(1);
            self.stop
                .as_ref()
                .context("Audio playback already stopped")?
                .send(tx)
                .map_err(|_| anyhow::anyhow!("Audio playback was cancelled"))?;
            rx.recv_timeout(Duration::from_secs(5))
                .context("Audio output could not start")?
                .map_err(anyhow::Error::msg)
        }
        pub fn pause(&self, paused: bool) {
            self.paused.store(paused, Ordering::Relaxed);
        }
        pub fn position(&self) -> f64 {
            // A paused stream does not consume its queued seek until it resumes.
            // Report the requested position immediately so another pause, seek or
            // narration-option change cannot restore the old position meanwhile.
            let pending = self.seek.load(Ordering::Relaxed);
            let frames = if pending == u64::MAX {
                self.position.load(Ordering::Relaxed)
            } else {
                pending
            };
            (frames as f64 / self.sample_rate as f64 * self.rate as f64).min(self.duration)
        }
        pub fn seek(&self, seconds: f64) {
            self.seek.store(
                (seconds.max(0.).min(self.duration) / self.rate as f64 * self.sample_rate as f64)
                    as u64,
                Ordering::Relaxed,
            );
        }
        pub fn stop(mut self) -> Result<()> {
            self.stop.take();
            self.worker
                .take()
                .unwrap()
                .join()
                .map_err(|_| anyhow::anyhow!("Playback worker stopped unexpectedly"))?
        }
    }
    impl Drop for Playback {
        fn drop(&mut self) {
            self.stop.take();
            if let Some(worker) = self.worker.take() {
                let _ = worker.join();
            }
        }
    }

    #[cfg(test)]
    mod playback_tests {
        use super::*;

        fn paused_playback(rate: f32) -> Playback {
            Playback {
                stop: None,
                worker: None,
                paused: Arc::new(AtomicBool::new(true)),
                position: Arc::new(AtomicU64::new(0)),
                seek: Arc::new(AtomicU64::new(u64::MAX)),
                sample_rate: 48_000,
                rate,
                duration: 60.,
            }
        }

        #[test]
        fn seeking_a_paused_clip_reports_its_source_position_before_resume() {
            for rate in [0.5, 1., 1.5, 2.] {
                let playback = paused_playback(rate);
                playback.seek(18.75);
                assert!((playback.position() - 18.75).abs() < 0.0001);
                playback.seek(9.);
                assert!((playback.position() - 9.).abs() < 0.0001);
                assert!(playback.paused.load(Ordering::Relaxed));
            }
        }

        #[test]
        fn paused_seek_keeps_reported_position_within_the_recording() {
            let playback = paused_playback(1.5);
            playback.seek(300.);
            assert_eq!(playback.position(), 60.);
            playback.seek(-2.);
            assert_eq!(playback.position(), 0.);
        }
    }
}
#[cfg(feature = "native-audio")]
pub use native::{Playback, Recording};

#[cfg(feature = "speech")]
pub mod speech {
    use super::*;
    use sherpa_onnx::{
        GenerationConfig, OfflineRecognizer, OfflineRecognizerConfig, OfflineTts, OfflineTtsConfig,
        OfflineTtsModelConfig, OfflineTtsPocketModelConfig, OfflineWhisperModelConfig, Wave,
    };
    pub struct PocketSpeech {
        engine: OfflineTts,
    }
    impl PocketSpeech {
        pub fn load(directory: &Path) -> Result<Self> {
            let file = |name: &str| -> Result<Option<String>> {
                let p = directory.join(name);
                if !p.is_file() {
                    bail!("PocketTTS model file is missing: {name}. Download the verified model first");
                }
                Ok(Some(p.to_string_lossy().into()))
            };
            let config = OfflineTtsConfig {
                model: OfflineTtsModelConfig {
                    pocket: OfflineTtsPocketModelConfig {
                        lm_flow: file("lm_flow.int8.onnx")?,
                        lm_main: file("lm_main.int8.onnx")?,
                        encoder: file("encoder.onnx")?,
                        decoder: file("decoder.int8.onnx")?,
                        text_conditioner: file("text_conditioner.onnx")?,
                        vocab_json: file("vocab.json")?,
                        token_scores_json: file("token_scores.json")?,
                        voice_embedding_cache_capacity: 4,
                    },
                    num_threads: 2,
                    debug: false,
                    ..Default::default()
                },
                ..Default::default()
            };
            Ok(Self {
                engine: OfflineTts::create(&config)
                    .context("PocketTTS model could not be initialized")?,
            })
        }
        pub fn synthesize(
            &self,
            text: &str,
            voice_wave: &Path,
            speed: f32,
            destination: &Path,
            cancel: CancellationToken,
        ) -> Result<()> {
            if cancel.is_cancelled() {
                bail!("Narration cancelled");
            }
            let voice = Wave::read(voice_wave.to_str().context("Invalid voice path")?)
                .context("The licensed reference voice is unavailable")?;
            let config = GenerationConfig {
                speed,
                reference_audio: Some(voice.samples().to_vec()),
                reference_sample_rate: voice.sample_rate(),
                ..Default::default()
            };
            let callback_cancel = cancel.clone();
            let callback = move |_: &[f32], _: f32| !callback_cancel.is_cancelled();
            let audio = self
                .engine
                .generate_with_config(text, &config, Some(callback))
                .context("Local speech synthesis failed")?;
            if cancel.is_cancelled() {
                bail!("Narration cancelled");
            }
            if !audio.save(destination.to_str().context("Invalid narration path")?) {
                bail!("Could not save narrated audio");
            }
            Ok(())
        }
    }
    pub struct WhisperSpeech {
        recognizer: OfflineRecognizer,
    }
    impl WhisperSpeech {
        pub fn load(directory: &Path, language: Option<String>) -> Result<Self> {
            let file = |name: &str| -> Result<Option<String>> {
                let p = directory.join(name);
                if !p.is_file() {
                    bail!(
                        "Whisper model file is missing: {name}. Download the verified model first"
                    );
                }
                Ok(Some(p.to_string_lossy().into()))
            };
            let mut c = OfflineRecognizerConfig::default();
            c.model_config.whisper = OfflineWhisperModelConfig {
                encoder: file("base-encoder.int8.onnx")?,
                decoder: file("base-decoder.int8.onnx")?,
                language,
                task: Some("transcribe".into()),
                ..Default::default()
            };
            c.model_config.tokens = file("base-tokens.txt")?;
            c.model_config.num_threads = 2;
            c.model_config.provider = Some("cpu".into());
            Ok(Self {
                recognizer: OfflineRecognizer::create(&c)
                    .context("Whisper model could not be initialized")?,
            })
        }
        pub fn transcribe(&self, wave: &Path, cancel: CancellationToken) -> Result<String> {
            let wave = Wave::read(wave.to_str().context("Invalid recording path")?)
                .context("Could not read the transcription audio")?;
            if cancel.is_cancelled() {
                bail!("Transcription cancelled");
            }
            // Whisper's context is 30 seconds. Decode overlapping windows rather
            // than handing a long recording to one bounded model invocation.
            let sample_rate = wave.sample_rate() as usize;
            let window = sample_rate * 28;
            let overlap = sample_rate;
            let mut transcript = Vec::<String>::new();
            let samples = wave.samples();
            let mut offset = 0;
            while offset < samples.len() {
                if cancel.is_cancelled() {
                    bail!("Transcription cancelled");
                }
                let segment = &samples[offset..(offset + window).min(samples.len())];
                let energy =
                    segment.iter().map(|s| s * s).sum::<f32>() / segment.len().max(1) as f32;
                if energy > 0.000001 {
                    let stream = self.recognizer.create_stream();
                    stream.accept_waveform(wave.sample_rate(), segment);
                    self.recognizer.decode(&stream);
                    if cancel.is_cancelled() {
                        bail!("Transcription cancelled");
                    }
                    if let Some(result) = stream.get_result() {
                        let words: Vec<String> =
                            result.text.split_whitespace().map(str::to_owned).collect();
                        let repeated = (1..=words.len().min(transcript.len()).min(24))
                            .rev()
                            .find(|n| {
                                transcript[transcript.len() - n..]
                                    .iter()
                                    .zip(&words[..*n])
                                    .all(|(a, b)| {
                                        a.trim_matches(|c: char| c.is_ascii_punctuation())
                                            .eq_ignore_ascii_case(
                                                b.trim_matches(|c: char| c.is_ascii_punctuation()),
                                            )
                                    })
                            })
                            .unwrap_or(0);
                        transcript.extend(words.into_iter().skip(repeated));
                    }
                }
                if offset + window >= samples.len() {
                    break;
                }
                offset += window - overlap;
            }
            if transcript.is_empty() {
                bail!("No speech was recognized");
            }
            Ok(transcript.join(" "))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn model_paths_cannot_escape_cache() {
        let m = ModelManager::new(PathBuf::from("/tmp/models")).unwrap();
        assert!(m.model_directory("../private").is_err());
        assert!(m.model_directory("pocket-tts").is_ok());
    }
    #[test]
    fn models_are_verified_before_use() {
        let d = tempfile::tempdir().unwrap();
        let file = d.path().join("model.onnx");
        std::fs::write(&file, b"weights").unwrap();
        let spec = ModelFile {
            name: "model.onnx".into(),
            url: "https://example.com/model".into(),
            sha256: crate::sync::sha256(b"weights"),
            size: 7,
        };
        assert!(verify_file(&file, &spec).unwrap());
        std::fs::write(file, b"corrupt").unwrap();
        assert!(!verify_file(&d.path().join("model.onnx"), &spec).unwrap());
    }
    #[test]
    fn missing_audio_codec_has_actionable_error() {
        let error = Ffmpeg::new(PathBuf::from("/nonexistent/kodi-ffmpeg"))
            .err()
            .unwrap()
            .to_string();
        assert!(error.contains("FFmpeg"));
    }
    #[cfg(unix)]
    #[test]
    fn cancelled_codec_preparation_terminates_its_child() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let marker = directory.path().join("started");
        let script = directory.path().join("codec");
        let marker_arg = format!("'{}'", marker.to_string_lossy().replace('\'', "'\\''"));
        std::fs::write(
            &script,
            format!("#!/bin/sh\nprintf ready > {marker_arg}\nexec sleep 30\n"),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        let codec = Ffmpeg::new(script).unwrap();
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let worker = std::thread::spawn(move || codec.run_cancellable(&[], &token));
        let start = std::time::Instant::now();
        while !marker.exists() && start.elapsed() < Duration::from_secs(2) {
            std::thread::sleep(Duration::from_millis(5));
        }
        let started = marker.exists();
        cancel.cancel();
        let result = worker.join().unwrap();
        assert!(started, "The synthetic codec child did not start");
        assert!(result.unwrap_err().to_string().contains("cancelled"));
        assert!(start.elapsed() < Duration::from_secs(3));
    }
    fn pending(root: &Path, bytes: &[u8]) -> PendingRecording {
        let directory = root.join("Audio/.pending");
        let pending = PendingRecording::new(
            "epub-sha256:test",
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            16000,
        )
        .unwrap();
        pending.write_journal(&directory).unwrap();
        std::fs::write(pending.pcm_path(&directory), bytes).unwrap();
        pending
    }
    #[test]
    fn persistent_pcm_summary_recovers_duration_and_waveform() {
        let dir = tempfile::tempdir().unwrap();
        let bytes = vec![0.25f32; 1600]
            .into_iter()
            .flat_map(f32::to_le_bytes)
            .collect::<Vec<_>>();
        let recording = pending(dir.path(), &bytes);
        let (duration, waveform) = pcm_summary(
            &recording.pcm_path(&dir.path().join("Audio/.pending")),
            16000,
        )
        .unwrap();
        assert_eq!(duration, 0.1);
        assert_eq!(waveform, vec![0.25]);
        confirm_pending_recording(dir.path(), &recording.audio_id).unwrap();
        assert!(!recording
            .pcm_path(&dir.path().join("Audio/.pending"))
            .exists());
    }
    #[cfg(unix)]
    #[test]
    fn empty_pending_capture_does_not_create_an_audio_attachment() {
        let dir = tempfile::tempdir().unwrap();
        let recording = pending(dir.path(), b"");
        let report = recover_pending_recordings(
            dir.path(),
            &Ffmpeg::new(PathBuf::from("/usr/bin/false")).unwrap(),
        )
        .unwrap();
        assert!(report.recordings.is_empty());
        assert!(report.errors.is_empty());
        assert!(!recording
            .pcm_path(&dir.path().join("Audio/.pending"))
            .exists());
    }
    #[cfg(unix)]
    #[test]
    fn corrupt_pending_pcm_is_preserved_and_not_attached() {
        let dir = tempfile::tempdir().unwrap();
        let recording = pending(dir.path(), b"abc");
        let report = recover_pending_recordings(
            dir.path(),
            &Ffmpeg::new(PathBuf::from("/usr/bin/false")).unwrap(),
        )
        .unwrap();
        assert!(report.recordings.is_empty());
        assert_eq!(report.errors.len(), 1);
        assert_eq!(
            std::fs::read(recording.pcm_path(&dir.path().join("Audio/.pending"))).unwrap(),
            b"abc"
        );
    }
    #[cfg(unix)]
    #[test]
    fn failed_recovery_encoder_preserves_pending_pcm_without_fake_success() {
        let dir = tempfile::tempdir().unwrap();
        let recording = pending(dir.path(), &0.25f32.to_le_bytes());
        let report = recover_pending_recordings(
            dir.path(),
            &Ffmpeg::new(PathBuf::from("/usr/bin/false")).unwrap(),
        )
        .unwrap();
        assert!(report.recordings.is_empty());
        assert_eq!(report.errors.len(), 1);
        assert!(recording
            .pcm_path(&dir.path().join("Audio/.pending"))
            .exists());
        assert!(!dir.path().join(recording.relative_destination()).exists());
    }
    fn response_server(
        response: String,
        expected_range: Option<&'static str>,
    ) -> (String, std::thread::JoinHandle<()>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut bytes = [0; 4096];
            let n = socket.read(&mut bytes).unwrap();
            let request = String::from_utf8_lossy(&bytes[..n]).to_lowercase();
            if let Some(range) = expected_range {
                assert!(request.contains(range));
            }
            socket.write_all(response.as_bytes()).unwrap();
        });
        (format!("http://{address}/model"), worker)
    }
    #[tokio::test]
    async fn interrupted_model_download_resumes_at_verified_partial_length() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("model.onnx");
        let (url, server) = response_server(
            "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nabc".into(),
            None,
        );
        let mut spec = ModelFile {
            name: "model.onnx".into(),
            url,
            sha256: crate::sync::sha256(b"abcdef"),
            size: 6,
        };
        let client = reqwest::Client::new();
        assert!(
            download_verified(&client, &spec, &target, CancellationToken::new(), |_| {})
                .await
                .is_err()
        );
        server.join().unwrap();
        assert_eq!(std::fs::read(partial_path(&target, &spec)).unwrap(), b"abc");
        let(url,server)=response_server("HTTP/1.1 206 Partial Content\r\nContent-Length: 3\r\nContent-Range: bytes 3-5/6\r\nConnection: close\r\n\r\ndef".into(),Some("range: bytes=3-"));
        spec.url = url;
        download_verified(&client, &spec, &target, CancellationToken::new(), |_| {})
            .await
            .unwrap();
        server.join().unwrap();
        assert_eq!(std::fs::read(target).unwrap(), b"abcdef");
    }
    #[tokio::test]
    async fn server_ignoring_range_restarts_instead_of_appending() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("model.onnx");
        let (url, server) = response_server(
            "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nabcdef".into(),
            Some("range: bytes=3-"),
        );
        let spec = ModelFile {
            name: "model.onnx".into(),
            url,
            sha256: crate::sync::sha256(b"abcdef"),
            size: 6,
        };
        std::fs::write(partial_path(&target, &spec), b"abc").unwrap();
        download_verified(
            &reqwest::Client::new(),
            &spec,
            &target,
            CancellationToken::new(),
            |_| {},
        )
        .await
        .unwrap();
        server.join().unwrap();
        assert_eq!(std::fs::read(target).unwrap(), b"abcdef");
    }
    #[tokio::test]
    async fn corrupt_download_keeps_previous_model_and_discards_partial() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("model.onnx");
        std::fs::write(&target, b"previous").unwrap();
        let (url, server) = response_server(
            "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nxxxxxx".into(),
            None,
        );
        let spec = ModelFile {
            name: "model.onnx".into(),
            url,
            sha256: crate::sync::sha256(b"abcdef"),
            size: 6,
        };
        assert!(download_verified(
            &reqwest::Client::new(),
            &spec,
            &target,
            CancellationToken::new(),
            |_| {}
        )
        .await
        .is_err());
        server.join().unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"previous");
        assert!(!partial_path(&target, &spec).exists());
    }
}
