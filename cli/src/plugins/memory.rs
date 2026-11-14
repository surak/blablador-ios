//! Long-term memory, the same as the Blablador apps': one list of facts that every chat in the apps and every
//! bla session sees. On the Mac it is the app's encrypted memories.json, read and changed through the app's own
//! binary (`Blablador --memory …`), the only program that can open its key in the Keychain. On Linux and Windows
//! (and a Mac without the app) it is the desktop app's encrypted memories.json, with the key from the same keyring
//! entry. The facts enter the system prompt as a snapshot at session start; changes are saved at once and show up
//! in the next session, so the prompt stays the same (and cached) all session.
//!
//! Facts bla kept before 3.9 in `~/.bla/memory/USER.md` and `MEMORY.md` are moved into the shared memory once.

use crate::llm::Message;
use crate::plugin::{CommandResult, CommandSpec, Ctx, Kind, Plugin, Session, Tool, ToolCtx, ToolOutput};
use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine;
use rand::RngCore;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};

/// The apps keep at most this many; the oldest go first.
const MAX: usize = 500;
/// The prompt gets the newest facts up to this many characters.
const PROMPT_LIMIT: usize = 6000;
const SERVICE: &str = "de.fz-juelich.blablador";
const MAGIC: &[u8] = b"BLA1";

#[derive(Clone, Debug, PartialEq)]
pub struct Fact {
    pub id: String,
    pub text: String,
}

pub enum Store {
    /// The Mac app's binary.
    App(PathBuf),
    /// The desktop app's folder, and whether its key may be in the keyring.
    Files { dir: PathBuf, keyring: bool },
}

impl Store {
    /// The store the apps on this computer use.
    pub fn shared() -> Store {
        if cfg!(target_os = "macos") {
            if let Some(app) = mac_app() {
                return Store::App(app);
            }
        }
        let dir = std::env::var_os("BLABLADOR_DATA_DIR").map(PathBuf::from).unwrap_or_else(|| {
            directories::ProjectDirs::from("de", "fz-juelich", "Blablador").map(|d| d.data_dir().to_path_buf()).unwrap_or_else(|| PathBuf::from(".blablador"))
        });
        Store::Files { dir, keyring: std::env::var_os("BLABLADOR_NO_KEYRING").is_none() }
    }

    pub fn place(&self) -> String {
        match self {
            Store::App(app) => format!("the Blablador app's memory ({})", app.display()),
            Store::Files { dir, .. } => format!("the Blablador desktop app's memory ({})", dir.join("memories.json").display()),
        }
    }

    pub fn list(&self) -> Result<Vec<Fact>, String> {
        match self {
            Store::App(app) => {
                let out = run_app(app, &["list"])?;
                let list: Vec<Value> = serde_json::from_str(&out).map_err(|e| format!("the app's answer: {e}"))?;
                Ok(list
                    .iter()
                    .map(|m| Fact { id: m["id"].as_str().unwrap_or_default().to_string(), text: m["text"].as_str().unwrap_or_default().to_string() })
                    .collect())
            }
            Store::Files { .. } => Ok(self
                .read_files()?
                .iter()
                .map(|m| Fact { id: m["id"].as_str().unwrap_or_default().to_string(), text: m["text"].as_str().unwrap_or_default().to_string() })
                .collect()),
        }
    }

    /// False when the fact is already there.
    pub fn add(&self, text: &str) -> Result<bool, String> {
        let text = text.trim();
        if text.is_empty() {
            return Err("add needs content".into());
        }
        match self {
            Store::App(app) => Ok(run_app(app, &["add", text])?.trim() == "added"),
            Store::Files { .. } => {
                let mut all = self.read_files()?;
                if all.iter().any(|m| m["text"].as_str().is_some_and(|t| t.eq_ignore_ascii_case(text))) {
                    return Ok(false);
                }
                all.push(json!({"id": uuid(), "text": text, "created": crate::util::timestamp()}));
                if all.len() > MAX {
                    let extra = all.len() - MAX;
                    all.drain(..extra);
                }
                self.write_files(&all)?;
                Ok(true)
            }
        }
    }

