//! The loop: ask the model, run the tools it calls, repeat until it answers without tools.
//! Everything around it (the prompt, permissions, compaction, hooks) comes from plugins through the host.

use crate::llm::{Delta, Message, Provider, Request};
use crate::plugin::{Ctx, Decision, Event, Host, Kind, Session as PluginSession, Tool, ToolCtx, ToolOutput};
use crate::session::Session;
use crate::ui::{Approval, Ui};
use serde_json::Value;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// How many times plugins may keep a finished turn going (a Stop hook, a goal), so it can't loop forever.
const MAX_CONTINUATIONS: usize = 25;

pub struct Agent {
    pub host: Host,
    pub provider: Arc<dyn Provider>,
    pub session: Session,
    pub model: String,
    pub effort: Option<String>,
    pub max_steps: usize,
    pub interactive: bool,
    /// Approve everything that would ask (--yes).
    pub yes: bool,
    pub cancel: Arc<AtomicBool>,
    /// Extra instructions from -s.
    pub instructions: Option<String>,
    system: Option<String>,
    always: HashSet<String>,
    turn: usize,
}

pub fn base_prompt(cwd: &std::path::Path) -> String {
    format!(
        "You are bla, a coding agent in the user's terminal, running on Blablador. You help with software and \
         other tasks by reading files, running commands, editing code and writing new files.\n\n\
         Guidelines:\n\
         - Look before you change: read files with the read tool (not cat or sed) and explore with bash (ls, rg, find).\n\
         - Use edit for changes to existing files: old_text must match the file exactly, once. Use write only for new files or complete rewrites.\n\
         - Prefer small, verifiable steps; run the project's tests or build when you change code.\n\
         - Ask the user when something is ambiguous or risky instead of guessing.\n\
         - Answer briefly and plainly. Show file paths when you mention code; don't paste whole files back.\n\n\
         Today is {}. The working directory is {}.",
        crate::util::today(),
        cwd.display()
    )
}

impl Agent {
    pub fn new(host: Host, provider: Arc<dyn Provider>, session: Session, model: String) -> Agent {
        Agent {
            host,
            provider,
            session,
            model,
            effort: None,
            max_steps: 60,
            interactive: false,
            yes: false,
            cancel: Arc::new(AtomicBool::new(false)),
            instructions: None,
            system: None,
            always: HashSet::new(),
            turn: 0,
        }
    }

    /// Starts plugins and builds the system prompt once, so it stays the same (and cacheable) all session.
    pub fn start(&mut self) {
        self.load_always();
        let ps = PluginSession { id: &self.session.id, cwd: &self.session.cwd, interactive: self.interactive };
        self.host.session_start(&ps);
        let mut base = base_prompt(&self.session.cwd);
        if let Some(extra) = &self.instructions {
            base.push_str("\n\n");
            base.push_str(extra);
        }
        self.system = Some(self.host.system_prompt(&ps, base));
    }

    pub fn system_prompt(&self) -> &str {
        self.system.as_deref().unwrap_or_default()
    }

    /// Replaces the session (/new, /resume) and starts plugins again.
    pub fn switch(&mut self, session: Session) {
        self.finish();
        self.session = session;
        self.always.clear();
        self.start();
    }

    pub fn finish(&mut self) {
        let ps = PluginSession { id: &self.session.id, cwd: &self.session.cwd, interactive: self.interactive };
        self.host.session_end(&ps);
    }

    /// Runs a slash command a plugin owns. None when no plugin has it.
    pub fn command(&mut self, name: &str, args: &str) -> Option<Result<crate::plugin::CommandResult, String>> {
        let ps = PluginSession { id: &self.session.id, cwd: &self.session.cwd, interactive: self.interactive };
        let ctx = Ctx { session: &ps, provider: self.provider.as_ref(), model: &self.model, cancel: &self.cancel };
        let mut messages = self.session.messages.clone();
        let result = self.host.command(&ctx, name, args, &mut messages);
        if messages != self.session.messages {
            self.session.replace(messages);
        }
        result
    }

