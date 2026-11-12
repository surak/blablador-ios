//! Long-term memory, as in Hermes: `~/.bla/memory/MEMORY.md` (the agent's notes) and `USER.md` (about the user),
//! entries separated by `§`. Both enter the system prompt as a snapshot at session start; changes during a session
//! are saved at once but show up in the next session, so the prompt stays the same (and cached) all session.
//! Small on purpose: whatever doesn't fit in the limit has to be worth more than what it replaces.

use crate::llm::Message;
use crate::plugin::{CommandResult, CommandSpec, Ctx, Kind, Plugin, Session, Tool, ToolCtx, ToolOutput};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

const SEPARATOR: &str = "\n§\n";
const MEMORY_LIMIT: usize = 2200;
const USER_LIMIT: usize = 1400;

pub struct Store {
    dir: PathBuf,
    lock: Mutex<()>,
}

impl Store {
    fn file(&self, target: &str) -> PathBuf {
        self.dir.join(if target == "user" { "USER.md" } else { "MEMORY.md" })
    }

    fn limit(target: &str) -> usize {
        if target == "user" {
            USER_LIMIT
        } else {
            MEMORY_LIMIT
        }
    }

    pub fn entries(&self, target: &str) -> Vec<String> {
        std::fs::read_to_string(self.file(target))
            .unwrap_or_default()
            .split(SEPARATOR)
            .map(|e| e.trim().to_string())
            .filter(|e| !e.is_empty())
            .collect()
    }

    /// Applies all operations or none; the limit is checked on the result.
    pub fn apply(&self, target: &str, operations: &[Value]) -> Result<String, String> {
        let _guard = self.lock.lock().unwrap();
        let mut entries = self.entries(target);
        for op in operations {
            let content = op["content"].as_str().unwrap_or_default().trim();
            let old = op["old_text"].as_str().unwrap_or_default().trim();
            match op["action"].as_str().unwrap_or_default() {
                "add" => {
                    if content.is_empty() {
                        return Err("add needs content".into());
                    }
                    if content.contains('§') {
                        return Err("entries can't contain §".into());
                    }
                    if !entries.iter().any(|e| e == content) {
                        entries.push(content.to_string());
                    }
                }
                action @ ("patch" | "remove") => {
                    if old.is_empty() {
                        return Err(format!("{action} needs old_text, part of the entry"));
                    }
                    let hits: Vec<usize> = entries.iter().enumerate().filter(|(_, e)| e.contains(old)).map(|(i, _)| i).collect();
                    let index = match hits.as_slice() {
                        [i] => *i,
                        [] => return Err(format!("no entry contains {old:?}")),
                        _ => return Err(format!("{} entries contain {old:?}; give more of the text", hits.len())),
                    };
                    if action == "remove" {
                        entries.remove(index);
                    } else if content.is_empty() || content.contains('§') {
                        return Err("patch needs content (without §)".into());
                    } else {
                        entries[index] = entries[index].replacen(old, content, 1);
                    }
                }
                other => return Err(format!("unknown action {other:?}; use add, patch or remove")),
            }
        }
        let text = entries.join(SEPARATOR);
        let limit = Self::limit(target);
        if text.chars().count() > limit {
            let current = entries.iter().enumerate().map(|(i, e)| format!("{}. {e}", i + 1)).collect::<Vec<_>>().join("\n");
            return Err(format!(
                "That would make {} {} characters, over the limit of {limit}. Nothing was saved. Remove or shorten old entries in the same call. Current entries:\n{current}",
                if target == "user" { "USER.md" } else { "MEMORY.md" },
                text.chars().count()
            ));
        }
        std::fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        crate::secret::write_private(&self.file(target), text.as_bytes()).map_err(|e| e.to_string())?;
        Ok(format!("Saved. {} is at {}/{limit} characters; it takes effect in the next session.", if target == "user" { "USER.md" } else { "MEMORY.md" }, text.chars().count()))
    }
}

struct MemoryTool {
    store: Arc<Store>,
}

