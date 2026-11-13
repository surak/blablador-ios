//! The four tools every session starts with, as in pi: read, write, edit and bash.
//!
//! Files must be read before they are changed, and must not have changed on disk since: the model then
//! never overwrites work it hasn't seen. Writes go to a temporary file first and are renamed into place.

use crate::plugin::{Kind, Plugin, Tool, ToolCtx, ToolOutput};
use crate::util;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

const READ_LINES: usize = 2000;
const READ_BYTES: usize = 50 * 1024;
const BASH_LINES: usize = 2000;
const BASH_BYTES: usize = 50 * 1024;
const MAX_FILE: u64 = 20 * 1024 * 1024;

/// When each file was last read or written by a tool, so edits can check nothing changed in between.
#[derive(Default)]
pub struct Seen(Mutex<HashMap<PathBuf, Option<SystemTime>>>);

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

impl Seen {
    fn record(&self, path: &Path) {
        self.0.lock().unwrap().insert(path.to_path_buf(), modified(path));
    }

    /// An error when an existing file wasn't read first or changed since.
    fn check(&self, path: &Path, shown: &str) -> Result<(), String> {
        if !path.exists() {
            return Ok(());
        }
        match self.0.lock().unwrap().get(path) {
            None => Err(format!("{shown} exists and you haven't read it yet. Read it first, then change it.")),
            Some(when) if *when != modified(path) => Err(format!("{shown} changed on disk since you read it. Read it again first.")),
            Some(_) => Ok(()),
        }
    }
}

fn path_arg(args: &Value) -> Option<&str> {
    args["path"].as_str().or(args["file_path"].as_str()).filter(|p| !p.trim().is_empty())
}

/// Writes through a temporary file in the same folder, keeping the file's permissions.
fn write_atomic(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_file_name(format!(".{}.bla-{}", path.file_name().and_then(|n| n.to_str()).unwrap_or("file"), util::random_hex(6)));
    std::fs::write(&tmp, contents)?;
    if let Ok(meta) = std::fs::metadata(path) {
        let _ = std::fs::set_permissions(&tmp, meta.permissions());
    }
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

pub struct Read {
    seen: Arc<Seen>,
}

impl Tool for Read {
    fn name(&self) -> &str {
        "read"
    }
    fn description(&self) -> &str {
        "Read a text file, with line numbers. Long files come in parts: give offset (first line, from 1) and limit. A folder lists its entries."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "path": {"type": "string", "description": "File or folder, relative to the working directory or absolute"},
            "offset": {"type": "integer", "description": "First line to read, from 1"},
            "limit": {"type": "integer", "description": "How many lines"}
        }, "required": ["path"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Read
    }
    fn subject(&self, args: &Value) -> Option<String> {
        path_arg(args).map(String::from)
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(given) = path_arg(args) else { return ToolOutput::err("Give a path.") };
        let path = util::resolve(ctx.cwd, given);
        if path.is_dir() {
            let mut names: Vec<String> = match std::fs::read_dir(&path) {
                Ok(entries) => entries.flatten().map(|e| e.file_name().to_string_lossy().to_string() + if e.path().is_dir() { "/" } else { "" }).collect(),
                Err(e) => return ToolOutput::err(format!("{given}: {e}")),
            };
            names.sort();
            return ToolOutput::ok(if names.is_empty() { "(empty folder)".to_string() } else { names.join("\n") });
        }
        match std::fs::metadata(&path) {
            Ok(m) if m.len() > MAX_FILE => return ToolOutput::err(format!("{given} is {} MB; read parts of it with bash (head, sed -n).", m.len() / 1_000_000)),
            Err(e) => return ToolOutput::err(format!("{given}: {e}")),
            _ => {}
        }
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => return ToolOutput::err(format!("{given}: {e}")),
        };
        if bytes.iter().take(8000).any(|&b| b == 0) {
            return ToolOutput::err(format!("{given} is a binary file."));
        }
        self.seen.record(&path);
        let text = String::from_utf8_lossy(&bytes);
        let lines: Vec<&str> = text.lines().collect();
        let offset = args["offset"].as_u64().unwrap_or(1).max(1) as usize;
        let limit = args["limit"].as_u64().map(|l| l as usize).unwrap_or(READ_LINES).min(READ_LINES);
        if offset > lines.len().max(1) {
            return ToolOutput::err(format!("{given} has {} lines.", lines.len()));
        }
        let mut out = String::new();
        let mut last = offset - 1;
        for (i, line) in lines.iter().enumerate().skip(offset - 1).take(limit) {
            let numbered = format!("{:>6}\t{}\n", i + 1, util::clip(line, 2000));
            if out.len() + numbered.len() > READ_BYTES {
                break;
            }
            out.push_str(&numbered);
            last = i + 1;
        }
        if last < lines.len() {
            out.push_str(&format!("\n[Lines {offset}–{last} of {}. Read on with offset={}.]", lines.len(), last + 1));
        }
        if out.is_empty() {
            out = "(empty file)".into();
        }
        ToolOutput::ok(out)
    }
}