    /// One user message and everything it leads to.
    pub fn turn(&mut self, input: &str, ui: &mut dyn Ui) -> Result<(), String> {
        if self.system.is_none() {
            self.start();
        }
        self.cancel.store(false, Ordering::Relaxed);
        self.turn += 1;
        let turn = self.turn;
        let mut text = input.to_string();
        {
            let ps = PluginSession { id: &self.session.id, cwd: &self.session.cwd, interactive: self.interactive };
            self.host.user_prompt(&ps, &mut text)?;
            self.host.event(&ps, &Event::TurnStart { turn });
        }
        self.session.push(Message::user(text));
        let schemas = self.host.schemas();
        let mut continuations = 0;
        let mut steps = 0;
        let result = loop {
            if self.cancel.load(Ordering::Relaxed) {
                break Err("cancelled".to_string());
            }
            if steps == self.max_steps {
                ui.notice(&format!("Stopped after {steps} steps. Say \"continue\" to go on."));
                break Ok(());
            }
            steps += 1;
            self.compact_if_needed();
            let reply = {
                let request = Request {
                    model: &self.model,
                    system: self.system.as_deref().unwrap_or_default(),
                    messages: &self.session.messages,
                    tools: &schemas,
                    effort: self.effort.as_deref(),
                };
                let mut on = |delta: Delta| match delta {
                    Delta::Text(t) => ui.text(t),
                    Delta::Thinking(t) => ui.thinking(t),
                };
                self.provider.stream(&request, &mut on, &self.cancel)
            };
            ui.end_reply();
            let reply = match reply {
                Ok(r) => r,
                Err(e) => break Err(e),
            };
            if let Some(usage) = &reply.usage {
                ui.usage(usage);
            }
            let calls = reply.message.tool_calls.clone();
            self.session.push(reply.message);
            if reply.finish == "cancelled" {
                self.answer_unrun(&calls, "Cancelled by the user.");
                break Err("cancelled".into());
            }
            if calls.is_empty() {
                let next = {
                    let ps = PluginSession { id: &self.session.id, cwd: &self.session.cwd, interactive: self.interactive };
                    self.host.turn_end(&ps, &self.session.messages)
                };
                match next {
                    Some(message) if continuations < MAX_CONTINUATIONS => {
                        continuations += 1;
                        ui.notice(&format!("↻ {}", crate::util::clip(message.lines().next().unwrap_or_default(), 120)));
                        self.session.push(Message::user(message));
                        continue;
                    }
                    _ => break Ok(()),
                }
            }
            self.run_tools(&calls, ui);
        };
        let ps = PluginSession { id: &self.session.id, cwd: &self.session.cwd, interactive: self.interactive };
        self.host.event(&ps, &Event::TurnEnd { turn });
        result
    }

    fn compact_if_needed(&mut self) {
        let ps = PluginSession { id: &self.session.id, cwd: &self.session.cwd, interactive: self.interactive };
        let ctx = Ctx { session: &ps, provider: self.provider.as_ref(), model: &self.model, cancel: &self.cancel };
        let mut messages = self.session.messages.clone();
        if self.host.before_request(&ctx, &mut messages) {
            self.session.replace(messages);
        }
    }

    /// Every tool call needs an answer, or the next request is invalid.
    fn answer_unrun(&mut self, calls: &[crate::llm::ToolCall], why: &str) {
        for call in calls {
            if !self.session.messages.iter().any(|m| m.tool_call_id.as_deref() == Some(&call.id)) {
                self.session.push(Message::tool(&call.id, why));
            }
        }
    }

    /// What "always" approves: for commands, each simple command's program and subcommand (`cargo test`,
    /// `npm run`), so its variants run without asking again, but only the exact command for anything that deletes,
    /// escalates or reaches the network, and only the exact line when it redirects or substitutes; for file
    /// changes the project (or the file's folder outside it); for other tools the tool.
    fn always_keys(tool: &dyn Tool, args: &Value, cwd: &std::path::Path) -> Vec<String> {
        let subject = tool.subject(args).unwrap_or_default();
        match tool.kind(args) {
            Kind::Exec if subject.contains(['>', '<', '`', '$', '\n']) => vec![format!("{}:{}", tool.name(), subject.trim())],
            Kind::Exec => crate::plugins::permissions::simple_commands(&subject).iter().map(|c| format!("{}:{}", tool.name(), command_prefix(c))).collect(),
            Kind::Write if !subject.is_empty() => {
                let path = crate::util::resolve(cwd, &subject);
                let place = if crate::util::inside(cwd, &path) { cwd.to_path_buf() } else { path.parent().map(|p| p.to_path_buf()).unwrap_or_default() };
                vec![format!("{}:{}", tool.name(), place.display())]
            }
            _ => vec![tool.name().to_string()],
        }
    }

