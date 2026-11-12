use kodi_reader_core::{build_article_epub, Article};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args_os()
        .nth(1)
        .ok_or("Supply output EPUB path")?;
    let article = Article {
        title: "Kodi native smoke fixture".into(),
        author: "Kodi Reader tests".into(),
        source_url: "https://example.invalid/kodi-native-smoke".into(),
        html: format!("<p id=\"start\">Durable anchors survive typography and window changes. 😀</p>{}", "<p>This offline chapter tests native publication loading, pagination, notes and reading progress.</p>".repeat(80)),
        images: vec![],
    };
    std::fs::write(path, build_article_epub(&article)?)?;
    Ok(())
}
