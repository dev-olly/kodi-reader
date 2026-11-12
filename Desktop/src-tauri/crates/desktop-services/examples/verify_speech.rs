//! Verifies the real offline model pipeline using fixed, non-personal test text.
use anyhow::{bail, Context, Result};
use kodi_desktop_services::{
    audio::{
        speech::{PocketSpeech, WhisperSpeech},
        Ffmpeg, ModelManager, ModelSpec,
    },
    CancellationToken,
};
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let root = PathBuf::from(
        args.next()
            .context("Pass a temporary model-cache directory")?,
    );
    let ffmpeg = Ffmpeg::new(PathBuf::from(
        args.next()
            .context("Pass the validated minimal FFmpeg executable")?,
    ))?;
    std::fs::create_dir_all(&root)?;
    let models = ModelManager::new(root.join("Models"))?;
    let catalog: Vec<ModelSpec> = serde_json::from_str(include_str!("../src/model-catalog.json"))?;
    for spec in &catalog {
        let mut last = 0;
        println!("Verifying/downloading {}", spec.id);
        models
            .install(spec, CancellationToken::new(), |done, total| {
                let percent = if total > 0 { done * 100 / total } else { 0 };
                if percent >= last + 25 {
                    println!("{}: {}%", spec.id, percent);
                    last = percent;
                }
            })
            .await?;
        if !models.verified(spec)? {
            bail!("Model verification failed");
        }
    }
    let text = "Kodi Reader keeps your books and notes together.";
    let generated = root.join("generated.wav");
    let wave = root.join("recognition.wav");
    let start = std::time::Instant::now();
    PocketSpeech::load(&models.model_directory("pocket-tts")?)?.synthesize(
        text,
        &models.model_directory("narration-voices")?.join("anna.wav"),
        1.,
        &generated,
        CancellationToken::new(),
    )?;
    ffmpeg.transcribe_wave(&generated, &wave)?;
    let transcript =
        WhisperSpeech::load(&models.model_directory("whisper-base")?, Some("en".into()))?
            .transcribe(&wave, CancellationToken::new())?;
    for word in ["books", "notes", "together"] {
        if !transcript.to_lowercase().contains(word) {
            bail!("Offline transcript failed its fixed-text check: {transcript}");
        }
    }
    println!(
        "{}",
        serde_json::json!({"result":"passed","text":text,"transcript":transcript,"elapsedSeconds":start.elapsed().as_secs_f64(),"generatedWav":generated})
    );
    Ok(())
}