pub struct Write {
    seen: Arc<Seen>,
}

impl Tool for Write {
    fn name(&self) -> &str {
        "write"
    }
    fn description(&self) -> &str {
        "Write a whole file: create it, or replace an existing file you have read. Folders are created as needed."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "path": {"type": "string"},
            "content": {"type": "string", "description": "The complete new content"}
        }, "required": ["path", "content"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Write
    }
    fn subject(&self, args: &Value) -> Option<String> {
        path_arg(args).map(String::from)
    }
    fn summary(&self, args: &Value) -> String {
        let lines = args["content"].as_str().map(|c| c.lines().count()).unwrap_or(0);
        format!("{} ({lines} lines)", path_arg(args).unwrap_or_default())
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(given) = path_arg(args) else { return ToolOutput::err("Give a path.") };
        let Some(content) = args["content"].as_str() else { return ToolOutput::err("Give the content.") };
        let path = util::resolve(ctx.cwd, given);
        if path.is_dir() {
            return ToolOutput::err(format!("{given} is a folder."));
        }
        if let Err(e) = self.seen.check(&path, given) {
            return ToolOutput::err(e);
        }
        let existed = path.exists();
        if let Err(e) = write_atomic(&path, content.as_bytes()) {
            return ToolOutput::err(format!("{given}: {e}"));
        }
        self.seen.record(&path);
        ToolOutput::ok(format!("{} {given} ({} lines).", if existed { "Replaced" } else { "Created" }, content.lines().count()))
    }
}

pub struct Edit {
    seen: Arc<Seen>,
}

/// Applies exact replacements; each old text must occur exactly once in the file as it is at that point.
pub fn apply_edits(text: &str, edits: &[(String, String)]) -> Result<String, String> {
    let mut out = text.to_string();
    for (n, (old, new)) in edits.iter().enumerate() {
        let which = if edits.len() > 1 { format!("Edit {}: ", n + 1) } else { String::new() };
        if old.is_empty() {
            return Err(format!("{which}old_text is empty."));
        }
        match out.matches(old.as_str()).count() {
            0 => {
                let hint = if out.replace("\r\n", "\n").contains(&old.replace("\r\n", "\n")) || out.contains(old.trim()) {
                    " It almost matches: check whitespace and line endings."
                } else {
                    " Read the file again and copy the text exactly."
                };
                return Err(format!("{which}old_text was not found.{hint}"));
            }
            1 => out = out.replacen(old.as_str(), new, 1),
            count => return Err(format!("{which}old_text occurs {count} times; include more surrounding lines so it is unique.")),
        }
    }
    Ok(out)
}

