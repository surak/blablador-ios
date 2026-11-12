//! Everything is a plugin. A plugin contributes tools, model providers and commands, and hooks into the
//! turn: the system prompt, the user's prompt, each request, each tool call and the end of a turn.
//! The `Host` holds the plugins in order and dispatches to them; the core loop only talks to the host.

use crate::llm::{Message, Provider};
use serde_json::Value;
use std::path::Path;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

/// What a tool call does, for permission rules and plan mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// Only looks: runs in parallel with other reads, allowed in plan mode.
    Read,
    /// Changes files.
    Write,
    /// Runs programs.
    Exec,
    /// Changes bla's own state (memory, a plan): allowed without asking.
    Internal,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ToolOutput {
    pub content: String,
    pub is_error: bool,
}

impl ToolOutput {
    pub fn ok(content: impl Into<String>) -> ToolOutput {
        ToolOutput { content: content.into(), is_error: false }
    }

    pub fn err(content: impl Into<String>) -> ToolOutput {
        ToolOutput { content: content.into(), is_error: true }
    }
}

pub struct ToolCtx<'a> {
    pub cwd: &'a Path,
    pub cancel: &'a AtomicBool,
}

pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    /// JSON Schema of the arguments.
    fn parameters(&self) -> Value;
    fn kind(&self, args: &Value) -> Kind;
    /// What permission rules match against: the command for bash, the path for file tools.
    fn subject(&self, _args: &Value) -> Option<String> {
        None
    }
    /// One line for the terminal.
    fn summary(&self, args: &Value) -> String {
        self.subject(args).unwrap_or_default()
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput;
}

/// A plugin's verdict on a tool call. The strictest verdict of all plugins wins: Deny, then Ask, then Allow.
#[derive(Clone, Debug, PartialEq)]
pub enum Decision {
    Allow,
    Ask(String),
    Deny(String),
}

impl Decision {
    fn rank(&self) -> u8 {
        match self {
            Decision::Allow => 0,
            Decision::Ask(_) => 1,
            Decision::Deny(_) => 2,
        }
    }

    pub fn strictest(self, other: Decision) -> Decision {
        if other.rank() > self.rank() {
            other
        } else {
            self
        }
    }
}

/// Plugins get what they need from these; not every built-in plugin reads every field.
#[allow(dead_code)]
pub struct Session<'a> {
    pub id: &'a str,
    pub cwd: &'a Path,
    pub interactive: bool,
}

#[allow(dead_code)]
/// What `before_request` and commands get: the model to ask for small jobs, and the cancel flag.
pub struct Ctx<'a> {
    pub session: &'a Session<'a>,
    pub provider: &'a dyn Provider,
    pub model: &'a str,
    pub cancel: &'a AtomicBool,
}

#[allow(dead_code)]
pub enum Event<'a> {
    TurnStart { turn: usize },
    ToolStart { name: &'a str, args: &'a Value },
    ToolEnd { name: &'a str, args: &'a Value, output: &'a ToolOutput },
    TurnEnd { turn: usize },
}

pub struct CommandSpec {
    pub name: String,
    pub help: String,
}

pub enum CommandResult {
    /// Shown to the user.
    Output(String),
    /// Sent to the model as the user's message.
    Prompt(String),
}

pub trait Plugin: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;

    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        Vec::new()
    }
    fn providers(&self) -> Vec<Arc<dyn Provider>> {
        Vec::new()
    }
    fn commands(&self) -> Vec<CommandSpec> {
        Vec::new()
    }

    fn session_start(&self, _session: &Session) {}
    /// Adds sections to the system prompt. Called once per session, so the prompt stays cacheable.
    fn system_prompt(&self, _session: &Session, _sections: &mut Vec<String>) {}
    /// May rewrite the user's message, or refuse it with a reason.
    fn user_prompt(&self, _session: &Session, _text: &mut String) -> Result<(), String> {
        Ok(())
    }
    /// May change the history before it is sent; returns true when it did, so the change is logged.
    fn before_request(&self, _ctx: &Ctx, _messages: &mut Vec<Message>) -> bool {
        false
    }
    /// Judges a tool call and may rewrite its arguments.
    fn pre_tool(&self, _session: &Session, _tool: &dyn Tool, _args: &mut Value) -> Decision {
        Decision::Allow
    }
    fn post_tool(&self, _session: &Session, _tool: &dyn Tool, _args: &Value, _output: &mut ToolOutput) {}
    /// When the model stops: Some(message) keeps the turn going with that message.
    fn turn_end(&self, _session: &Session, _messages: &[Message]) -> Option<String> {
        None
    }
    fn event(&self, _session: &Session, _event: &Event) {}
    /// Handles `/name args` when it owns the command; None when it doesn't.
    fn command(&self, _ctx: &Ctx, _name: &str, _args: &str, _messages: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        None
    }
    fn session_end(&self, _session: &Session) {}
}

