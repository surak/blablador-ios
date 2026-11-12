//! Hooks: shell commands run at points of a session, configured like Claude Code's, so its hook scripts work:
//!
//! ```json
//! "hooks": {"PreToolUse": [{"matcher": "Bash|Write", "hooks": [{"type": "command", "command": "./check.sh", "timeout": 30}]}]}
//! ```
//!
//! Events: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd. The hook gets a JSON
//! object on stdin (session_id, cwd, hook_event_name, tool_name, tool_input, tool_response, prompt).
//! Exit code 2 blocks, with stderr as the reason; exit 0 may print JSON: `{"decision": "block", "reason": …}`
//! or `{"hookSpecificOutput": {"permissionDecision": "allow" | "ask" | "deny", "permissionDecisionReason": …,
//! "additionalContext": …}}`. Plain stdout from SessionStart and UserPromptSubmit is added as context.

use crate::llm::Message;
use crate::plugin::{Decision, Plugin, Session, Tool, ToolOutput};
use crate::util;
use serde_json::{json, Value};
use std::process::Command;
use std::sync::atomic::AtomicBool;
use std::sync::Mutex;
use std::time::Duration;

struct Hook {
    matcher: String,
    command: String,
    timeout: u64,
}

pub struct Hooks {
    events: Vec<(String, Vec<Hook>)>,
    start_context: Mutex<String>,
    stop_active: Mutex<bool>,
}

/// The tool's name as Claude Code spells it, so matchers written for it still match.
fn claude_name(tool: &str) -> String {
    let mut chars = tool.chars();
    chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default()
}

fn matches(matcher: &str, tool: &str) -> bool {
    let matcher = matcher.trim();
    if matcher.is_empty() || matcher == "*" {
        return true;
    }
    matcher.split('|').any(|m| {
        let m = m.trim();
        m.eq_ignore_ascii_case(tool) || util::glob_match(&m.to_lowercase(), &tool.to_lowercase(), false) || (m == "MultiEdit" && tool == "edit")
    })
}

struct Outcome {
    blocked: Option<String>,
    decision: Option<Decision>,
    context: String,
}

impl Hooks {
    pub fn new(config: &Value) -> Hooks {
        let mut events = Vec::new();
        if let Some(map) = config.as_object() {
            for (event, groups) in map {
                let mut hooks = Vec::new();
                for group in groups.as_array().into_iter().flatten() {
                    let matcher = group["matcher"].as_str().unwrap_or("").to_string();
                    for h in group["hooks"].as_array().into_iter().flatten() {
                        if let Some(command) = h["command"].as_str() {
                            hooks.push(Hook { matcher: matcher.clone(), command: command.into(), timeout: h["timeout"].as_u64().unwrap_or(60).clamp(1, 600) });
                        }
                    }
                }
                events.push((event.clone(), hooks));
            }
        }
        Hooks { events, start_context: Mutex::new(String::new()), stop_active: Mutex::new(false) }
    }

    pub fn is_empty(&self) -> bool {
        self.events.iter().all(|(_, h)| h.is_empty())
    }

    fn run(&self, event: &str, tool: Option<&str>, session: &Session, mut input: Value) -> Outcome {
        let mut outcome = Outcome { blocked: None, decision: None, context: String::new() };
        let Some((_, hooks)) = self.events.iter().find(|(e, _)| e == event) else { return outcome };
        input["session_id"] = json!(session.id);
        input["cwd"] = json!(session.cwd);
        input["hook_event_name"] = json!(event);
        let payload = input.to_string();
        let cancel = AtomicBool::new(false);
        for hook in hooks.iter().filter(|h| tool.map(|t| matches(&h.matcher, t)).unwrap_or(true)) {
            let (shell, flag) = util::shell();
            let mut cmd = Command::new(shell);
            cmd.arg(flag).arg(&hook.command).current_dir(session.cwd).env("BLA_PROJECT_DIR", session.cwd).env("CLAUDE_PROJECT_DIR", session.cwd);
            let done = match util::run(cmd, payload.as_bytes(), Duration::from_secs(hook.timeout), &cancel) {
                Ok(d) => d,
                Err(e) => {
                    outcome.context.push_str(&format!("(hook {} could not start: {e})\n", hook.command));
                    continue;
                }
            };
            let stdout = String::from_utf8_lossy(&done.stdout).trim().to_string();
            let stderr = String::from_utf8_lossy(&done.stderr).trim().to_string();
            match done.code {
                Some(2) => {
                    outcome.blocked = Some(if stderr.is_empty() { format!("blocked by the hook {}", hook.command) } else { stderr });
                    return outcome;
                }
                Some(0) => {
                    if let Ok(v) = serde_json::from_str::<Value>(&stdout) {
                        if v["decision"] == "block" || v["continue"] == false {
                            outcome.blocked = Some(v["reason"].as_str().or(v["stopReason"].as_str()).unwrap_or("blocked by a hook").to_string());
                            return outcome;
                        }
                        let specific = &v["hookSpecificOutput"];
                        let reason = specific["permissionDecisionReason"].as_str().unwrap_or_default().to_string();
                        let decision = match specific["permissionDecision"].as_str() {
                            Some("deny") => Some(Decision::Deny(if reason.is_empty() { "a hook denied it".into() } else { reason })),
                            Some("ask") => Some(Decision::Ask(reason)),
                            Some("allow") => Some(Decision::Allow),
                            _ => None,
                        };
                        // Several hooks: the strictest verdict wins.
                        if let Some(d) = decision {
                            outcome.decision = Some(match outcome.decision.take() {
                                Some(previous) => previous.strictest(d),
                                None => d,
                            });
                        }
                        if let Some(extra) = specific["additionalContext"].as_str() {
                            outcome.context.push_str(extra);
                            outcome.context.push('\n');
                        }
                    } else if !stdout.is_empty() {
                        outcome.context.push_str(&stdout);
                        outcome.context.push('\n');
                    }
                }
                _ if done.timed_out => outcome.context.push_str(&format!("(hook {} timed out)\n", hook.command)),
                _ => {}
            }
        }
        outcome
    }
}

