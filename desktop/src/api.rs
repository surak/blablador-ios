//! Client for Blablador's OpenAI-compatible API: models, streaming chat completions, embeddings and rerank.

use anyhow::{anyhow, Result};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::time::Duration;

pub const DEFAULT_ENDPOINT: &str = "https://api.blablador.fz-juelich.de/v1";
pub const DEFAULT_MODEL: &str = "deepseek-v4.1-flash-at-hzdr";
/// Blablador's quick model for small jobs such as chat titles.
pub const FAST_MODEL: &str = "alias-fast";
pub const EMBEDDING_MODEL: &str = "alias-qwen3-4b-embeddings";
pub const FALLBACK_EMBEDDING_MODEL: &str = "alias-embeddings";
pub const RERANK_MODEL: &str = "alias-qwen3-4b-reranker";

/// A failed request, with the server's status so callers can react to 400s and 500s.
#[derive(Debug)]
pub struct HttpError {
    pub status: u16,
    pub body: String,
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Server returned {}. {}", self.status, self.body)
    }
}

impl std::error::Error for HttpError {}

pub fn http_status(error: &anyhow::Error) -> Option<u16> {
    error.downcast_ref::<HttpError>().map(|e| e.status)
}

#[derive(Clone, Default, Debug, Serialize, Deserialize, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

impl ToolCall {
    pub fn wire(&self) -> Value {
        json!({ "id": self.id, "type": "function", "function": { "name": self.name, "arguments": self.arguments } })
    }
}

pub enum StreamEvent {
    Content(String),
    Reasoning(String),
    ToolCalls(Vec<ToolCall>),
    Usage { prompt: u64, completion: u64 },
}

#[derive(Clone)]
pub struct Api {
    pub endpoint: String,
    pub key: String,
    /// Minutes to wait for a reply; 0 waits as long as it takes.
    pub timeout_minutes: u64,
    client: reqwest::Client,
}

