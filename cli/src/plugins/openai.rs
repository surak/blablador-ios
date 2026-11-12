//! Model provider for OpenAI-compatible endpoints (Blablador by default): streaming chat completions with tools.

use crate::llm::{Delta, Message, Provider, Reply, Request, ToolCall, Usage};
use crate::plugin::Plugin;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub struct OpenAi {
    endpoint: String,
    key: String,
    agent: ureq::Agent,
}

impl OpenAi {
    pub fn new(endpoint: &str, key: String, allow_insecure: bool) -> Result<OpenAi, String> {
        let endpoint = endpoint.trim().trim_end_matches('/').to_string();
        let host = endpoint.split("://").nth(1).unwrap_or_default().split(['/', ':']).next().unwrap_or_default();
        let local = matches!(host, "localhost" | "127.0.0.1" | "[::1]");
        if endpoint.starts_with("http://") && !local && !allow_insecure {
            return Err(format!("{endpoint} is plain http: the key would travel unencrypted. Use https, or set allowInsecureHttp."));
        }
        if !endpoint.starts_with("https://") && !endpoint.starts_with("http://") {
            return Err(format!("{endpoint} is not an http(s) address"));
        }
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(20))
            .timeout_read(Duration::from_secs(600))
            .user_agent(concat!("bla/", env!("CARGO_PKG_VERSION")))
            .build();
        Ok(OpenAi { endpoint, key, agent })
    }

    fn post(&self, path: &str, body: &Value) -> Result<ureq::Response, String> {
        if self.key.is_empty() {
            return Err("No API key. Run `bla login`, or set BLABLADOR_API_KEY.".into());
        }
        match self
            .agent
            .post(&format!("{}/{path}", self.endpoint))
            .set("Authorization", &format!("Bearer {}", self.key))
            .set("Content-Type", "application/json")
            .send_string(&body.to_string())
        {
            Ok(r) => Ok(r),
            Err(ureq::Error::Status(code, r)) => {
                let text = r.into_string().unwrap_or_default();
                let message = serde_json::from_str::<Value>(&text)
                    .ok()
                    .and_then(|v| v["error"]["message"].as_str().or(v["detail"].as_str()).map(String::from))
                    .unwrap_or_else(|| crate::util::clip(&text, 300).to_string());
                Err(format!("HTTP {code}: {message}"))
            }
            Err(e) => Err(e.to_string()),
        }
    }
}

/// The OpenAI wire form of the history.
pub fn wire_messages(system: &str, messages: &[Message]) -> Vec<Value> {
    let mut out = Vec::with_capacity(messages.len() + 1);
    if !system.is_empty() {
        out.push(json!({"role": "system", "content": system}));
    }
    for m in messages {
        match m.role.as_str() {
            "assistant" => {
                let mut v = json!({"role": "assistant", "content": if m.content.is_empty() && !m.tool_calls.is_empty() { Value::Null } else { Value::from(m.content.clone()) }});
                if !m.tool_calls.is_empty() {
                    v["tool_calls"] = m
                        .tool_calls
                        .iter()
                        .map(|c| json!({"id": c.id, "type": "function", "function": {"name": c.name, "arguments": if c.arguments.is_empty() { "{}" } else { &c.arguments }}}))
                        .collect();
                }
                out.push(v);
            }
            "tool" => out.push(json!({"role": "tool", "tool_call_id": m.tool_call_id, "content": m.content})),
            _ => out.push(json!({"role": m.role, "content": m.content})),
        }
    }
    out
}

/// Request fields for a thinking effort.
fn effort_fields(effort: &str) -> Value {
    match effort {
        "off" => json!({"reasoning_effort": "low", "chat_template_kwargs": {"enable_thinking": false, "thinking": false}}),
        "max" => json!({"reasoning_effort": "high"}),
        other => json!({"reasoning_effort": other}),
    }
}

/// Folds one streamed chunk into the reply; returns text and thinking to show.
pub struct StreamState {
    pub content: String,
    pub reasoning: String,
    pub calls: Vec<ToolCall>,
    pub finish: String,
    pub usage: Option<Usage>,
}

