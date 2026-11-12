//! Exercises crash recovery from synthetic PCM without opening a microphone.
use anyhow::{Context, Result};
use kodi_desktop_services::audio::{
    confirm_pending_recording, recover_pending_recordings, Ffmpeg, PendingRecording,
};
use std::path::PathBuf;
fn main() -> Result<()> {
    let ffmpeg = Ffmpeg::new(PathBuf::from(
        std::env::args()
            .nth(1)
            .context("Pass the validated minimal FFmpeg executable")?,
    ))?;
    let directory = tempfile::tempdir()?;
    let pending_directory = directory.path().join("Audio/.pending");
    let pending = PendingRecording::new(
        "epub-sha256:synthetic",
        "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
        16000,
    )?;
    pending.write_journal(&pending_directory)?;
    let pcm = (0..16000)
        .flat_map(|i| {
            ((i as f32 * 440. * 2. * std::f32::consts::PI / 16000.).sin() * 0.2).to_le_bytes()
        })
        .collect::<Vec<_>>();
    std::fs::write(pending.pcm_path(&pending_directory), pcm)?;
    let report = recover_pending_recordings(directory.path(), &ffmpeg)?;
    assert!(report.errors.is_empty());
    assert_eq!(report.recordings.len(), 1);
    let recovered = &report.recordings[0];
    assert_eq!(recovered.recording.duration, 1.);
    assert!(std::fs::metadata(&recovered.recording.path)?.len() > 0);
    let decoded = directory.path().join("decoded.f32le");
    ffmpeg.decode_pcm_cancellable(
        &recovered.recording.path,
        &decoded,
        16000,
        1.5,
        &kodi_desktop_services::CancellationToken::new(),
    )?;
    assert!(std::fs::metadata(decoded)?.len() > 0);
    assert!(
        pending.pcm_path(&pending_directory).exists(),
        "Keep the PCM until library commit"
    );
    confirm_pending_recording(directory.path(), &pending.audio_id)?;
    assert!(!pending.pcm_path(&pending_directory).exists());
    println!(
        "{}",
        serde_json::json!({"result":"passed","syntheticDuration":recovered.recording.duration,"waveformBuckets":recovered.recording.waveform.len(),"microphoneOpened":false})
    );
    Ok(())
}
