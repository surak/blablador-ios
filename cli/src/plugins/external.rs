//! External plugins: programs in any language that talk JSON-RPC 2.0, one message per line, on stdin/stdout.
//! They run as separate processes (never loaded into bla), without the API key in their environment, and each
//! call has a time limit. See `cli/PLUGINS.md` for the protocol.
//!
//! Declared in settings (`"plugins": {"external": [{"name": "x", "command": ["python3", "x.py"]}]}`) or as a
//! folder with a `plugin.json` in `~/.bla/plugins` (or the project's `.bla/plugins` when it is trusted).

use crate::llm::Message;
use crate::plugin::{CommandResult, CommandSpec, Ctx, Decision, Kind, Plugin, Session, Tool, ToolCtx, ToolOutput};
use crate::util;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const PROTOCOL: u32 = 1;
const HOOK_TIMEOUT: Duration = Duration::from_secs(30);
const TOOL_TIMEOUT: Duration = Duration::from_secs(600);

struct Process {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    next_id: u64,
}

pub struct Connection {
    name: String,
    process: Mutex<Option<Process>>,
}

impl Connection {
    pub fn start(name: &str, command: &[String], cwd: &Path) -> Result<Connection, String> {
        let (program, args) = command.split_first().ok_or("empty command")?;
        let mut cmd = Command::new(program);
        cmd.args(args).current_dir(cwd).stdin(Stdio::piped()).stdout(Stdio::piped());
        cmd.stderr(if std::env::var_os("BLA_PLUGIN_DEBUG").is_some() { Stdio::inherit() } else { Stdio::null() });
        for key in util::SECRET_ENV {
            cmd.env_remove(key);
        }
        let mut child = cmd.spawn().map_err(|e| format!("{program}: {e}"))?;
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = child.stdout.take().ok_or("no stdout")?;
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        Ok(Connection { name: name.into(), process: Mutex::new(Some(Process { child, stdin, lines: rx, next_id: 1 })) })
    }