impl Tool for Edit {
    fn name(&self) -> &str {
        "edit"
    }
    fn description(&self) -> &str {
        "Change a file you have read by replacing exact text. old_text must match the file exactly (whitespace included) and occur once. Several changes to one file go in edits, applied in order."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "path": {"type": "string"},
            "old_text": {"type": "string", "description": "Exact text to replace"},
            "new_text": {"type": "string", "description": "What replaces it"},
            "edits": {"type": "array", "description": "Several replacements instead of old_text/new_text",
                      "items": {"type": "object", "properties": {"old_text": {"type": "string"}, "new_text": {"type": "string"}}, "required": ["old_text", "new_text"]}}
        }, "required": ["path"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Write
    }
    fn subject(&self, args: &Value) -> Option<String> {
        path_arg(args).map(String::from)
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(given) = path_arg(args) else { return ToolOutput::err("Give a path.") };
        let path = util::resolve(ctx.cwd, given);
        let mut edits: Vec<(String, String)> = Vec::new();
        if let Some(list) = args["edits"].as_array() {
            for e in list {
                edits.push((e["old_text"].as_str().unwrap_or_default().into(), e["new_text"].as_str().unwrap_or_default().into()));
            }
        }
        if let Some(old) = args["old_text"].as_str().or(args["old_string"].as_str()) {
            edits.push((old.into(), args["new_text"].as_str().or(args["new_string"].as_str()).unwrap_or_default().into()));
        }
        if edits.is_empty() {
            return ToolOutput::err("Give old_text and new_text, or edits.");
        }
        if !path.exists() {
            return ToolOutput::err(format!("{given} doesn't exist; use write to create it."));
        }
        if let Err(e) = self.seen.check(&path, given) {
            return ToolOutput::err(e);
        }
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) => return ToolOutput::err(format!("{given}: {e}")),
        };
        let changed = match apply_edits(&text, &edits) {
            Ok(t) => t,
            Err(e) => return ToolOutput::err(e),
        };
        if let Err(e) = write_atomic(&path, changed.as_bytes()) {
            return ToolOutput::err(format!("{given}: {e}"));
        }
        self.seen.record(&path);
        let delta = changed.lines().count() as i64 - text.lines().count() as i64;
        ToolOutput::ok(format!("Edited {given}: {} change{}, {}{delta} lines.", edits.len(), if edits.len() == 1 { "" } else { "s" }, if delta >= 0 { "+" } else { "" }))
    }
}

pub struct Bash;

impl Tool for Bash {
    fn name(&self) -> &str {
        "bash"
    }
    fn description(&self) -> &str {
        "Run a shell command in the working directory and get its output (the last 2000 lines or 50 KB) and exit code. Default timeout 120 s, at most 600. Not for interactive programs."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "command": {"type": "string"},
            "timeout": {"type": "integer", "description": "Seconds, default 120"}
        }, "required": ["command"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Exec
    }
    fn subject(&self, args: &Value) -> Option<String> {
        args["command"].as_str().map(String::from)
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(command) = args["command"].as_str().filter(|c| !c.trim().is_empty()) else { return ToolOutput::err("Give a command.") };
        let seconds = args["timeout"].as_u64().unwrap_or(120).clamp(1, 600);
        let (shell, flag) = util::shell();
        let mut cmd = Command::new(shell);
        cmd.arg(flag).arg(command).current_dir(ctx.cwd);
        let done = match util::run(cmd, &[], Duration::from_secs(seconds), ctx.cancel) {
            Ok(d) => d,
            Err(e) => return ToolOutput::err(format!("could not start the shell: {e}")),
        };
        let mut text = String::from_utf8_lossy(&done.stdout).to_string();
        let err = String::from_utf8_lossy(&done.stderr);
        if !err.trim().is_empty() {
            if !text.is_empty() && !text.ends_with('\n') {
                text.push('\n');
            }
            text.push_str(&err);
        }
        let (mut out, cut) = util::truncate_tail(text.trim_end(), BASH_LINES, BASH_BYTES);
        if cut {
            out = format!("[Earlier output cut; showing the end.]\n{out}");
        }
        match done.code {
            Some(0) => ToolOutput::ok(if out.is_empty() { "(no output)".into() } else { out }),
            Some(code) => ToolOutput::err(format!("{out}\n[exit code {code}]").trim_start().to_string()),
            None if done.timed_out => ToolOutput::err(format!("{out}\n[stopped after {seconds} s]").trim_start().to_string()),
            None => ToolOutput::err(format!("{out}\n[stopped by the user]").trim_start().to_string()),
        }
    }
}