    fn approvals_file() -> std::path::PathBuf {
        crate::util::bla_home().join("approvals.json")
    }

    /// "Always" answers given earlier in this project.
    fn load_always(&mut self) {
        let all: serde_json::Map<String, Value> = std::fs::read(Self::approvals_file()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        let here = self.session.cwd.display().to_string();
        self.always = all.get(&here).and_then(|v| v.as_array()).into_iter().flatten().filter_map(|k| k.as_str().map(String::from)).collect();
    }

    fn save_always(&self) {
        let file = Self::approvals_file();
        let mut all: serde_json::Map<String, Value> = std::fs::read(&file).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        let mut keys: Vec<&String> = self.always.iter().collect();
        keys.sort();
        all.insert(self.session.cwd.display().to_string(), Value::from(keys.into_iter().cloned().collect::<Vec<_>>()));
        if let Some(dir) = file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = crate::secret::write_private(&file, serde_json::to_string_pretty(&all).unwrap_or_default().as_bytes());
    }

    fn run_tools(&mut self, calls: &[crate::llm::ToolCall], ui: &mut dyn Ui) {
        // Decide each call in order (asking the user where needed), then run: reads in parallel, the rest one by one.
        struct Job {
            index: usize,
            tool: Arc<dyn Tool>,
            args: Value,
        }
        let mut outputs: Vec<Option<ToolOutput>> = vec![None; calls.len()];
        let mut jobs: Vec<Job> = Vec::new();
        for (index, call) in calls.iter().enumerate() {
            let Some(tool) = self.host.tool(&call.name).cloned() else {
                outputs[index] = Some(ToolOutput::err(format!("There is no tool called {}.", call.name)));
                continue;
            };
            let mut args: Value = match serde_json::from_str(if call.arguments.trim().is_empty() { "{}" } else { &call.arguments }) {
                Ok(v) => v,
                Err(e) => {
                    outputs[index] = Some(ToolOutput::err(format!("The arguments are not valid JSON ({e}). Send them again as a JSON object.")));
                    continue;
                }
            };
            let decision = {
                let ps = PluginSession { id: &self.session.id, cwd: &self.session.cwd, interactive: self.interactive };
                self.host.pre_tool(&ps, tool.as_ref(), &mut args)
            };
            let allowed = match decision {
                Decision::Allow => true,
                Decision::Deny(reason) => {
                    ui.tool_start(tool.name(), &tool.summary(&args));
                    outputs[index] = Some(ToolOutput::err(format!("Not allowed: {reason}")));
                    ui.tool_end(tool.name(), outputs[index].as_ref().unwrap());
                    false
                }
                Decision::Ask(reason) => {
                    let keys = Self::always_keys(tool.as_ref(), &args, &self.session.cwd);
                    if self.yes || (!keys.is_empty() && keys.iter().all(|k| self.always.contains(k))) {
                        true
                    } else {
                        let covers: Vec<&str> = keys.iter().map(|k| k.split_once(':').map(|(_, rest)| rest).unwrap_or(k)).collect();
                        let note = format!("Always: allows {} in this project from now on", covers.join(", "));
                        let reason = if reason.is_empty() { note } else { format!("{reason} · {note}") };
                        match ui.approve(tool.name(), &tool.summary(&args), &reason) {
                            Approval::Once => true,
                            Approval::Always => {
                                self.always.extend(keys);
                                self.save_always();
                                true
                            }
                            Approval::No => {
                                outputs[index] = Some(ToolOutput::err("The user declined this tool call. Ask them how to go on, or try another way."));
                                false
                            }
                        }
                    }
                }
            };
            if allowed {
                jobs.push(Job { index, tool, args });
            }
            if self.cancel.load(Ordering::Relaxed) {
                break;
            }
        }

        let mut i = 0;
        while i < jobs.len() {
            if self.cancel.load(Ordering::Relaxed) {
                break;
            }
            // A run of read-only calls goes in parallel.
            let mut end = i + 1;
            if jobs[i].tool.kind(&jobs[i].args) == Kind::Read {
                while end < jobs.len() && jobs[end].tool.kind(&jobs[end].args) == Kind::Read {
                    end += 1;
                }
            }
            let batch = &jobs[i..end];
            {
                let ps = PluginSession { id: &self.session.id, cwd: &self.session.cwd, interactive: self.interactive };
                for job in batch {
                    ui.tool_start(job.tool.name(), &job.tool.summary(&job.args));
                    self.host.event(&ps, &Event::ToolStart { name: job.tool.name(), args: &job.args });
                }
            }
            let ctx = ToolCtx { cwd: &self.session.cwd, cancel: &self.cancel };
            let results: Vec<ToolOutput> = if batch.len() == 1 {
                vec![batch[0].tool.run(&batch[0].args, &ctx)]
            } else {
                std::thread::scope(|scope| {
                    let handles: Vec<_> = batch.iter().map(|job| scope.spawn(|| job.tool.run(&job.args, &ctx))).collect();
                    handles.into_iter().map(|h| h.join().unwrap_or_else(|_| ToolOutput::err("The tool crashed."))).collect()
                })
            };
            let ps = PluginSession { id: &self.session.id, cwd: &self.session.cwd, interactive: self.interactive };
            for (job, mut output) in batch.iter().zip(results) {
                self.host.post_tool(&ps, job.tool.as_ref(), &job.args, &mut output);
                self.host.event(&ps, &Event::ToolEnd { name: job.tool.name(), args: &job.args, output: &output });
                ui.tool_end(job.tool.name(), &output);
                outputs[job.index] = Some(output);
            }
            i = end;
        }

        for (call, output) in calls.iter().zip(outputs) {
            let content = match output {
                Some(o) if o.is_error && !o.content.starts_with("Error") => format!("Error: {}", o.content),
                Some(o) => o.content,
                None => "Cancelled by the user.".into(),
            };
            self.session.push(Message::tool(&call.id, content));
        }
    }
}

/// Programs whose "always" stays with the exact command: they delete, escalate, reach the network or rewrite history.
const EXACT_ONLY: &[&str] = &[
    "rm", "rmdir", "sudo", "doas", "su", "dd", "mkfs", "chmod", "chown", "kill", "pkill", "killall", "curl", "wget", "ssh", "scp", "rsync",
    "nc", "eval", "exec", "sh", "bash", "zsh", "shutdown", "reboot", "launchctl", "systemctl", "docker", "kubectl", "mv", "truncate", "shred",
    "python", "python3", "node", "ruby", "perl", "php", "deno", "bun", "npx", "uvx", "pipx", "osascript",
];
const GIT_EXACT_ONLY: &[&str] = &["push", "reset", "clean", "rebase", "checkout", "restore", "branch", "tag", "filter-branch", "gc", "update-ref", "config"];

/// The part of a simple command that "always" approves: `cargo test` for `cargo test --release foo`.
pub fn command_prefix(command: &str) -> String {
    let words: Vec<&str> = command.split_whitespace().collect();
    let Some(&first) = words.first() else { return String::new() };
    let program = first.rsplit('/').next().unwrap_or(first);
    let second = words.get(1).copied();
    if EXACT_ONLY.contains(&program) || (program == "git" && second.is_some_and(|s| GIT_EXACT_ONLY.contains(&s))) {
        return command.trim().to_string();
    }
    match second {
        Some(sub) if !sub.starts_with('-') && !sub.contains(['/', '.', '=']) && sub.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_' || c == ':') => {
            format!("{first} {sub}")
        }
        _ => first.to_string(),
    }
}

#[cfg(test)]
mod prefix_tests {
    #[test]
    fn always_covers_subcommands_but_not_risky_programs() {
        assert_eq!(super::command_prefix("cargo test --release foo"), "cargo test");
        assert_eq!(super::command_prefix("make"), "make");
        assert_eq!(super::command_prefix("./gradlew test"), "./gradlew test");
        assert_eq!(super::command_prefix("rm -rf build"), "rm -rf build");
        assert_eq!(super::command_prefix("git push origin main"), "git push origin main");
        assert_eq!(super::command_prefix("python3 script.py"), "python3 script.py");
        assert_eq!(super::command_prefix("npm run build"), "npm run");
    }
}