    pub fn update(&self, id: &str, text: &str) -> Result<(), String> {
        match self {
            Store::App(app) => run_app(app, &["update", id, text.trim()]).map(|_| ()),
            Store::Files { .. } => {
                let mut all = self.read_files()?;
                let m = all.iter_mut().find(|m| m["id"].as_str() == Some(id)).ok_or("that fact is gone")?;
                m["text"] = Value::from(text.trim());
                self.write_files(&all)
            }
        }
    }

    pub fn remove(&self, id: &str) -> Result<(), String> {
        match self {
            Store::App(app) => run_app(app, &["remove", id]).map(|_| ()),
            Store::Files { .. } => {
                let mut all = self.read_files()?;
                all.retain(|m| m["id"].as_str() != Some(id));
                self.write_files(&all)
            }
        }
    }

    fn cipher(&self, create: bool) -> Result<Option<Aes256Gcm>, String> {
        let Store::Files { dir, keyring } = self else {
            return Ok(None);
        };
        let engine = base64::engine::general_purpose::STANDARD;
        let entry = if *keyring { keyring::Entry::new(SERVICE, "storageKey").ok() } else { None };
        let file = dir.join(".storageKey");
        let stored = entry.as_ref().and_then(|e| e.get_password().ok()).or_else(|| std::fs::read_to_string(&file).ok().map(|s| s.trim().to_string()));
        let key = match stored.and_then(|k| engine.decode(k).ok()).filter(|k| k.len() == 32) {
            Some(k) => k,
            None if !create => return Ok(None),
            None => {
                // The first memory on this computer: make the key the desktop app will use too.
                let mut key = vec![0u8; 32];
                rand::thread_rng().fill_bytes(&mut key);
                let encoded = engine.encode(&key);
                let kept = entry.as_ref().is_some_and(|e| e.set_password(&encoded).is_ok() && e.get_password().ok().as_deref() == Some(encoded.as_str()));
                if !kept {
                    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                    crate::secret::write_private(&file, encoded.as_bytes()).map_err(|e| e.to_string())?;
                }
                key
            }
        };
        Ok(Aes256Gcm::new_from_slice(&key).ok())
    }

    fn read_files(&self) -> Result<Vec<Value>, String> {
        let Store::Files { dir, .. } = self else {
            return Ok(Vec::new());
        };
        let Ok(data) = std::fs::read(dir.join("memories.json")) else {
            return Ok(Vec::new());
        };
        let cipher = self.cipher(false)?.ok_or("memories.json is there but its key isn't in the keyring")?;
        let rest = data.strip_prefix(MAGIC).filter(|r| r.len() >= 12).ok_or("memories.json isn't in the desktop app's format")?;
        let plain = cipher.decrypt(Nonce::from_slice(&rest[..12]), &rest[12..]).map_err(|_| "memories.json can't be decrypted with the keyring's key")?;
        serde_json::from_slice(&plain).map_err(|e| format!("memories.json: {e}"))
    }

    fn write_files(&self, all: &[Value]) -> Result<(), String> {
        let Store::Files { dir, .. } = self else {
            return Ok(());
        };
        let cipher = self.cipher(true)?.ok_or("no key")?;
        let mut nonce = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut nonce);
        let plain = serde_json::to_vec(all).map_err(|e| e.to_string())?;
        let sealed = cipher.encrypt(Nonce::from_slice(&nonce), plain.as_slice()).map_err(|_| "encryption failed")?;
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        let temporary = dir.join("memories.tmp");
        crate::secret::write_private(&temporary, &[MAGIC, &nonce, &sealed].concat()).map_err(|e| e.to_string())?;
        std::fs::rename(&temporary, dir.join("memories.json")).map_err(|e| e.to_string())
    }
}

/// The Mac app's binary: the one bla came in, or the one in Applications.
fn mac_app() -> Option<PathBuf> {
    let me = std::env::current_exe().ok().and_then(|p| p.canonicalize().ok());
    let bundled = me.and_then(|p| Some(p.parent()?.parent()?.join("MacOS").join("Blablador")));
    let home = crate::util::home().join("Applications/Blablador.app/Contents/MacOS/Blablador");
    [bundled, Some(PathBuf::from("/Applications/Blablador.app/Contents/MacOS/Blablador")), Some(home)].into_iter().flatten().find(|p| p.is_file())
}

