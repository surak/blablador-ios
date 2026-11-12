//! The message vocabulary and the model seam. A provider plugin turns a `Request` into a streamed `Reply`.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::atomic::AtomicBool;

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    /// The arguments as the model wrote them: JSON text, possibly broken.
    pub arguments: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct Message {
    /// "user", "assistant" or "tool".
    pub role: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub content: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ToolCall>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// The model's thinking: kept in the log, never sent back.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub reasoning: String,
}

impl Message {
    pub fn user(text: impl Into<String>) -> Message {
        Message { role: "user".into(), content: text.into(), ..Default::default() }
    }

    pub fn tool(id: &str, content: impl Into<String>) -> Message {
        Message { role: "tool".into(), content: content.into(), tool_call_id: Some(id.into()), ..Default::default() }
    }

    /// Size in characters, for deciding when to compact.
    pub fn size(&self) -> usize {
        self.content.len() + self.tool_calls.iter().map(|c| c.name.len() + c.arguments.len()).sum::<usize>()
    }
}

pub struct Request<'a> {
    pub model: &'a str,
    pub system: &'a str,
    pub messages: &'a [Message],
    /// OpenAI-style function schemas.
    pub tools: &'a [Value],
    /// off, low, medium, high or max; None leaves it to the model.
    pub effort: Option<&'a str>,
}

pub enum Delta<'a> {
    Text(&'a str),
    Thinking(&'a str),
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Usage {
    pub input: u64,
    pub output: u64,
}

pub struct Reply {
    pub message: Message,
    pub usage: Option<Usage>,
    /// "stop", "tool_calls", "length", "cancelled"…
    pub finish: String,
}

pub trait Provider: Send + Sync {
    fn name(&self) -> &str;

    /// Streams one model request; `on` sees text and thinking as they arrive.
    fn stream(&self, request: &Request, on: &mut dyn FnMut(Delta), cancel: &AtomicBool) -> Result<Reply, String>;

    fn models(&self) -> Result<Vec<String>, String>;

    /// One question, one answer, no tools: for summaries and other small jobs.
    fn complete(&self, model: &str, system: &str, user: &str) -> Result<String, String> {
        let messages = [Message::user(user)];
        let request = Request { model, system, messages: &messages, tools: &[], effort: Some("off") };
        let cancel = AtomicBool::new(false);
        Ok(self.stream(&request, &mut |_| {}, &cancel)?.message.content)
    }
}