impl Tool for MemoryTool {
    fn name(&self) -> &str {
        "memory"
    }
    fn description(&self) -> &str {
        "Save durable facts that every future session should know. target user: who the user is, their preferences and style; \
         target memory: your notes on the environment, conventions and lessons. Make all changes to one target in one call \
         (operations: add with content, patch with old_text and content, remove with old_text); the size limit applies to the \
         result. Skip trivia, task progress and anything easy to find again; procedures belong in skills."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "target": {"type": "string", "enum": ["memory", "user"]},
            "operations": {"type": "array", "items": {"type": "object", "properties": {
                "action": {"type": "string", "enum": ["add", "patch", "remove"]},
                "content": {"type": "string"},
                "old_text": {"type": "string", "description": "Part of the entry to patch or remove"}
            }, "required": ["action"]}}
        }, "required": ["target", "operations"]})
    }
    /// Memory goes into every later prompt, so a change is a write the user approves (accept-edits allows it).
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Write
    }
    fn summary(&self, args: &Value) -> String {
        let ops: Vec<String> = args["operations"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|o| format!("{} {}", o["action"].as_str().unwrap_or("?"), crate::util::clip(o["content"].as_str().or(o["old_text"].as_str()).unwrap_or_default(), 60)))
            .collect();
        format!("{}: {}", args["target"].as_str().unwrap_or("memory"), ops.join("; "))
    }
    fn run(&self, args: &Value, _ctx: &ToolCtx) -> ToolOutput {
        let target = match args["target"].as_str() {
            Some("user") => "user",
            _ => "memory",
        };
        // Accept a single operation at the top level too: models drift.
        let operations = match args["operations"].as_array() {
            Some(list) => list.clone(),
            None if args["action"].is_string() => vec![args.clone()],
            None => return ToolOutput::err("Give operations."),
        };
        match self.store.apply(target, &operations) {
            Ok(text) => ToolOutput::ok(text),
            Err(e) => ToolOutput::err(e),
        }
    }
}

pub struct Memory {
    store: Arc<Store>,
    snapshot: Mutex<String>,
}

impl Memory {
    pub fn new(dir: PathBuf) -> Memory {
        Memory { store: Arc::new(Store { dir, lock: Mutex::new(()) }), snapshot: Mutex::new(String::new()) }
    }
}

impl Plugin for Memory {
    fn name(&self) -> &str {
        "memory"
    }
    fn description(&self) -> &str {
        "MEMORY.md and USER.md, saved by the agent and frozen into each session's prompt"
    }
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        vec![Arc::new(MemoryTool { store: self.store.clone() })]
    }
    fn commands(&self) -> Vec<CommandSpec> {
        vec![CommandSpec { name: "memory".into(), help: format!("show what bla remembers ({})", self.store.dir.display()) }]
    }
    fn session_start(&self, _session: &Session) {
        let mut text = String::new();
        for (target, title) in [("user", "About the user"), ("memory", "Your notes from earlier sessions")] {
            let entries = self.store.entries(target);
            if !entries.is_empty() {
                text.push_str(&format!("\n\n{title}:\n{}", entries.iter().map(|e| format!("- {e}")).collect::<Vec<_>>().join("\n")));
            }
        }
        *self.snapshot.lock().unwrap() = text;
    }
    fn system_prompt(&self, _session: &Session, sections: &mut Vec<String>) {
        let snapshot = self.snapshot.lock().unwrap();
        sections.push(format!(
            "You have a small long-term memory that carries over between sessions. When you learn something durable about the user or the environment, save it with the memory tool.{}",
            snapshot
        ));
    }
    fn command(&self, _ctx: &Ctx, name: &str, _args: &str, _messages: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        if name != "memory" {
            return None;
        }
        let mut out = String::new();
        for target in ["user", "memory"] {
            let entries = self.store.entries(target);
            out.push_str(&format!("{} ({}):\n", if target == "user" { "USER.md" } else { "MEMORY.md" }, self.store.file(target).display()));
            if entries.is_empty() {
                out.push_str("  (empty)\n");
            }
            for e in entries {
                out.push_str(&format!("  - {e}\n"));
            }
        }
        Some(Ok(CommandResult::Output(out.trim_end().to_string())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batches_are_atomic_and_limited() {
        let dir = std::env::temp_dir().join(format!("bla-mem-{}", crate::util::random_hex(8)));
        let store = Store { dir: dir.clone(), lock: Mutex::new(()) };
        store.apply("user", &[json!({"action": "add", "content": "Name: Alex"}), json!({"action": "add", "content": "Likes Rust"})]).unwrap();
        store.apply("user", &[json!({"action": "patch", "old_text": "Rust", "content": "fast Rust"})]).unwrap();
        assert_eq!(store.entries("user"), vec!["Name: Alex", "Likes fast Rust"]);
        let big = "x".repeat(USER_LIMIT);
        assert!(store.apply("user", &[json!({"action": "add", "content": big})]).unwrap_err().contains("Nothing was saved"));
        assert_eq!(store.entries("user").len(), 2);
        store.apply("user", &[json!({"action": "remove", "old_text": "Alex"}), json!({"action": "add", "content": "Works at FZJ"})]).unwrap();
        assert_eq!(store.entries("user"), vec!["Likes fast Rust", "Works at FZJ"]);
        assert!(store.apply("user", &[json!({"action": "remove", "old_text": "nothing"})]).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }
}
