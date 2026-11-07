//! Where files live and how they are kept: everything the app saves is encrypted with AES-GCM, with the key
//! in the system keyring (Windows Credential Manager, Secret Service on Linux, Keychain on macOS).
//! Without a keyring (a headless Linux box, say) the key is kept in a file only the user can read.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine;
use rand::RngCore;
use serde::{de::DeserializeOwned, Serialize};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

const SERVICE: &str = "de.fz-juelich.blablador";
const MAGIC: &[u8] = b"BLA1";

pub fn data_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("BLABLADOR_DATA_DIR") {
        return PathBuf::from(dir);
    }
    let dir = directories::ProjectDirs::from("de", "fz-juelich", "Blablador")
        .map(|d| d.data_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".blablador"));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

pub fn path(name: &str) -> PathBuf {
    data_dir().join(name)
}

fn keyring_entry(name: &str) -> Option<keyring::Entry> {
    // BLABLADOR_NO_KEYRING keeps secrets in files, for tests and machines whose keyring misbehaves.
    if std::env::var_os("BLABLADOR_NO_KEYRING").is_some() {
        return None;
    }
    keyring::Entry::new(SERVICE, name).ok()
}

/// A secret file next to the data, for systems without a keyring.
fn secret_file(name: &str) -> PathBuf {
    data_dir().join(format!(".{name}"))
}

fn write_private(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    std::fs::write(path, contents)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

fn read_secret(name: &str) -> Option<String> {
    if let Some(value) = keyring_entry(name).and_then(|entry| entry.get_password().ok()) {
        return Some(value);
    }
    std::fs::read_to_string(secret_file(name)).ok().map(|s| s.trim().to_string())
}

fn write_secret(name: &str, value: &str) {
    let stored = keyring_entry(name).map(|entry| entry.set_password(value).is_ok()).unwrap_or(false);
    // Read back: some keyrings accept the write and forget it.
    if stored && keyring_entry(name).and_then(|entry| entry.get_password().ok()).as_deref() == Some(value) {
        let _ = std::fs::remove_file(secret_file(name));
    } else {
        let _ = write_private(&secret_file(name), value.as_bytes());
    }
}

fn delete_secret(name: &str) {
    if let Some(entry) = keyring_entry(name) {
        let _ = entry.delete_credential();
    }
    let _ = std::fs::remove_file(secret_file(name));
}

/// The API key: BLABLADOR_API_KEY when set, otherwise the one saved in Settings.
pub fn api_key() -> String {
    std::env::var("BLABLADOR_API_KEY").ok().filter(|k| !k.is_empty()).or_else(|| read_secret("apiKey")).unwrap_or_default()
}

pub fn set_api_key(key: &str) {
    if key.trim().is_empty() {
        delete_secret("apiKey");
    } else {
        write_secret("apiKey", key.trim());
    }
}

fn cipher() -> &'static Aes256Gcm {
    static CIPHER: OnceLock<Aes256Gcm> = OnceLock::new();
    CIPHER.get_or_init(|| {
        let engine = base64::engine::general_purpose::STANDARD;
        let key = read_secret("storageKey").and_then(|k| engine.decode(k).ok()).filter(|k| k.len() == 32).unwrap_or_else(|| {
            let mut key = vec![0u8; 32];
            rand::thread_rng().fill_bytes(&mut key);
            write_secret("storageKey", &engine.encode(&key));
            key
        });
        Aes256Gcm::new_from_slice(&key).expect("32-byte key")
    })
}

pub fn encrypt(plain: &[u8]) -> Vec<u8> {
    let mut nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce);
    let sealed = cipher().encrypt(Nonce::from_slice(&nonce), plain).expect("encryption");
    [MAGIC, &nonce, &sealed].concat()
}

pub fn decrypt(data: &[u8]) -> Option<Vec<u8>> {
    let rest = data.strip_prefix(MAGIC)?;
    if rest.len() < 12 {
        return None;
    }
    cipher().decrypt(Nonce::from_slice(&rest[..12]), &rest[12..]).ok()
}

/// Writes atomically, so a crash never leaves half a file.
pub fn write(path: &Path, plain: &[u8]) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let temporary = path.with_extension("tmp");
    if write_private(&temporary, &encrypt(plain)).is_ok() {
        let _ = std::fs::rename(&temporary, path);
    }
}

pub fn read(path: &Path) -> Option<Vec<u8>> {
    decrypt(&std::fs::read(path).ok()?)
}

pub fn write_json<T: Serialize>(path: &Path, value: &T) {
    if let Ok(data) = serde_json::to_vec(value) {
        write(path, &data);
    }
}

pub fn read_json<T: DeserializeOwned>(path: &Path) -> Option<T> {
    serde_json::from_slice(&read(path)?).ok()
}

#[cfg(test)]
mod tests {
    #[test]
    fn round_trip() {
        let dir = std::env::temp_dir().join(format!("blablador-test-{}", uuid::Uuid::new_v4()));
        std::env::set_var("BLABLADOR_DATA_DIR", &dir);
        std::env::set_var("BLABLADOR_NO_KEYRING", "1");
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("x.json");
        super::write_json(&file, &vec!["hello"]);
        assert!(!std::fs::read(&file).unwrap().windows(5).any(|w| w == b"hello"));
        assert_eq!(super::read_json::<Vec<String>>(&file).unwrap(), vec!["hello"]);
        let _ = std::fs::remove_dir_all(dir);
    }
}
