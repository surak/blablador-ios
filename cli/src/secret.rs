//! The API key: `BLABLADOR_API_KEY`, else the system keyring entry the desktop app uses
//! (service de.fz-juelich.blablador, account apiKey), else a file only the user can read.

use std::path::PathBuf;
use std::sync::Mutex;

/// The key as it is known now. Cached so that a request doesn't read the keyring every time, and updated by
/// [`save`], so that a key given after a provider was built (say `/login` in the chat) is the one requests use:
/// without this, logging in mid-chat would keep failing until bla was restarted.
static LIVE: Mutex<Option<String>> = Mutex::new(None);

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
    if let Some(key) = LIVE.lock().unwrap_or_else(|e| e.into_inner()).clone() {
        return Some(key);
    }
    let key = resolve()?;
    *LIVE.lock().unwrap_or_else(|e| e.into_inner()) = Some(key.clone());
    Some(key)
}

fn resolve() -> Option<String> {
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
    // Before anything can fail: whatever is running now must use the key the user just gave.
    *LIVE.lock().unwrap_or_else(|e| e.into_inner()) = Some(key.to_string());
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
    *LIVE.lock().unwrap_or_else(|e| e.into_inner()) = None;
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