fn run_app(app: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new(app).arg("--memory").args(args).env_remove("BLABLADOR_API_KEY").output().map_err(|e| format!("{}: {e}", app.display()))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(if err.is_empty() { "The Blablador app couldn't open its memory; update the app to 3.9 or later.".into() } else { err });
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

fn uuid() -> String {
    let h = crate::util::random_hex(32);
    // Version 4, variant 1.
    format!("{}-{}-4{}-{}{}-{}", &h[..8], &h[8..12], &h[13..16], ['8', '9', 'a', 'b'][h.as_bytes()[16] as usize % 4], &h[17..20], &h[20..32]).to_uppercase()
}

/// The one fact containing `part`.
fn find<'a>(facts: &'a [Fact], part: &str) -> Result<&'a Fact, String> {
    let hits: Vec<&Fact> = facts.iter().filter(|f| f.text.contains(part)).collect();
    match hits.as_slice() {
        [f] => Ok(f),
        [] => Err(format!("no fact contains {part:?}")),
        _ => Err(format!("{} facts contain {part:?}; give more of the text", hits.len())),
    }
}

/// Runs add, patch and remove operations one by one; stops at the first that fails.
pub fn apply(store: &Store, operations: &[Value]) -> Result<String, String> {
    let mut done = Vec::new();
    for op in operations {
        let content = op["content"].as_str().unwrap_or_default().trim();
        let old = op["old_text"].as_str().unwrap_or_default().trim();
        let result = match op["action"].as_str().unwrap_or_default() {
            "add" => store.add(content).map(|added| if added { format!("added {content:?}") } else { format!("{content:?} was already there") }),
            action @ ("patch" | "remove") => {
                if old.is_empty() {
                    Err(format!("{action} needs old_text, part of the fact"))
                } else {
                    (|| {
                        let facts = store.list()?;
                        let fact = find(&facts, old)?;
                        if action == "remove" {
                            store.remove(&fact.id).map(|_| format!("removed {:?}", fact.text))
                        } else if content.is_empty() {
                            Err("patch needs content".into())
                        } else {
                            let text = fact.text.replacen(old, content, 1);
                            store.update(&fact.id, &text).map(|_| format!("now {text:?}"))
                        }
                    })()
                }
            }
            other => Err(format!("unknown action {other:?}; use add, patch or remove")),
        };
        match result {
            Ok(r) => done.push(r),
            Err(e) if done.is_empty() => return Err(format!("{e}. Nothing was changed.")),
            Err(e) => return Err(format!("{e}. Done before that: {}", done.join("; "))),
        }
    }
    Ok(format!("Saved in the shared memory: {}. The Blablador apps see it now; it enters bla's prompt in the next session.", done.join("; ")))
}

struct MemoryTool {
    store: Arc<Store>,
}

impl Tool for MemoryTool {
    fn name(&self) -> &str {
        "memory"
    }
    fn description(&self) -> &str {
        "Save durable facts in the long-term memory you share with the Blablador apps on this computer: who the user is, \
         their preferences and style, their projects, conventions and lessons worth keeping. One short fact per entry, \
         in the third person. Operations: add with content, patch with old_text (part of the fact) and content, remove \
         with old_text. Skip trivia, task progress, secrets and anything easy to find again; procedures belong in skills."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "operations": {"type": "array", "items": {"type": "object", "properties": {
                "action": {"type": "string", "enum": ["add", "patch", "remove"]},
                "content": {"type": "string"},
                "old_text": {"type": "string", "description": "Part of the fact to patch or remove"}
            }, "required": ["action"]}}
        }, "required": ["operations"]})
    }
    /// Memory goes into every later prompt, so a change is a write the user approves (default mode allows it after one "always").
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Write
    }
    fn summary(&self, args: &Value) -> String {
        let ops: Vec<String> = args["operations"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|o| {
                format!(
                    "{} {}",
                    o["action"].as_str().unwrap_or("?"),
                    crate::util::clip(o["content"].as_str().or(o["old_text"].as_str()).unwrap_or_default(), 60)
                )
            })
            .collect();
        ops.join("; ")
    }
    fn run(&self, args: &Value, _ctx: &ToolCtx) -> ToolOutput {
        // Accept a single operation at the top level too: models drift.
        let operations = match args["operations"].as_array() {
            Some(list) => list.clone(),
            None if args["action"].is_string() => vec![args.clone()],
            None => return ToolOutput::err("Give operations."),
        };
        match apply(&self.store, &operations) {
            Ok(text) => ToolOutput::ok(text),
            Err(e) => ToolOutput::err(e),
        }
    }
}

