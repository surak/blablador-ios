//! Subagents: the `task` tool runs bla itself as a child process with its own, fresh context, and hands back only
//! the child's final answer. Explore subagents run read-only (plan mode) and several run at once; general ones may
//! edit files (accept-edits mode) and go through the parent's permission check first. A child can't ask the user
//! anything: its stdin is closed and --json mode declines whatever would ask.

use crate::plugin::{Kind, Plugin, Session, Tool, ToolCtx, ToolOutput};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const TIMEOUT: Duration = Duration::from_secs(20 * 60);

const GUIDE: &str = "Subagents: the task tool hands a self-contained job to a fresh copy of you with its own context and returns only its answer. \
Use kind explore (read-only; several task calls in one reply run at the same time) for broad searches across many files, questions about \
unfamiliar parts of a codebase, and independent questions you can ask in parallel; your own context then stays small. Use kind general \
for a separate piece of work that edits files. Write the prompt as a full brief: the goal, what you already know, where to look, and what \
to report back. Don't use it for a single file read or a quick command.";

/// What a child's JSON lines add up to.
#[derive(Debug, Default, PartialEq)]
pub struct Outcome {
    /// The text of its last reply.
    pub answer: String,
    pub tools: usize,
    pub tokens: u64,
    pub errors: Vec<String>,
}

impl Outcome {
    /// Takes one JSON line of `bla --json`; `reply` collects the reply being written.
    pub fn take(&mut self, line: &str, reply: &mut String) {
        let Ok(v) = serde_json::from_str::<Value>(line) else { return };
        match v["type"].as_str().unwrap_or_default() {
            "text" => reply.push_str(v["text"].as_str().unwrap_or_default()),
            "reply_end" => {
                if !reply.trim().is_empty() {
                    self.answer = std::mem::take(reply);
                }
                reply.clear();
            }
            "tool_start" => self.tools += 1,
            "usage" => self.tokens += v["input"].as_u64().unwrap_or(0) + v["output"].as_u64().unwrap_or(0),
            "error" => self.errors.push(v["text"].as_str().unwrap_or_default().to_string()),
            _ => {}
        }
    }

    pub fn tally(&self) -> String {
        let tokens = if self.tokens >= 1000 { format!("{:.1}k", self.tokens as f64 / 1000.0) } else { self.tokens.to_string() };
        format!("({} tool call{}, {tokens} tokens)", self.tools, if self.tools == 1 { "" } else { "s" })
    }
}

#[cfg(test)]
fn parse(lines: &str) -> Outcome {
    let mut outcome = Outcome::default();
    let mut reply = String::new();
    for line in lines.lines() {
        outcome.take(line, &mut reply);
    }
    if !reply.trim().is_empty() {
        outcome.answer = reply;
    }
    outcome
}

struct TaskTool {
    model: String,
}

