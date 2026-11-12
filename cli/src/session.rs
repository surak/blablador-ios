//! Sessions are append-only JSON lines in `~/.bla/sessions`, one file per session, readable only by the user.
//! Whatever the model saw is in the log, so a session can always be resumed exactly:
//! `{"type":"meta",…}`, then `{"type":"message","message":…}` per message, and `{"type":"replace","messages":[…]}`
//! when a plugin rewrote the history (compaction).

use crate::llm::Message;
use crate::util;
use serde_json::{json, Value};
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

pub struct Session {
    pub id: String,
    pub cwd: PathBuf,
    pub messages: Vec<Message>,
    path: PathBuf,
    file: Option<File>,
    model: String,
}

pub struct Summary {
    pub id: String,
    pub cwd: String,
    pub title: String,
    pub modified: SystemTime,
}

pub fn dir() -> PathBuf {
    util::bla_home().join("sessions")
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

impl Session {
    pub fn new(cwd: &Path, model: &str) -> Session {
        let (y, mo, d, h, mi, s) = util::utc_now();
        let id = format!("{y:04}{mo:02}{d:02}-{h:02}{mi:02}{s:02}-{}", util::random_hex(6));
        Session { path: dir().join(format!("{id}.jsonl")), id, cwd: cwd.to_path_buf(), messages: Vec::new(), file: None, model: model.into() }
    }

    pub fn open(id: &str) -> Result<Session, String> {
        if !valid_id(id) {
            return Err(format!("no session {id}"));
        }
        let path = dir().join(format!("{id}.jsonl"));
        let file = File::open(&path).map_err(|_| format!("no session {id}"))?;
        let mut session = Session { id: id.into(), cwd: PathBuf::from("."), messages: Vec::new(), path, file: None, model: String::new() };
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            let Ok(entry) = serde_json::from_str::<Value>(&line) else { continue };
            match entry["type"].as_str() {
                Some("meta") => {
                    session.cwd = PathBuf::from(entry["cwd"].as_str().unwrap_or("."));
                    session.model = entry["model"].as_str().unwrap_or_default().into();
                }
                Some("message") => {
                    if let Ok(m) = serde_json::from_value(entry["message"].clone()) {
                        session.messages.push(m);
                    }
                }
                Some("replace") => {
                    if let Ok(list) = serde_json::from_value(entry["messages"].clone()) {
                        session.messages = list;
                    }
                }
                _ => {}
            }
        }
        session.repair();
        Ok(session)
    }

    /// A session that ended mid-tool (a crash, a kill) has calls without results; answer them so the history is valid.
    fn repair(&mut self) {
        let answered: std::collections::HashSet<String> = self.messages.iter().filter_map(|m| m.tool_call_id.clone()).collect();
        if self.messages.iter().all(|m| m.tool_calls.iter().all(|c| answered.contains(&c.id))) {
            return;
        }
        // Each missing result goes right after the results its message did get.
        let mut fixed = Vec::with_capacity(self.messages.len());
        let mut owed: Vec<String> = Vec::new();
        for m in std::mem::take(&mut self.messages) {
            if m.role != "tool" {
                for id in owed.drain(..) {
                    fixed.push(Message::tool(&id, "Interrupted: bla stopped before this tool finished."));
                }
            }
            owed.extend(m.tool_calls.iter().map(|c| c.id.clone()).filter(|id| !answered.contains(id)));
            fixed.push(m);
        }
        for id in owed {
            fixed.push(Message::tool(&id, "Interrupted: bla stopped before this tool finished."));
        }
        self.replace(fixed);
    }

    fn append(&mut self, entry: Value) {
        if self.file.is_none() {
            let _ = std::fs::create_dir_all(dir());
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(dir(), std::fs::Permissions::from_mode(0o700));
            }
            let fresh = !self.path.exists();
            let mut options = std::fs::OpenOptions::new();
            options.create(true).append(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            self.file = options.open(&self.path).ok();
            if fresh {
                let meta = json!({"type": "meta", "id": self.id, "cwd": self.cwd, "model": self.model,
                                  "created": util::timestamp(), "version": env!("CARGO_PKG_VERSION")});
                if let Some(f) = self.file.as_mut() {
                    let _ = writeln!(f, "{meta}");
                }
            }
        }
        if let Some(f) = self.file.as_mut() {
            let _ = writeln!(f, "{entry}");
        }
    }

    pub fn push(&mut self, message: Message) {
        self.append(json!({"type": "message", "message": message}));
        self.messages.push(message);
    }

    /// Records a rewritten history (after compaction).
    pub fn replace(&mut self, messages: Vec<Message>) {
        self.append(json!({"type": "replace", "messages": messages}));
        self.messages = messages;
    }

    pub fn list() -> Vec<Summary> {
        let mut out = Vec::new();
        let Ok(entries) = std::fs::read_dir(dir()) else { return out };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let Some(id) = path.file_stem().and_then(|s| s.to_str()).map(String::from) else { continue };
            let modified = entry.metadata().and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
            let (mut cwd, mut title) = (String::new(), String::new());
            if let Ok(file) = File::open(&path) {
                for line in BufReader::new(file).lines().map_while(Result::ok).take(50) {
                    let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                    if v["type"] == "meta" {
                        cwd = v["cwd"].as_str().unwrap_or_default().into();
                    } else if v["type"] == "message" && v["message"]["role"] == "user" {
                        title = v["message"]["content"].as_str().unwrap_or_default().lines().next().unwrap_or_default().chars().take(70).collect();
                        break;
                    }
                }
            }
            out.push(Summary { id, cwd, title, modified });
        }
        out.sort_by(|a, b| b.modified.cmp(&a.modified));
        out
    }

    /// The most recent session started in `cwd`.
    pub fn last_in(cwd: &Path) -> Option<String> {
        Session::list().into_iter().find(|s| Path::new(&s.cwd) == cwd).map(|s| s.id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_replaces() {
        let mut s = Session::new(Path::new("/tmp/project"), "m");
        s.push(Message::user("hello"));
        s.push(Message { role: "assistant".into(), content: "hi".into(), reasoning: "thinking".into(), ..Default::default() });
        s.replace(vec![Message::user("summary")]);
        s.push(Message { role: "assistant".into(), tool_calls: vec![crate::llm::ToolCall { id: "c9".into(), name: "bash".into(), arguments: "{}".into() }], ..Default::default() });
        s.push(Message::user("again"));
        let back = Session::open(&s.id).unwrap();
        assert_eq!(back.cwd, PathBuf::from("/tmp/project"));
        // The unanswered call got its answer right after the call.
        assert_eq!(back.messages.len(), 4);
        assert_eq!(back.messages[0], Message::user("summary"));
        assert_eq!(back.messages[2].tool_call_id.as_deref(), Some("c9"));
        assert_eq!(back.messages[3], Message::user("again"));
        assert!(Session::open("../etc/passwd").is_err());
    }
}