pub struct CoreTools {
    seen: Arc<Seen>,
}

impl CoreTools {
    pub fn new() -> CoreTools {
        CoreTools { seen: Arc::new(Seen::default()) }
    }
}

impl Plugin for CoreTools {
    fn name(&self) -> &str {
        "core-tools"
    }
    fn description(&self) -> &str {
        "read, write, edit and bash"
    }
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        vec![
            Arc::new(Read { seen: self.seen.clone() }),
            Arc::new(Write { seen: self.seen.clone() }),
            Arc::new(Edit { seen: self.seen.clone() }),
            Arc::new(Bash),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("bla-tools-{}", util::random_hex(8)));
        std::fs::create_dir_all(&dir).unwrap();
        dir.canonicalize().unwrap()
    }

    #[test]
    fn edits_need_unique_exact_text() {
        assert_eq!(apply_edits("a b a", &[("b".into(), "c".into())]).unwrap(), "a c a");
        assert!(apply_edits("a b a", &[("a".into(), "x".into())]).unwrap_err().contains("2 times"));
        assert!(apply_edits("a b", &[("z".into(), "x".into())]).unwrap_err().contains("not found"));
        assert_eq!(apply_edits("one two", &[("one".into(), "1".into()), ("two".into(), "2".into())]).unwrap(), "1 2");
    }

    #[test]
    fn read_before_write_and_edit() {
        let dir = temp();
        let cancel = AtomicBool::new(false);
        let ctx = ToolCtx { cwd: &dir, cancel: &cancel };
        let plugin = CoreTools::new();
        let tools = plugin.tools();
        let (read, write, edit) = (&tools[0], &tools[1], &tools[2]);
        let created = write.run(&json!({"path": "a/b.txt", "content": "hello\nworld\n"}), &ctx);
        assert!(!created.is_error, "{}", created.content);
        std::fs::write(dir.join("other.txt"), "x").unwrap();
        assert!(edit.run(&json!({"path": "other.txt", "old_text": "x", "new_text": "y"}), &ctx).content.contains("haven't read"));
        assert!(!edit.run(&json!({"path": "a/b.txt", "old_text": "world", "new_text": "there"}), &ctx).is_error);
        assert_eq!(std::fs::read_to_string(dir.join("a/b.txt")).unwrap(), "hello\nthere\n");
        let out = read.run(&json!({"path": "a/b.txt", "offset": 2}), &ctx);
        assert_eq!(out.content, "     2\tthere\n");
        assert!(read.run(&json!({"path": "a"}), &ctx).content.contains("b.txt"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn bash_output_and_exit_code() {
        // The commands are Unix shell; Windows runs cmd.
        if cfg!(windows) {
            return;
        }
        let dir = temp();
        let cancel = AtomicBool::new(false);
        let ctx = ToolCtx { cwd: &dir, cancel: &cancel };
        let ok = Bash.run(&json!({"command": "echo hi; echo oops >&2"}), &ctx);
        assert_eq!(ok.content, "hi\noops");
        let failed = Bash.run(&json!({"command": "exit 3"}), &ctx);
        assert!(failed.is_error && failed.content.contains("exit code 3"));
        std::env::set_var("BLABLADOR_API_KEY", "secret-test");
        let env = Bash.run(&json!({"command": "echo \"[$BLABLADOR_API_KEY]\""}), &ctx);
        assert_eq!(env.content, "[]");
        let slow = Bash.run(&json!({"command": "sleep 5", "timeout": 1}), &ctx);
        assert!(slow.content.contains("stopped after 1 s"));
        // A background job holding the pipes doesn't keep the call waiting.
        let started = std::time::Instant::now();
        let background = Bash.run(&json!({"command": "sleep 30 & echo started"}), &ctx);
        assert!(background.content.contains("started"), "{}", background.content);
        assert!(started.elapsed() < Duration::from_secs(5));
        let _ = std::fs::remove_dir_all(dir);
    }
}