impl Api {
    pub fn new(endpoint: &str, key: &str, timeout_minutes: u64) -> Api {
        let client = reqwest::Client::builder()
            .user_agent(concat!("Blablador-desktop/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(30))
            .build()
            .expect("HTTP client");
        Api { endpoint: endpoint.trim().trim_end_matches('/').to_string(), key: key.trim().to_string(), timeout_minutes, client }
    }

    fn url(&self, path: &str) -> String {
        let base = if self.endpoint.is_empty() { DEFAULT_ENDPOINT } else { &self.endpoint };
        format!("{base}/{path}")
    }

    pub fn is_blablador(&self) -> bool {
        self.endpoint.is_empty() || self.endpoint == DEFAULT_ENDPOINT
    }

    /// alias-fast on Blablador, the chat's own model on other endpoints.
    pub fn helper_model(&self, chat_model: &str) -> String {
        if self.is_blablador() { FAST_MODEL.into() } else { chat_model.into() }
    }

    fn post(&self, path: &str, body: &Value, timeout: Duration) -> Result<reqwest::RequestBuilder> {
        if self.key.is_empty() {
            return Err(anyhow!("No API key set. Add your Blablador API key in Settings."));
        }
        Ok(self.client.post(self.url(path)).bearer_auth(&self.key).json(body).timeout(timeout))
    }

    async fn checked(response: reqwest::Response) -> Result<reqwest::Response> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        let body: String = response.text().await.unwrap_or_default().chars().take(500).collect();
        Err(HttpError { status: status.as_u16(), body }.into())
    }

    /// Chat model ids, sorted.
    pub async fn models(&self) -> Result<Vec<String>> {
        if self.key.is_empty() {
            return Err(anyhow!("No API key set. Add your Blablador API key in Settings."));
        }
        let response = self.client.get(self.url("models")).bearer_auth(&self.key).timeout(Duration::from_secs(30)).send().await?;
        let value: Value = Self::checked(response).await?.json().await?;
        let excluded = ["embedding", "rerank", "whisper", "flux", "image", "video", "voice", "davinci", "anonymizer"];
        let mut ids: Vec<String> = value["data"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|m| m["id"].as_str().map(String::from))
            .filter(|id| !excluded.iter().any(|word| id.to_lowercase().contains(word)))
            .collect();
        ids.sort_by_key(|id| id.to_lowercase());
        Ok(ids)
    }

    pub async fn embeddings(&self, texts: &[String], model: &str) -> Result<Vec<Vec<f32>>> {
        let request = self.post("embeddings", &json!({ "model": model, "input": texts }), Duration::from_secs(45))?;
        let value: Value = Self::checked(request.send().await?).await?.json().await?;
        let mut items: Vec<(u64, Vec<f32>)> = value["data"]
            .as_array()
            .ok_or_else(|| anyhow!("No embeddings in the answer."))?
            .iter()
            .map(|item| {
                let vector = item["embedding"].as_array().into_iter().flatten().filter_map(|v| v.as_f64()).map(|v| v as f32).collect();
                (item["index"].as_u64().unwrap_or(0), vector)
            })
            .collect();
        items.sort_by_key(|(index, _)| *index);
        Ok(items.into_iter().map(|(_, vector)| vector).collect())
    }

    /// Document indices, most relevant first.
    pub async fn rerank(&self, query: &str, documents: &[String]) -> Result<Vec<usize>> {
        let body = json!({ "model": RERANK_MODEL, "query": query, "documents": documents });
        let value: Value = Self::checked(self.post("rerank", &body, Duration::from_secs(60))?.send().await?).await?.json().await?;
        let mut results: Vec<(usize, f64)> = value["results"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|r| (r["index"].as_u64().unwrap_or(0) as usize, r["relevance_score"].as_f64().unwrap_or(0.0)))
            .collect();
        results.sort_by(|a, b| b.1.total_cmp(&a.1));
        Ok(results.into_iter().map(|(index, _)| index).collect())
    }

    /// One reply without tools, as text.
    pub async fn complete(&self, model: &str, system: &str, user: &str) -> Result<String> {
        let messages = [json!({ "role": "system", "content": system }), json!({ "role": "user", "content": user })];
        let mut text = String::new();
        self.stream_chat(model, &messages, &[], &[Map::new()], |event| {
            if let StreamEvent::Content(delta) = event {
                text.push_str(&delta)
            }
        })
        .await?;
        Ok(text)
    }

    /// Streams a chat completion. `candidates` are extra request fields to try in order (see effort.rs); the next
    /// is tried when the server answers 400 or 422. Returns the index of the one that was accepted.
    pub async fn stream_chat(
        &self,
        model: &str,
        messages: &[Value],
        tools: &[Value],
        candidates: &[Map<String, Value>],
        mut on_event: impl FnMut(StreamEvent),
    ) -> Result<usize> {
        let mut body = json!({ "model": model, "messages": messages, "stream": true });
        if !tools.is_empty() {
            body["tools"] = json!(tools);
        }
        let timeout = if self.timeout_minutes == 0 { Duration::from_secs(7 * 24 * 3600) } else { Duration::from_secs(self.timeout_minutes * 60) };
        let fallback = [Map::new()];
        let candidates = if candidates.is_empty() { &fallback[..] } else { candidates };

        // Ask for token counts at the end of the stream; a server that rejects the option gets every candidate
        // again without it, and isn't asked again while the app runs.
        let ask_usage = !usage_rejected().lock().unwrap().contains(&self.endpoint);
        let mut attempts: Vec<(usize, bool)> = Vec::new();
        if ask_usage {
            attempts.extend((0..candidates.len()).map(|i| (i, true)));
        }
        attempts.extend((0..candidates.len()).map(|i| (i, false)));
        let mut accepted = None;
        for (attempt, &(index, with_usage)) in attempts.iter().enumerate() {
            let mut request_body = body.clone();
            for (key, value) in &candidates[index] {
                request_body[key] = value.clone();
            }
            if with_usage {
                request_body["stream_options"] = json!({ "include_usage": true });
            }
            let response = self.post("chat/completions", &request_body, timeout)?.header("Accept", "text/event-stream").send().await?;
            let status = response.status().as_u16();
            if (status == 400 || status == 422) && attempt + 1 < attempts.len() {
                continue;
            }
            let response = Self::checked(response).await?;
            if ask_usage && !with_usage {
                usage_rejected().lock().unwrap().insert(self.endpoint.clone());
            }
            accepted = Some((index, response));
            break;
        }
        let (index, response) = accepted.ok_or_else(|| anyhow!("The server refused the request."))?;

        let mut calls: Vec<(u64, ToolCall)> = Vec::new();
        let mut last_usage: Option<(u64, u64)> = None;
        let mut buffer = Vec::<u8>::new();
        let mut stream = response.bytes_stream();
        'reading: while let Some(piece) = stream.next().await {
            buffer.extend_from_slice(&piece?);
            while let Some(end) = buffer.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = buffer.drain(..=end).collect();
                let line = String::from_utf8_lossy(&line);
                let Some(payload) = line.trim().strip_prefix("data:") else { continue };
                let payload = payload.trim();
                if payload == "[DONE]" {
                    break 'reading;
                }
                let Ok(chunk) = serde_json::from_str::<Value>(payload) else { continue };
                // Some servers repeat running totals in many chunks: only the last one counts.
                if let Some(usage) = chunk.get("usage").filter(|u| u.is_object()) {
                    last_usage = Some((usage["prompt_tokens"].as_u64().unwrap_or(0), usage["completion_tokens"].as_u64().unwrap_or(0)));
                }
                let delta = &chunk["choices"][0]["delta"];
                if let Some(thinking) = delta["reasoning_content"].as_str().or(delta["reasoning"].as_str()) {
                    if !thinking.is_empty() {
                        on_event(StreamEvent::Reasoning(thinking.into()));
                    }
                }
                if let Some(content) = delta["content"].as_str() {
                    if !content.is_empty() {
                        on_event(StreamEvent::Content(content.into()));
                    }
                }
                for call in delta["tool_calls"].as_array().into_iter().flatten() {
                    let position = call["index"].as_u64().unwrap_or(0);
                    let current = match calls.iter_mut().find(|(p, _)| *p == position) {
                        Some((_, current)) => current,
                        None => {
                            calls.push((position, ToolCall::default()));
                            &mut calls.last_mut().unwrap().1
                        }
                    };
                    if let Some(id) = call["id"].as_str() {
                        current.id = id.into();
                    }
                    if let Some(name) = call["function"]["name"].as_str() {
                        current.name.push_str(name);
                    }
                    if let Some(arguments) = call["function"]["arguments"].as_str() {
                        current.arguments.push_str(arguments);
                    }
                }
            }
        }
        if !calls.is_empty() {
            calls.sort_by_key(|(position, _)| *position);
            on_event(StreamEvent::ToolCalls(calls.into_iter().map(|(_, call)| call).collect()));
        }
        if let Some((prompt, completion)) = last_usage {
            on_event(StreamEvent::Usage { prompt, completion });
        }
        Ok(index)
    }
}

/// Endpoints that refused `stream_options.include_usage` (token counts).
fn usage_rejected() -> &'static std::sync::Mutex<std::collections::HashSet<String>> {
    static REJECTED: std::sync::OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> = std::sync::OnceLock::new();
    REJECTED.get_or_init(Default::default)
}