impl StreamState {
    pub fn new() -> StreamState {
        StreamState { content: String::new(), reasoning: String::new(), calls: Vec::new(), finish: String::new(), usage: None }
    }

    pub fn feed(&mut self, chunk: &Value, on: &mut dyn FnMut(Delta)) {
        if let Some(u) = chunk.get("usage").filter(|u| u.is_object()) {
            self.usage = Some(Usage { input: u["prompt_tokens"].as_u64().unwrap_or(0), output: u["completion_tokens"].as_u64().unwrap_or(0) });
        }
        let Some(choice) = chunk["choices"].get(0) else { return };
        if let Some(f) = choice["finish_reason"].as_str() {
            self.finish = f.into();
        }
        let delta = &choice["delta"];
        for key in ["reasoning_content", "reasoning"] {
            if let Some(t) = delta[key].as_str().filter(|t| !t.is_empty()) {
                self.reasoning.push_str(t);
                on(Delta::Thinking(t));
            }
        }
        if let Some(t) = delta["content"].as_str().filter(|t| !t.is_empty()) {
            self.content.push_str(t);
            on(Delta::Text(t));
        }
        if let Some(calls) = delta["tool_calls"].as_array() {
            for (n, c) in calls.iter().enumerate() {
                let index = c["index"].as_u64().map(|i| i as usize).unwrap_or(n);
                // A broken or hostile server can't make us allocate without end.
                if index > self.calls.len() + 64 {
                    continue;
                }
                while self.calls.len() <= index {
                    self.calls.push(ToolCall::default());
                }
                let call = &mut self.calls[index];
                if let Some(id) = c["id"].as_str().filter(|s| !s.is_empty()) {
                    call.id = id.into();
                }
                if let Some(name) = c["function"]["name"].as_str() {
                    call.name.push_str(name);
                }
                if let Some(args) = c["function"]["arguments"].as_str() {
                    call.arguments.push_str(args);
                }
            }
        }
    }

    pub fn into_reply(mut self) -> Reply {
        self.calls.retain(|c| !c.name.is_empty());
        for (n, c) in self.calls.iter_mut().enumerate() {
            if c.id.is_empty() {
                c.id = format!("call_{n}_{}", crate::util::random_hex(8));
            }
        }
        Reply {
            message: Message { role: "assistant".into(), content: self.content, tool_calls: self.calls, tool_call_id: None, reasoning: self.reasoning },
            usage: self.usage,
            finish: self.finish,
        }
    }
}

impl Provider for OpenAi {
    fn name(&self) -> &str {
        "openai"
    }

    fn stream(&self, request: &Request, on: &mut dyn FnMut(Delta), cancel: &AtomicBool) -> Result<Reply, String> {
        let mut body = json!({
            "model": request.model,
            "messages": wire_messages(request.system, request.messages),
            "stream": true,
            "stream_options": {"include_usage": true},
        });
        if !request.tools.is_empty() {
            body["tools"] = Value::from(request.tools.to_vec());
        }
        if let Some(effort) = request.effort {
            if let (Some(b), Value::Object(extra)) = (body.as_object_mut(), effort_fields(effort)) {
                b.extend(extra);
            }
        }
        // Servers that don't know an optional field answer 400; ask again without them.
        let response = match self.post("chat/completions", &body) {
            Err(e) if e.starts_with("HTTP 400") || e.starts_with("HTTP 422") => {
                if let Some(b) = body.as_object_mut() {
                    for key in ["stream_options", "reasoning_effort", "chat_template_kwargs"] {
                        b.remove(key);
                    }
                }
                self.post("chat/completions", &body)?
            }
            other => other?,
        };
        let mut state = StreamState::new();
        let reader = BufReader::new(response.into_reader());
        for line in reader.lines() {
            if cancel.load(Ordering::Relaxed) {
                state.finish = "cancelled".into();
                state.calls.clear();
                break;
            }
            let line = line.map_err(|e| format!("the connection broke: {e}"))?;
            let Some(data) = line.strip_prefix("data:") else { continue };
            let data = data.trim();
            if data == "[DONE]" {
                break;
            }
            if let Ok(chunk) = serde_json::from_str::<Value>(data) {
                if let Some(message) = chunk["error"]["message"].as_str() {
                    return Err(message.to_string());
                }
                state.feed(&chunk, on);
            }
        }
        Ok(state.into_reply())
    }