pub struct Host {
    pub plugins: Vec<Arc<dyn Plugin>>,
    tools: Vec<Arc<dyn Tool>>,
    providers: Vec<Arc<dyn Provider>>,
    pub warnings: Vec<String>,
}

impl Host {
    pub fn new(plugins: Vec<Arc<dyn Plugin>>) -> Host {
        let mut tools: Vec<Arc<dyn Tool>> = Vec::new();
        let mut providers = Vec::new();
        let mut warnings = Vec::new();
        for plugin in &plugins {
            for tool in plugin.tools() {
                if tools.iter().any(|t| t.name() == tool.name()) {
                    warnings.push(format!("{}: tool {} is already provided by another plugin", plugin.name(), tool.name()));
                } else {
                    tools.push(tool);
                }
            }
            providers.extend(plugin.providers());
        }
        Host { plugins, tools, providers, warnings }
    }

    pub fn tool(&self, name: &str) -> Option<&Arc<dyn Tool>> {
        self.tools.iter().find(|t| t.name() == name)
    }

    pub fn tools(&self) -> &[Arc<dyn Tool>] {
        &self.tools
    }

    pub fn provider(&self, name: &str) -> Option<Arc<dyn Provider>> {
        self.providers.iter().find(|p| p.name() == name).or_else(|| self.providers.first()).cloned()
    }

    pub fn schemas(&self) -> Vec<Value> {
        self.tools
            .iter()
            .map(|t| {
                serde_json::json!({
                    "type": "function",
                    "function": {"name": t.name(), "description": t.description(), "parameters": t.parameters()}
                })
            })
            .collect()
    }

    pub fn commands(&self) -> Vec<(String, CommandSpec)> {
        self.plugins.iter().flat_map(|p| p.commands().into_iter().map(|c| (p.name().to_string(), c))).collect()
    }

    pub fn session_start(&self, session: &Session) {
        for p in &self.plugins {
            p.session_start(session);
        }
    }

    pub fn system_prompt(&self, session: &Session, base: String) -> String {
        let mut sections = vec![base];
        for p in &self.plugins {
            p.system_prompt(session, &mut sections);
        }
        sections.retain(|s| !s.trim().is_empty());
        sections.join("\n\n")
    }

    pub fn user_prompt(&self, session: &Session, text: &mut String) -> Result<(), String> {
        for p in &self.plugins {
            p.user_prompt(session, text)?;
        }
        Ok(())
    }

    pub fn before_request(&self, ctx: &Ctx, messages: &mut Vec<Message>) -> bool {
        let mut changed = false;
        for p in &self.plugins {
            changed |= p.before_request(ctx, messages);
        }
        changed
    }

    /// Every plugin judges the call. When one rewrites the arguments, all judge the final arguments again,
    /// so a rewrite can't slip past permissions that already looked.
    pub fn pre_tool(&self, session: &Session, tool: &dyn Tool, args: &mut Value) -> Decision {
        let mut decision = Decision::Allow;
        for round in 0..3 {
            let before = args.clone();
            for p in &self.plugins {
                decision = decision.strictest(p.pre_tool(session, tool, args));
            }
            if *args == before {
                return decision;
            }
            if round == 2 {
                break;
            }
        }
        decision.strictest(Decision::Ask("plugins kept rewriting the arguments".into()))
    }

    pub fn post_tool(&self, session: &Session, tool: &dyn Tool, args: &Value, output: &mut ToolOutput) {
        for p in &self.plugins {
            p.post_tool(session, tool, args, output);
        }
    }

    pub fn turn_end(&self, session: &Session, messages: &[Message]) -> Option<String> {
        self.plugins.iter().find_map(|p| p.turn_end(session, messages))
    }

    pub fn event(&self, session: &Session, event: &Event) {
        for p in &self.plugins {
            p.event(session, event);
        }
    }

    pub fn command(&self, ctx: &Ctx, name: &str, args: &str, messages: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        self.plugins.iter().find_map(|p| p.command(ctx, name, args, messages))
    }

    pub fn session_end(&self, session: &Session) {
        for p in &self.plugins {
            p.session_end(session);
        }
    }
}
