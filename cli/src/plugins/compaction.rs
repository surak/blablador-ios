//! Compaction: when the conversation grows past `compactAt` characters, the model summarises everything but the
//! recent part, and the summary replaces it. `/compact` does it now. The rewrite is logged, so resuming works.

use crate::llm::Message;
use crate::plugin::{CommandResult, CommandSpec, Ctx, Plugin};
use crate::util;

const KEEP_CHARS: usize = 40_000;

const SUMMARY_PROMPT: &str = "You summarise a coding session so it can continue with only your summary. Keep: the user's goals and \
requests in their words, decisions and their reasons, files changed and how, commands and test results that matter, errors met \
and how they were solved, and what is left to do. Be specific (paths, names, numbers); leave out chatter. Write plain text.";

pub struct Compaction {
    pub threshold: usize,
    /// The size at which compaction last failed or didn't help: no new try until the history grows past it.
    pub gave_up_at: std::sync::Mutex<usize>,
}

impl Compaction {
    pub fn new(threshold: usize) -> Compaction {
        Compaction { threshold, gave_up_at: std::sync::Mutex::new(0) }
    }
}

/// Where the kept tail starts: never at a tool result, so every result keeps the call it answers.
/// A long single task (one user message, many tool calls) can be cut before any assistant message.
fn cut_point(messages: &[Message], keep: usize) -> Option<usize> {
    let mut size = 0;
    let mut cut = None;
    for (i, m) in messages.iter().enumerate().rev() {
        size += m.size();
        if m.role != "tool" && i > 0 {
            cut = Some(i);
            if size >= keep {
                break;
            }
        }
    }
    cut
}

fn transcript(messages: &[Message]) -> String {
    let mut out = String::new();
    for m in messages {
        match m.role.as_str() {
            "tool" => out.push_str(&format!("[tool result]\n{}\n\n", util::clip(&m.content, 2000))),
            role => {
                out.push_str(&format!("[{role}]\n{}\n", util::clip(&m.content, 8000)));
                for c in &m.tool_calls {
                    out.push_str(&format!("(calls {} {})\n", c.name, util::clip(&c.arguments, 500)));
                }
                out.push('\n');
            }
        }
    }
    out
}

pub fn compact(ctx: &Ctx, messages: &mut Vec<Message>, keep: usize) -> Result<usize, String> {
    let Some(cut) = cut_point(messages, keep) else { return Err("The conversation is too short to compact.".into()) };
    let summary = ctx.provider.complete(ctx.model, SUMMARY_PROMPT, &transcript(&messages[..cut]))?;
    if summary.trim().is_empty() {
        return Err("The summary came back empty.".into());
    }
    let mut next = vec![Message::user(format!("Summary of the conversation so far (earlier messages were compacted):\n\n{}", summary.trim()))];
    next.extend_from_slice(&messages[cut..]);
    *messages = next;
    Ok(cut)
}

impl Plugin for Compaction {
    fn name(&self) -> &str {
        "compaction"
    }
    fn description(&self) -> &str {
        "Summarises long conversations so they fit the model's context"
    }
    fn commands(&self) -> Vec<CommandSpec> {
        vec![CommandSpec { name: "compact".into(), help: "summarise the conversation so far to save context".into() }]
    }
    fn before_request(&self, ctx: &Ctx, messages: &mut Vec<Message>) -> bool {
        let size: usize = messages.iter().map(Message::size).sum();
        let mut gave_up = self.gave_up_at.lock().unwrap();
        if size <= self.threshold || size <= *gave_up + *gave_up / 5 {
            return false;
        }
        let ok = compact(ctx, messages, KEEP_CHARS).is_ok();
        let after: usize = messages.iter().map(Message::size).sum();
        if !ok || after > self.threshold {
            *gave_up = size.max(after);
        }
        ok
    }
    fn command(&self, ctx: &Ctx, name: &str, _args: &str, messages: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        if name != "compact" {
            return None;
        }
        Some(compact(ctx, messages, 0).map(|n| CommandResult::Output(format!("Compacted {n} messages into a summary."))))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn never_cuts_at_a_tool_result() {
        let mut messages = vec![Message::user("a")];
        messages.push(Message { role: "assistant".into(), content: "x".repeat(100), ..Default::default() });
        messages.push(Message::user("b"));
        messages.push(Message { role: "assistant".into(), tool_calls: vec![Default::default()], ..Default::default() });
        messages.push(Message::tool("1", "y".repeat(50)));
        assert_eq!(cut_point(&messages, 10), Some(3));
        assert_eq!(cut_point(&messages, 1000), Some(1));
        assert_eq!(cut_point(&messages[..1], 0), None);
    }
}