pub struct Memory {
    store: Arc<Store>,
    /// Where bla kept its own memory before.
    old: PathBuf,
    snapshot: Mutex<String>,
}

impl Memory {
    pub fn new(old: PathBuf) -> Memory {
        Memory { store: Arc::new(Store::shared()), old, snapshot: Mutex::new(String::new()) }
    }

    /// Moves facts from `~/.bla/memory` into the shared memory, once.
    fn import_old(&self) {
        for name in ["USER.md", "MEMORY.md"] {
            let file = self.old.join(name);
            let Ok(text) = std::fs::read_to_string(&file) else {
                continue;
            };
            let all_added = text.split("\n§\n").map(str::trim).filter(|e| !e.is_empty()).all(|e| self.store.add(e).is_ok());
            if all_added {
                let _ = std::fs::rename(&file, file.with_extension("md.imported"));
            }
        }
    }
}

impl Plugin for Memory {
    fn name(&self) -> &str {
        "memory"
    }
    fn description(&self) -> &str {
        "the long-term memory shared with the Blablador apps, frozen into each session's prompt"
    }
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        vec![Arc::new(MemoryTool { store: self.store.clone() })]
    }
    fn commands(&self) -> Vec<CommandSpec> {
        vec![CommandSpec { name: "memory".into(), help: "show what Blablador remembers (shared with the apps)".into() }]
    }
    fn session_start(&self, _session: &Session) {
        self.import_old();
        let facts = self.store.list().unwrap_or_default();
        // The newest that fit.
        let mut lines = Vec::new();
        let mut size = 0;
        for f in facts.iter().rev() {
            size += f.text.len() + 3;
            if size > PROMPT_LIMIT {
                break;
            }
            lines.push(format!("- {}", f.text));
        }
        lines.reverse();
        *self.snapshot.lock().unwrap() = if lines.is_empty() { String::new() } else { format!("\n\nWhat you remember:\n{}", lines.join("\n")) };
    }
    fn system_prompt(&self, _session: &Session, sections: &mut Vec<String>) {
        let snapshot = self.snapshot.lock().unwrap();
        sections.push(format!(
            "You have a long-term memory shared with the Blablador apps, carried over between sessions and chats. When you learn something durable about the user or their work, save it with the memory tool.{}",
            snapshot
        ));
    }
    fn command(&self, _ctx: &Ctx, name: &str, _args: &str, _messages: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        if name != "memory" {
            return None;
        }
        Some(self.store.list().map(|facts| {
            let mut out = format!("Shared with {}:\n", self.store.place());
            if facts.is_empty() {
                out.push_str("  (nothing yet)");
            }
            out.push_str(&facts.iter().enumerate().map(|(i, f)| format!("  {}. {}", i + 1, f.text)).collect::<Vec<_>>().join("\n"));
            CommandResult::Output(out.trim_end().to_string())
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_files_round_trip() {
        let dir = std::env::temp_dir().join(format!("bla-mem-{}", crate::util::random_hex(8)));
        let store = Store::Files { dir: dir.clone(), keyring: false };
        apply(&store, &[json!({"action": "add", "content": "Name: Alex"}), json!({"action": "add", "content": "Likes Rust"})]).unwrap();
        apply(&store, &[json!({"action": "patch", "old_text": "Rust", "content": "fast Rust"})]).unwrap();
        let texts: Vec<String> = store.list().unwrap().into_iter().map(|f| f.text).collect();
        assert_eq!(texts, vec!["Name: Alex", "Likes fast Rust"]);
        assert!(!store.add("likes fast rust").unwrap());
        // Encrypted the desktop app's way.
        let raw = std::fs::read(dir.join("memories.json")).unwrap();
        assert!(raw.starts_with(MAGIC) && !raw.windows(4).any(|w| w == b"Alex"));
        apply(&store, &[json!({"action": "remove", "old_text": "Alex"})]).unwrap();
        assert_eq!(store.list().unwrap().len(), 1);
        assert!(apply(&store, &[json!({"action": "remove", "old_text": "nothing"})]).unwrap_err().contains("Nothing was changed"));
        let id = store.list().unwrap()[0].id.clone();
        assert_eq!(id.len(), 36);
        let _ = std::fs::remove_dir_all(dir);
    }
}
