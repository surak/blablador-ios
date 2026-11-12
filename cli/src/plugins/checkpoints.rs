//! Checkpoints, as in Hermes and Claude Code: before a turn's first change to a file, its old content is kept,
//! so `/undo` puts back every file the last turn changed (and removes the ones it created).
//! Changes made by shell commands aren't covered; that's what git is for.

use crate::llm::Message;
use crate::plugin::{CommandResult, CommandSpec, Ctx, Decision, Event, Kind, Plugin, Session, Tool};
use crate::util;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Mutex;

const MAX_SNAPSHOT: u64 = 10 * 1024 * 1024;

#[derive(Default)]
struct Turn {
    number: usize,
    /// The file and what it held before; None when the turn created it.
    files: Vec<(PathBuf, Option<Vec<u8>>)>,
}

#[derive(Default)]
pub struct Checkpoints {
    turns: Mutex<Vec<Turn>>,
    /// Taken before a call; kept only when the call succeeds, so refused or failed calls leave nothing to undo.
    pending: Mutex<Vec<(PathBuf, Option<Vec<u8>>)>>,
}

impl Checkpoints {
    pub fn undo(&self) -> Result<String, String> {
        let mut turns = self.turns.lock().unwrap();
        while let Some(turn) = turns.pop() {
            if turn.files.is_empty() {
                continue;
            }
            let mut restored = Vec::new();
            for (path, before) in turn.files.iter().rev() {
                let result = match before {
                    Some(bytes) => std::fs::write(path, bytes),
                    None => std::fs::remove_file(path).or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) }),
                };
                match result {
                    Ok(()) => restored.push(format!("  {} {}", if before.is_some() { "restored" } else { "removed" }, path.display())),
                    Err(e) => restored.push(format!("  failed {}: {e}", path.display())),
                }
            }
            return Ok(format!("Undid turn {}:\n{}", turn.number, restored.join("\n")));
        }
        Err("Nothing to undo: no files were changed by edit or write.".into())
    }
}

impl Plugin for Checkpoints {
    fn name(&self) -> &str {
        "checkpoints"
    }
    fn description(&self) -> &str {
        "Keeps files as they were before each turn; /undo restores them"
    }
    fn commands(&self) -> Vec<CommandSpec> {
        vec![CommandSpec { name: "undo".into(), help: "put back the files the last turn changed".into() }]
    }
    fn event(&self, _session: &Session, event: &Event) {
        if let Event::TurnStart { turn } = event {
            self.pending.lock().unwrap().clear();
            self.turns.lock().unwrap().push(Turn { number: *turn, files: Vec::new() });
        }
    }
    fn pre_tool(&self, session: &Session, tool: &dyn Tool, args: &mut Value) -> Decision {
        if tool.kind(args) != Kind::Write {
            return Decision::Allow;
        }
        let Some(subject) = tool.subject(args) else { return Decision::Allow };
        let path = util::resolve(session.cwd, &subject);
        let before = match std::fs::metadata(&path) {
            Ok(m) if m.is_file() && m.len() <= MAX_SNAPSHOT => std::fs::read(&path).ok(),
            Ok(_) => return Decision::Allow,
            Err(_) => None,
        };
        let mut pending = self.pending.lock().unwrap();
        pending.retain(|(p, _)| p != &path);
        pending.push((path, before));
        Decision::Allow
    }
    fn post_tool(&self, session: &Session, tool: &dyn Tool, args: &Value, output: &mut crate::plugin::ToolOutput) {
        let Some(subject) = tool.subject(args) else { return };
        let path = util::resolve(session.cwd, &subject);
        let Some(index) = self.pending.lock().unwrap().iter().position(|(p, _)| p == &path) else { return };
        let (path, before) = self.pending.lock().unwrap().remove(index);
        if output.is_error {
            return;
        }
        let mut turns = self.turns.lock().unwrap();
        if turns.is_empty() {
            turns.push(Turn::default());
        }
        let turn = turns.last_mut().unwrap();
        if !turn.files.iter().any(|(p, _)| p == &path) {
            turn.files.push((path, before));
        }
    }
    fn command(&self, _ctx: &Ctx, name: &str, _args: &str, _messages: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        (name == "undo").then(|| self.undo().map(CommandResult::Output))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugins::core_tools::CoreTools;
    use serde_json::json;

    #[test]
    fn undoes_a_turn() {
        let dir = std::env::temp_dir().join(format!("bla-cp-{}", util::random_hex(8)));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.txt"), "old").unwrap();
        let session = Session { id: "s", cwd: &dir, interactive: false };
        let cp = Checkpoints::default();
        let tools = CoreTools::new().tools();
        let write = tools.iter().find(|t| t.name() == "write").unwrap();
        cp.event(&session, &Event::TurnStart { turn: 1 });
        let ok = || crate::plugin::ToolOutput::ok("done");
        cp.pre_tool(&session, write.as_ref(), &mut json!({"path": "a.txt"}));
        std::fs::write(dir.join("a.txt"), "new").unwrap();
        cp.post_tool(&session, write.as_ref(), &json!({"path": "a.txt"}), &mut ok());
        cp.pre_tool(&session, write.as_ref(), &mut json!({"path": "b.txt"}));
        std::fs::write(dir.join("b.txt"), "created").unwrap();
        cp.post_tool(&session, write.as_ref(), &json!({"path": "b.txt"}), &mut ok());
        // A refused call leaves nothing to undo.
        cp.pre_tool(&session, write.as_ref(), &mut json!({"path": "c.txt"}));
        cp.post_tool(&session, write.as_ref(), &json!({"path": "c.txt"}), &mut crate::plugin::ToolOutput::err("Not allowed"));
        cp.event(&session, &Event::TurnStart { turn: 2 });
        assert!(cp.undo().unwrap().contains("turn 1"));
        assert_eq!(std::fs::read_to_string(dir.join("a.txt")).unwrap(), "old");
        assert!(!dir.join("b.txt").exists());
        assert!(cp.undo().is_err());
        let _ = std::fs::remove_dir_all(dir);
    }
}