impl Tool for TaskTool {
    fn name(&self) -> &str {
        "task"
    }
    fn description(&self) -> &str {
        "Run a subagent: a fresh copy of you with its own context does a self-contained job and returns only its final answer. \
         kind explore is read-only and several run in parallel; kind general may edit files."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "description": {"type": "string", "description": "A few words on what it does, shown to the user"},
            "prompt": {"type": "string", "description": "The full brief: goal, context, where to look, what to report"},
            "kind": {"type": "string", "enum": ["explore", "general"]}
        }, "required": ["description", "prompt"]})
    }
    fn kind(&self, args: &Value) -> Kind {
        if args["kind"].as_str() == Some("general") {
            Kind::Write
        } else {
            Kind::Read
        }
    }
    fn subject(&self, args: &Value) -> Option<String> {
        args["description"].as_str().map(String::from)
    }
    fn summary(&self, args: &Value) -> String {
        format!("{} ({})", args["description"].as_str().unwrap_or_default(), args["kind"].as_str().unwrap_or("explore"))
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(prompt) = args["prompt"].as_str().filter(|p| !p.trim().is_empty()) else { return ToolOutput::err("Give a prompt.") };
        let mode = if args["kind"].as_str() == Some("general") { "accept-edits" } else { "plan" };
        let Ok(me) = std::env::current_exe() else { return ToolOutput::err("Can't find bla's own program.") };
        let mut child = match Command::new(me)
            .args(["--json", "--mode", mode, "--no-plugin", "agents", "-m", &self.model, "--", prompt])
            .current_dir(ctx.cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => return ToolOutput::err(format!("could not start the subagent: {e}")),
        };
        let outcome = Arc::new(Mutex::new((Outcome::default(), String::new())));
        let stdout = child.stdout.take();
        let shared = outcome.clone();
        let reader = std::thread::spawn(move || {
            if let Some(out) = stdout {
                for line in BufReader::new(out).lines().map_while(Result::ok) {
                    let mut guard = shared.lock().unwrap();
                    let (o, reply) = &mut *guard;
                    o.take(&line, reply);
                }
            }
        });
        let stderr = child.stderr.take();
        let errors = std::thread::spawn(move || {
            let mut text = String::new();
            if let Some(mut err) = stderr {
                let _ = std::io::Read::read_to_string(&mut err, &mut text);
            }
            text
        });
        let start = Instant::now();
        let stopped = loop {
            match child.try_wait() {
                Ok(Some(_)) => break None,
                Ok(None) => {}
                Err(e) => break Some(e.to_string()),
            }
            if ctx.cancel.load(Ordering::Relaxed) || start.elapsed() > TIMEOUT {
                let _ = child.kill();
                let _ = child.wait();
                break Some(if start.elapsed() > TIMEOUT { "stopped after 20 minutes".to_string() } else { "stopped by the user".to_string() });
            }
            std::thread::sleep(Duration::from_millis(50));
        };
        let _ = reader.join();
        let stderr = errors.join().unwrap_or_default();
        let (mut o, reply) = std::mem::take(&mut *outcome.lock().unwrap());
        if !reply.trim().is_empty() {
            o.answer = reply;
        }
        let tally = o.tally();
        match (stopped, o.answer.trim().is_empty()) {
            (None, false) => ToolOutput::ok(format!("{}\n\n{tally}", o.answer.trim())),
            (Some(why), _) => ToolOutput::err(format!("The subagent was {why}. {}\n{tally}", o.answer.trim())),
            (None, true) => {
                let why = o.errors.last().cloned().unwrap_or_else(|| crate::util::clip(stderr.trim(), 500).to_string());
                ToolOutput::err(format!("The subagent gave no answer. {why} {tally}"))
            }
        }
    }
}

pub struct Agents {
    model: String,
}

impl Agents {
    pub fn new(model: &str) -> Agents {
        Agents { model: model.to_string() }
    }
}

impl Plugin for Agents {
    fn name(&self) -> &str {
        "agents"
    }
    fn description(&self) -> &str {
        "Subagents: the task tool runs a fresh bla on a self-contained job (explore: read-only and in parallel; general)"
    }
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        vec![Arc::new(TaskTool { model: self.model.clone() })]
    }
    fn system_prompt(&self, _session: &Session, sections: &mut Vec<String>) {
        sections.push(GUIDE.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_json_lines() {
        let lines = [
            r#"{"type":"text","text":"Let me look."}"#,
            r#"{"type":"reply_end"}"#,
            r#"{"type":"usage","input":1000,"output":200}"#,
            r#"{"type":"tool_start","name":"read","summary":"a.rs"}"#,
            r#"{"type":"tool_end","name":"read","content":"x","is_error":false}"#,
            r#"{"type":"text","text":"The answer "}"#,
            r#"{"type":"text","text":"is 42."}"#,
            r#"{"type":"reply_end"}"#,
            r#"{"type":"usage","input":1500,"output":100}"#,
            "not json",
        ]
        .join("\n");
        let o = parse(&lines);
        assert_eq!(o.answer, "The answer is 42.");
        assert_eq!(o.tools, 1);
        assert_eq!(o.tokens, 2800);
        assert_eq!(o.tally(), "(1 tool call, 2.8k tokens)");
    }
}