    fn models(&self) -> Result<Vec<String>, String> {
        if self.key.is_empty() {
            return Err("No API key. Run `bla login`, or set BLABLADOR_API_KEY.".into());
        }
        let response = self
            .agent
            .get(&format!("{}/models", self.endpoint))
            .set("Authorization", &format!("Bearer {}", self.key))
            .call()
            .map_err(|e| e.to_string())?;
        let v: Value = response.into_json().map_err(|e| e.to_string())?;
        let mut ids: Vec<String> = v["data"].as_array().into_iter().flatten().filter_map(|m| m["id"].as_str().map(String::from)).collect();
        ids.sort();
        Ok(ids)
    }
}

pub struct OpenAiPlugin {
    provider: Arc<OpenAi>,
}

impl OpenAiPlugin {
    pub fn new(provider: OpenAi) -> OpenAiPlugin {
        OpenAiPlugin { provider: Arc::new(provider) }
    }
}

impl Plugin for OpenAiPlugin {
    fn name(&self) -> &str {
        "openai"
    }
    fn description(&self) -> &str {
        "Model provider for OpenAI-compatible endpoints (Blablador)"
    }
    fn providers(&self) -> Vec<Arc<dyn Provider>> {
        vec![self.provider.clone()]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folds_streamed_tool_calls() {
        let mut state = StreamState::new();
        let mut shown = String::new();
        let chunks = [
            json!({"choices": [{"delta": {"reasoning_content": "hmm"}}]}),
            json!({"choices": [{"delta": {"content": "Looking"}}]}),
            json!({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "a", "function": {"name": "read", "arguments": "{\"pa"}}]}}]}),
            json!({"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "th\":\"x\"}"}}]}}]}),
            json!({"choices": [{"delta": {"tool_calls": [{"index": 1, "function": {"name": "bash", "arguments": "{}"}}]}, "finish_reason": "tool_calls"}]}),
            json!({"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 5}}),
        ];
        for c in &chunks {
            state.feed(c, &mut |d| {
                if let Delta::Text(t) = d {
                    shown.push_str(t)
                }
            });
        }
        let reply = state.into_reply();
        assert_eq!(shown, "Looking");
        assert_eq!(reply.message.reasoning, "hmm");
        assert_eq!(reply.message.tool_calls[0], ToolCall { id: "a".into(), name: "read".into(), arguments: "{\"path\":\"x\"}".into() });
        assert_eq!(reply.message.tool_calls[1].name, "bash");
        assert!(!reply.message.tool_calls[1].id.is_empty());
        assert_eq!(reply.finish, "tool_calls");
        assert_eq!(reply.usage, Some(Usage { input: 10, output: 5 }));
    }

    #[test]
    fn wire_form() {
        let messages = vec![
            Message::user("hi"),
            Message { role: "assistant".into(), tool_calls: vec![ToolCall { id: "1".into(), name: "read".into(), arguments: String::new() }], reasoning: "secret".into(), ..Default::default() },
            Message::tool("1", "file"),
        ];
        let wire = wire_messages("sys", &messages);
        assert_eq!(wire[0], json!({"role": "system", "content": "sys"}));
        assert_eq!(wire[2]["content"], Value::Null);
        assert_eq!(wire[2]["tool_calls"][0]["function"]["arguments"], "{}");
        assert!(wire[2].get("reasoning").is_none());
        assert_eq!(wire[3], json!({"role": "tool", "tool_call_id": "1", "content": "file"}));
    }

    #[test]
    fn refuses_plain_http_elsewhere() {
        assert!(OpenAi::new("http://example.com/v1", "k".into(), false).is_err());
        assert!(OpenAi::new("http://localhost:8000/v1", "k".into(), false).is_ok());
        assert!(OpenAi::new("https://api.blablador.fz-juelich.de/v1/", "k".into(), false).is_ok());
        assert!(OpenAi::new("file:///etc/passwd", "k".into(), true).is_err());
    }
}
