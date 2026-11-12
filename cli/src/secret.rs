//! The API key: `BLABLADOR_API_KEY`, else the system keyring entry the desktop app uses
//! (service de.fz-juelich.blablador, account apiKey), else a file only the user can read.

use std::path::PathBuf;

const SERVICE: &str = "de.fz-juelich.blablador";
const ACCOUNT: &str = "apiKey";

fn entry() -> Option<keyring::Entry> {
    if std::env::var_os("BLABLADOR_NO_KEYRING").is_some() {
        return None;
    }
    keyring::Entry::new(SERVICE, ACCOUNT).ok()
}

fn file() -> PathBuf {
    crate::util::bla_home().join(".apikey")
}

pub fn api_key() -> Option<String> {
    if let Ok(key) = std::env::var("BLABLADOR_API_KEY") {
        if !key.trim().is_empty() {
            return Some(key.trim().to_string());
        }
    }
    if let Some(key) = entry().and_then(|e| e.get_password().ok()) {
        return Some(key);
    }
    std::fs::read_to_string(file()).ok().map(|k| k.trim().to_string()).filter(|k| !k.is_empty())
}

pub fn save(key: &str) -> Result<&'static str, String> {
    let key = key.trim();
    if key.is_empty() {
        return Err("no key given".into());
    }
    if let Some(e) = entry() {
        // Read back: some keyrings accept a write and forget it.
        if e.set_password(key).is_ok() && entry().and_then(|e| e.get_password().ok()).as_deref() == Some(key) {
            let _ = std::fs::remove_file(file());
            return Ok("the system keyring");
        }
    }
    let path = file();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    write_private(&path, key.as_bytes()).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok("~/.bla/.apikey (readable only by you)")
}

pub fn delete() {
    if let Some(e) = entry() {
        let _ = e.delete_credential();
    }
    let _ = std::fs::remove_file(file());
}

/// Writes a file only the owner can read, created that way so it is never readable by others, even briefly.
pub fn write_private(path: &std::path::Path, contents: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut f = options.open(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    f.write_all(contents)
}