    /// Sends a request and waits for its answer. A plugin that times out or breaks is stopped.
    pub fn call(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, String> {
        self.call_cancellable(method, params, timeout, None)
    }

    /// Like `call`, but gives up when `cancel` is set (Ctrl-C); a late answer is then ignored.
    pub fn call_cancellable(&self, method: &str, params: Value, timeout: Duration, cancel: Option<&std::sync::atomic::AtomicBool>) -> Result<Value, String> {
        let mut guard = self.process.lock().unwrap();
        let Some(p) = guard.as_mut() else { return Err(format!("plugin {} has stopped", self.name)) };
        let id = p.next_id;
        p.next_id += 1;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        if writeln!(p.stdin, "{request}").and_then(|_| p.stdin.flush()).is_err() {
            let _ = p.child.kill();
            let _ = p.child.wait();
            *guard = None;
            return Err(format!("plugin {} has stopped", self.name));
        }
        let deadline = std::time::Instant::now() + timeout;
        loop {
            if cancel.is_some_and(|c| c.load(std::sync::atomic::Ordering::Relaxed)) {
                return Err("stopped by the user".into());
            }
            let left = deadline.saturating_duration_since(std::time::Instant::now()).min(Duration::from_millis(100));
            match p.lines.recv_timeout(left) {
                Ok(line) => {
                    let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                    if message["id"] != json!(id) {
                        continue;
                    }
                    if let Some(error) = message.get("error").filter(|e| !e.is_null()) {
                        return Err(error["message"].as_str().unwrap_or("plugin error").to_string());
                    }
                    return Ok(message["result"].clone());
                }
                Err(RecvTimeoutError::Timeout) if std::time::Instant::now() < deadline => continue,
                Err(RecvTimeoutError::Timeout) => {
                    let _ = p.child.kill();
                    let _ = p.child.wait();
                    *guard = None;
                    return Err(format!("plugin {} didn't answer {method} within {} s and was stopped", self.name, timeout.as_secs()));
                }
                Err(RecvTimeoutError::Disconnected) => {
                    let _ = p.child.kill();
                    let _ = p.child.wait();
                    *guard = None;
                    return Err(format!("plugin {} has stopped", self.name));
                }
            }
        }
    }

    pub fn notify(&self, method: &str, params: Value) {
        if let Some(p) = self.process.lock().unwrap().as_mut() {
            let _ = writeln!(p.stdin, "{}", json!({"jsonrpc": "2.0", "method": method, "params": params}));
            let _ = p.stdin.flush();
        }
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        if let Some(mut p) = self.process.lock().unwrap().take() {
            let _ = p.child.kill();
            let _ = p.child.wait();
        }
    }
}

struct ExternalTool {
    conn: Arc<Connection>,
    name: String,
    description: String,
    parameters: Value,
    kind: Kind,
}

impl Tool for ExternalTool {
    fn name(&self) -> &str {
        &self.name
    }
    fn description(&self) -> &str {
        &self.description
    }
    fn parameters(&self) -> Value {
        self.parameters.clone()
    }
    fn kind(&self, _args: &Value) -> Kind {
        self.kind
    }
    fn summary(&self, args: &Value) -> String {
        util::clip(&args.to_string(), 160).to_string()
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        match self.conn.call_cancellable("tool", json!({"name": self.name, "arguments": args, "cwd": ctx.cwd}), TOOL_TIMEOUT, Some(ctx.cancel)) {
            Ok(r) => ToolOutput { content: r["content"].as_str().unwrap_or_default().to_string(), is_error: r["is_error"].as_bool().unwrap_or(false) },
            Err(e) => ToolOutput::err(e),
        }
    }
}

pub struct External {
    name: String,
    description: String,
    conn: Arc<Connection>,
    hooks: Vec<String>,
    tools: Vec<Arc<dyn Tool>>,
    commands: Vec<CommandSpec>,
}

impl External {
    pub fn start(name: &str, description: &str, command: &[String], cwd: &Path) -> Result<External, String> {
        let conn = Arc::new(Connection::start(name, command, cwd)?);
        let info = conn.call("initialize", json!({"protocol": PROTOCOL, "bla": env!("CARGO_PKG_VERSION"), "cwd": cwd}), HOOK_TIMEOUT)?;
        let hooks = info["hooks"].as_array().into_iter().flatten().filter_map(|h| h.as_str().map(String::from)).collect();
        let tools = info["tools"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|t| {
                let name = t["name"].as_str()?.to_string();
                let kind = match t["kind"].as_str().unwrap_or("exec") {
                    "read" => Kind::Read,
                    "write" => Kind::Write,
                    "internal" => Kind::Internal,
                    _ => Kind::Exec,
                };
                Some(Arc::new(ExternalTool {
                    conn: conn.clone(),
                    name,
                    description: t["description"].as_str().unwrap_or_default().to_string(),
                    parameters: t.get("parameters").cloned().unwrap_or_else(|| json!({"type": "object", "properties": {}})),
                    kind,
                }) as Arc<dyn Tool>)
            })
            .collect();
        let commands = info["commands"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| Some(CommandSpec { name: c["name"].as_str()?.to_string(), help: c["help"].as_str().unwrap_or_default().to_string() }))
            .collect();
        let description = info["description"].as_str().map(String::from).unwrap_or_else(|| description.to_string());
        Ok(External { name: name.into(), description, conn, hooks, tools, commands })
    }