impl Plugin for Hooks {
    fn name(&self) -> &str {
        "hooks"
    }
    fn description(&self) -> &str {
        "Shell hooks at session start, prompt, tool calls and stop (Claude Code format)"
    }
    fn session_start(&self, session: &Session) {
        let outcome = self.run("SessionStart", None, session, json!({"source": "startup"}));
        *self.start_context.lock().unwrap() = outcome.context;
    }
    fn system_prompt(&self, _session: &Session, sections: &mut Vec<String>) {
        let context = self.start_context.lock().unwrap();
        if !context.trim().is_empty() {
            sections.push(format!("Context from session hooks:\n{}", context.trim()));
        }
    }
    fn user_prompt(&self, session: &Session, text: &mut String) -> Result<(), String> {
        *self.stop_active.lock().unwrap() = false;
        let outcome = self.run("UserPromptSubmit", None, session, json!({"prompt": text}));
        if let Some(reason) = outcome.blocked {
            return Err(format!("A hook refused the message: {reason}"));
        }
        if !outcome.context.trim().is_empty() {
            text.push_str(&format!("\n\n<hook-context>\n{}\n</hook-context>", outcome.context.trim()));
        }
        Ok(())
    }
    fn pre_tool(&self, session: &Session, tool: &dyn Tool, args: &mut Value) -> Decision {
        let outcome = self.run("PreToolUse", Some(tool.name()), session, json!({"tool_name": claude_name(tool.name()), "tool_input": args}));
        if let Some(reason) = outcome.blocked {
            return Decision::Deny(reason);
        }
        outcome.decision.unwrap_or(Decision::Allow)
    }
    fn post_tool(&self, session: &Session, tool: &dyn Tool, args: &Value, output: &mut ToolOutput) {
        let response = json!({"content": output.content, "is_error": output.is_error});
        let outcome = self.run("PostToolUse", Some(tool.name()), session, json!({"tool_name": claude_name(tool.name()), "tool_input": args, "tool_response": response}));
        if let Some(reason) = outcome.blocked {
            output.content.push_str(&format!("\n\n[Hook feedback: {reason}]"));
        } else if !outcome.context.trim().is_empty() {
            output.content.push_str(&format!("\n\n[Hook: {}]", outcome.context.trim()));
        }
    }
    fn turn_end(&self, session: &Session, messages: &[Message]) -> Option<String> {
        let active = *self.stop_active.lock().unwrap();
        let last = messages.last().map(|m| m.content.clone()).unwrap_or_default();
        let outcome = self.run("Stop", None, session, json!({"stop_hook_active": active, "last_assistant_message": last}));
        let reason = outcome.blocked?;
        *self.stop_active.lock().unwrap() = true;
        Some(format!("A stop hook says the task isn't finished: {reason}"))
    }
    fn session_end(&self, session: &Session) {
        let _ = self.run("SessionEnd", None, session, json!({"reason": "exit"}));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugins::core_tools::CoreTools;

    #[test]
    fn blocks_and_decides() {
        if cfg!(windows) {
            return;
        }
        let cwd = std::env::temp_dir();
        let session = Session { id: "s", cwd: &cwd, interactive: false };
        let hooks = Hooks::new(&json!({
            "PreToolUse": [
                {"matcher": "Bash", "hooks": [{"type": "command", "command": "grep -q 'rm -rf' && { echo 'no rm -rf' >&2; exit 2; } || exit 0"}]},
                {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "echo '{\"hookSpecificOutput\": {\"permissionDecision\": \"ask\", \"permissionDecisionReason\": \"check\"}}'"}]}
            ],
            "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "echo extra"}]}]
        }));
        let tools = CoreTools::new().tools();
        let bash = tools.iter().find(|t| t.name() == "bash").unwrap();
        let write = tools.iter().find(|t| t.name() == "write").unwrap();
        assert_eq!(hooks.pre_tool(&session, bash.as_ref(), &mut json!({"command": "rm -rf /"})), Decision::Deny("no rm -rf".into()));
        assert_eq!(hooks.pre_tool(&session, bash.as_ref(), &mut json!({"command": "ls"})), Decision::Allow);
        assert_eq!(hooks.pre_tool(&session, write.as_ref(), &mut json!({"path": "a"})), Decision::Ask("check".into()));
        let mut text = "hi".to_string();
        hooks.user_prompt(&session, &mut text).unwrap();
        assert!(text.contains("<hook-context>\nextra\n</hook-context>"));
    }
}
