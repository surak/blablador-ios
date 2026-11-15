//! Text from attached files: PDFs (their text layer) and plain text formats; pictures go to a vision model (app.rs).

use anyhow::{anyhow, Result};
use std::path::Path;

/// Characters of an attachment handed to the model.
pub const MAX_ATTACHMENT: usize = 100_000;

/// The text of a file, with "[Page n]" markers for PDFs.
pub fn text_of(path: &Path) -> Result<String> {
    let bytes = std::fs::read(path)?;
    if bytes.starts_with(b"%PDF") {
        return pdf_text(&bytes);
    }
    if bytes.iter().take(8000).any(|&b| b == 0) {
        return Err(anyhow!("{} is not a text file, PDF or picture.", path.file_name().unwrap_or_default().to_string_lossy()));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// A photo or screenshot, by its first bytes: these are read by a vision model, not as text.
pub fn is_picture(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0xFF, 0xD8, 0xFF]) || bytes.starts_with(b"\x89PNG") || (bytes.len() > 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP")
}

/// A picture as a JPEG data URL, at most 1568 pixels on its long side: phone photos are many megabytes, and vision
/// models scale them down to about that anyway.
pub fn picture_data_url(bytes: &[u8]) -> Result<String> {
    use base64::Engine;
    let picture = image::load_from_memory(bytes).map_err(|e| anyhow!("Can't open this picture: {e}"))?;
    let picture = if picture.width().max(picture.height()) > 1568 { picture.resize(1568, 1568, image::imageops::FilterType::Triangle) } else { picture };
    let mut jpeg = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 85)
        .encode_image(&picture.to_rgb8())
        .map_err(|e| anyhow!("Can't convert this picture: {e}"))?;
    Ok(format!("data:image/jpeg;base64,{}", base64::engine::general_purpose::STANDARD.encode(jpeg)))
}

pub fn pdf_text(bytes: &[u8]) -> Result<String> {
    let pages = pdf_extract::extract_text_from_mem_by_pages(bytes).map_err(|e| anyhow!("Can't read this PDF: {e}"))?;
    let text: String = pages
        .iter()
        .enumerate()
        .filter(|(_, page)| !page.trim().is_empty())
        .map(|(number, page)| format!("[Page {}]\n{}\n", number + 1, page.trim()))
        .collect();
    if text.trim().is_empty() {
        return Err(anyhow!("This PDF has no text layer (scanned pages need OCR, which the desktop app doesn't do yet)."));
    }
    Ok(text)
}