    fn wants(&self, hook: &str) -> bool {
        self.hooks.iter().any(|h| h == hook)
    }
}

impl Plugin for External {
    fn name(&self) -> &str {
        &self.name
    }
    fn description(&self) -> &str {
        &self.description
    }
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        self.tools.clone()
    }
    fn commands(&self) -> Vec<CommandSpec> {
        self.commands.iter().map(|c| CommandSpec { name: c.name.clone(), help: c.help.clone() }).collect()
    }
    fn session_start(&self, session: &Session) {
        if self.wants("session_start") {
            self.conn.notify("session_start", json!({"session_id": session.id, "cwd": session.cwd}));
        }
    }
    fn system_prompt(&self, session: &Session, sections: &mut Vec<String>) {
        if self.wants("system_prompt") {
            if let Ok(r) = self.conn.call("system_prompt", json!({"session_id": session.id, "cwd": session.cwd}), HOOK_TIMEOUT) {
                if let Some(text) = r["text"].as_str() {
                    sections.push(text.to_string());
                }
            }
        }
    }
    fn user_prompt(&self, session: &Session, text: &mut String) -> Result<(), String> {
        if !self.wants("user_prompt") {
            return Ok(());
        }
        let r = self.conn.call("user_prompt", json!({"session_id": session.id, "text": text}), HOOK_TIMEOUT)?;
        if let Some(reason) = r["block"].as_str() {
            return Err(format!("{} refused the message: {reason}", self.name));
        }
        if let Some(new) = r["text"].as_str() {
            *text = new.to_string();
        }
        Ok(())
    }
    fn pre_tool(&self, session: &Session, tool: &dyn Tool, args: &mut Value) -> Decision {
        if !self.wants("pre_tool") {
            return Decision::Allow;
        }
        let kind = format!("{:?}", tool.kind(args)).to_lowercase();
        match self.conn.call("pre_tool", json!({"session_id": session.id, "tool": tool.name(), "kind": kind, "arguments": args}), HOOK_TIMEOUT) {
            Ok(r) => {
                if let Some(new) = r.get("arguments").filter(|a| a.is_object()) {
                    *args = new.clone();
                }
                let reason = r["reason"].as_str().unwrap_or_default().to_string();
                match r["decision"].as_str() {
                    Some("deny") => Decision::Deny(if reason.is_empty() { format!("{} denied it", self.name) } else { reason }),
                    Some("ask") => Decision::Ask(reason),
                    _ => Decision::Allow,
                }
            }
            // A policy plugin that fails must not let calls through unseen.
            Err(e) => Decision::Ask(e),
        }
    }
    fn post_tool(&self, session: &Session, tool: &dyn Tool, args: &Value, output: &mut ToolOutput) {
        if !self.wants("post_tool") {
            return;
        }
        let params = json!({"session_id": session.id, "tool": tool.name(), "arguments": args, "content": output.content, "is_error": output.is_error});
        if let Ok(r) = self.conn.call("post_tool", params, HOOK_TIMEOUT) {
            if let Some(content) = r["content"].as_str() {
                output.content = content.to_string();
            }
            if let Some(is_error) = r["is_error"].as_bool() {
                output.is_error = is_error;
            }
        }
    }
    fn turn_end(&self, session: &Session, messages: &[Message]) -> Option<String> {
        if !self.wants("turn_end") {
            return None;
        }
        let last = messages.last().map(|m| m.content.as_str()).unwrap_or_default();
        let r = self.conn.call("turn_end", json!({"session_id": session.id, "last_message": last}), HOOK_TIMEOUT).ok()?;
        r["continue"].as_str().map(String::from)
    }
    fn command(&self, _ctx: &Ctx, name: &str, args: &str, _messages: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        if !self.commands.iter().any(|c| c.name == name) {
            return None;
        }
        Some(self.conn.call("command", json!({"name": name, "args": args}), TOOL_TIMEOUT).map(|r| match r["prompt"].as_str() {
            Some(p) => CommandResult::Prompt(p.to_string()),
            None => CommandResult::Output(r["output"].as_str().unwrap_or_default().to_string()),
        }))
    }
    fn session_end(&self, session: &Session) {
        if self.wants("session_end") {
            self.conn.notify("session_end", json!({"session_id": session.id}));
        }
    }
}

/// Plugins declared as folders with a plugin.json: {"name", "description", "command": [...]}; the command runs in the folder.
pub fn manifests(dir: &Path) -> Vec<(String, String, Vec<String>, PathBuf)> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else { return out };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let folder = entry.path();
        let Ok(text) = std::fs::read_to_string(folder.join("plugin.json")) else { continue };
        let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
        let name = v["name"].as_str().map(String::from).unwrap_or_else(|| entry.file_name().to_string_lossy().to_string());
        let command: Vec<String> = v["command"].as_array().into_iter().flatten().filter_map(|c| c.as_str().map(String::from)).collect();
        if !command.is_empty() {
            out.push((name, v["description"].as_str().unwrap_or_default().to_string(), command, folder));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugins::core_tools::CoreTools;
    use std::sync::atomic::AtomicBool;

    #[test]
    fn talks_to_a_plugin() {
        if cfg!(windows) || std::process::Command::new("python3").arg("--version").output().is_err() {
            return;
        }
        let example = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/plugins/guard/guard.py");
        let cwd = std::env::temp_dir();
        let plugin = External::start("guard", "", &["python3".into(), example.display().to_string()], &cwd).unwrap();
        let session = Session { id: "s", cwd: &cwd, interactive: false };
        let tools = plugin.tools();
        let count = tools.iter().find(|t| t.name() == "word_count").unwrap();
        let cancel = AtomicBool::new(false);
        let out = count.run(&json!({"text": "one two three"}), &ToolCtx { cwd: &cwd, cancel: &cancel });
        assert_eq!(out.content, "3 words");
        let core = CoreTools::new().tools();
        let bash = core.iter().find(|t| t.name() == "bash").unwrap();
        assert!(matches!(plugin.pre_tool(&session, bash.as_ref(), &mut json!({"command": "git push --force"})), Decision::Deny(_)));
        assert_eq!(plugin.pre_tool(&session, bash.as_ref(), &mut json!({"command": "git push"})), Decision::Allow);
        let mut sections = Vec::new();
        plugin.system_prompt(&session, &mut sections);
        assert_eq!(sections.len(), 1);
    }
}
