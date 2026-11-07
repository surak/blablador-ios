//! Text from attached files: PDFs (their text layer) and plain text formats.

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
        return Err(anyhow!("{} is not a text file or PDF.", path.file_name().unwrap_or_default().to_string_lossy()));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
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
