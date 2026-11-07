//! Writing a reply: the system prompt, knowledge search, streaming, and tool rounds. Runs on the tokio
//! runtime and reports to the window through `Events`.

use crate::api::{self, Api, StreamEvent};
use crate::effort::Effort;
use crate::knowledge::{self, KnowledgeBase};
use crate::model::{Conversation, Message, MemoryStore, Role, Settings, Step, StepState};
use crate::tools;
use anyhow::Result;
use serde_json::{json, Map, Value};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::oneshot;
use uuid::Uuid;

/// Tool rounds before the model is told to answer with what it has.
const MAX_ROUNDS: usize = 8;
/// The reply on screen is updated at most this often while it streams.
const STREAM_INTERVAL: Duration = Duration::from_millis(80);

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Approval {
    Allow,
    AllowForChat,
    Deny,
}

pub enum Event {
    /// The reply as it is now.
    Reply { chat: Uuid, message: Message },
    Done { chat: Uuid, message: Message },
    Approval { chat: Uuid, command: String, folder: String, reply: oneshot::Sender<Approval> },
    Title { chat: Uuid, title: String },
    Models(Result<Vec<String>, String>),
    EffortWorked { model: String, level: Effort, index: usize },
    MemoriesChanged,
    KnowledgeProgress { base: Uuid, text: Option<String> },
    KnowledgeAdded { base: Uuid, document: knowledge::Document, model: String },
    Error(String),
}

/// Sends events to the window and wakes it up.
#[derive(Clone)]
pub struct Events {
    pub sender: std::sync::mpsc::Sender<Event>,
    pub context: eframe::egui::Context,
}

impl Events {
    pub fn send(&self, event: Event) {
        let _ = self.sender.send(event);
        self.context.request_repaint();
    }
}

pub struct Turn {
    pub api: Api,
    pub model: String,
    pub effort: Option<Effort>,
    pub candidates: Vec<Map<String, Value>>,
    pub settings: Settings,
    pub chat: Uuid,
    /// The chat's messages up to and including the question.
    pub history: Vec<Message>,
    /// Earlier chats, for search_chats.
    pub other_chats: Vec<Conversation>,
    pub knowledge: Vec<KnowledgeBase>,
    pub memory: Arc<Mutex<MemoryStore>>,
    pub commands_allowed: bool,
    pub needs_title: bool,
    pub reply: Message,
}

/// `<think>…</think>` at the start of a reply, as some models send their thinking.
pub fn split_thinking(text: &str) -> (String, String) {
    let trimmed = text.trim_start();
    let Some(body) = trimmed.strip_prefix("<think>") else { return (String::new(), text.to_string()) };
    match body.find("</think>") {
        Some(end) => (body[..end].to_string(), body[end + 8..].trim().to_string()),
        None => (body.to_string(), String::new()),
    }
}

fn joined(earlier: &str, new: &str) -> String {
    if earlier.is_empty() { new.to_string() } else if new.is_empty() { earlier.to_string() } else { format!("{earlier}\n\n{new}") }
}

fn wire(message: &Message) -> Value {
    let role = if message.role == Role::User { "user" } else { "assistant" };
    let mut content = message.content.clone();
    for file in &message.attachments {
        content += &format!("\n\n[Attached file: {}]\n```\n{}\n```", file.name, file.text);
    }
    json!({ "role": role, "content": content })
}

pub async fn run(mut turn: Turn, events: Events) {
    let mut reply = turn.reply.clone();
    let outcome = write_reply(&mut turn, &mut reply, &events).await;
    reply.status = None;
    match &outcome {
        Err(error) => reply.error = Some(format!("{error:#}")),
        Ok(_) if reply.content.trim().is_empty() && reply.steps.is_empty() => reply.error = Some("The model sent an empty answer.".into()),
        _ => {}
    }
    events.send(Event::Done { chat: turn.chat, message: reply.clone() });

    let question = turn.history.last().map(|m| m.content.clone()).unwrap_or_default();
    let helper = turn.api.helper_model(&turn.model);
    if turn.needs_title && !question.trim().is_empty() {
        let system = "Write a title of at most six words for a chat that starts with this message. Answer with the title only, without quotes.";
        if let Ok(answer) = turn.api.complete(&helper, system, &question).await {
            let title = split_thinking(&answer).1.trim().trim_matches('"').lines().next().unwrap_or("").to_string();
            if !title.is_empty() {
                events.send(Event::Title { chat: turn.chat, title: title.chars().take(60).collect() });
            }
        }
    }
    // Facts from a reply that read outside content are learned from the user's own words only.
    if turn.settings.learn && turn.settings.memory && reply.error.is_none() {
        let outside = outcome.unwrap_or(true);
        let exchange = if outside { format!("User: {question}") } else { format!("User: {question}\n\nAssistant: {}", reply.content) };
        learn(&turn.api, &helper, &exchange, &turn.memory, &events).await;
    }
}

/// Asks the helper model which lasting facts about the user the exchange holds, and saves them.
async fn learn(api: &Api, model: &str, exchange: &str, memory: &Arc<Mutex<MemoryStore>>, events: &Events) {
    let known: Vec<String> = memory.lock().unwrap().memories.iter().map(|m| format!("- {}", m.text)).collect();
    let system = format!(
        "You pick out lasting facts about the user (name, job, preferences, ongoing projects) from a chat exchange. Answer with a JSON array of short third-person sentences, or [] when there is nothing new. Never include passwords, keys or other secrets, and skip what is already known:\n{}",
        known.join("\n")
    );
    let Ok(answer) = api.complete(model, &system, exchange).await else { return };
    let answer = split_thinking(&answer).1;
    let (Some(start), Some(end)) = (answer.find('['), answer.rfind(']')) else { return };
    let Ok(facts) = serde_json::from_str::<Vec<String>>(&answer[start..=end.max(start)]) else { return };
    let mut store = memory.lock().unwrap();
    if facts.iter().take(5).fold(false, |added, fact| store.add(fact) || added) {
        events.send(Event::MemoriesChanged);
    }
}

/// Returns whether the reply read outside content (web pages, files, command output).
async fn write_reply(turn: &mut Turn, reply: &mut Message, events: &Events) -> Result<bool> {
    let chat = turn.chat;
    let question = turn.history.last().map(|m| m.content.clone()).unwrap_or_default();
    let mut outside = turn.history.last().is_some_and(|m| !m.attachments.is_empty());

    let mut system = format!(
        "You are Blablador, a helpful assistant from Forschungszentrum Jülich. Today is {}. Answer in the user's language and use Markdown.",
        chrono::Local::now().format("%A, %-d %B %Y")
    );
    if !turn.settings.instructions.trim().is_empty() {
        system += &format!("\n\nThe user's instructions:\n{}", turn.settings.instructions.trim());
    }
    if turn.settings.web_search {
        system += tools::WEB_PROMPT;
    }
    if turn.settings.memory {
        system += &format!("\n\n{}", turn.memory.lock().unwrap().system_prompt(&question));
    }
    if !turn.knowledge.is_empty() {
        reply.status = Some("Searching knowledge…".into());
        events.send(Event::Reply { chat, message: reply.clone() });
        match knowledge::search(&turn.api, &question, &turn.knowledge).await {
            Ok(citations) if !citations.is_empty() => {
                system += &format!("\n\n{}", knowledge::context(&citations));
                reply.citations = citations;
                outside = true;
            }
            Ok(_) => {}
            Err(error) => events.send(Event::Error(format!("Knowledge search failed: {error:#}"))),
        }
    }

    let mut messages = vec![json!({ "role": "system", "content": system })];
    messages.extend(turn.history.iter().filter(|m| m.error.is_none() || m.role == Role::User).map(wire));

    let mut tool_list = Vec::new();
    if turn.settings.web_search {
        tool_list.extend([tools::web_search_tool(), tools::read_page_tool()]);
    }
    if turn.settings.memory {
        tool_list.extend([tools::remember_tool(), tools::forget_tool()]);
    }
    if turn.settings.search_chats {
        tool_list.push(tools::search_chats_tool());
    }
    let folder = turn.settings.workspace.clone().map(PathBuf::from).filter(|f| f.is_dir());
    if turn.settings.commands && folder.is_some() {
        tool_list.push(tools::run_command_tool());
    }

    let mut round = 0;
    loop {
        round += 1;
        let final_round = round > MAX_ROUNDS;
        if final_round {
            // Keep the tools declared (removing them makes some models print raw tool markup),
            // but tell the model to answer with what it has.
            messages.push(json!({ "role": "user", "content": "Stop using tools now and write the final answer using the results above." }));
        }
        let prefix = reply.content.clone();
        let reasoning_prefix = reply.reasoning.clone();
        let mut text = String::new();
        let mut reasoning = String::new();
        let mut calls = Vec::new();
        let mut shown = Instant::now() - STREAM_INTERVAL;
        let mut show = |reply: &mut Message, text: &str, reasoning: &str, force: bool| {
            if !force && shown.elapsed() < STREAM_INTERVAL {
                return;
            }
            shown = Instant::now();
            let (thinking, answer) = split_thinking(text);
            reply.status = None;
            reply.content = prefix.clone() + &answer;
            reply.reasoning = joined(&reasoning_prefix, &(reasoning.to_string() + &thinking));
            events.send(Event::Reply { chat, message: reply.clone() });
        };
        let candidates = if turn.effort.is_some() { turn.candidates.clone() } else { vec![Map::new()] };
        let streamed = turn
            .api
            .stream_chat(&turn.model, &messages, &tool_list, &candidates, |event| match event {
                StreamEvent::Content(delta) => {
                    text += &delta;
                    show(reply, &text, &reasoning, false);
                }
                StreamEvent::Reasoning(delta) => {
                    reasoning += &delta;
                    show(reply, &text, &reasoning, false);
                }
                StreamEvent::ToolCalls(found) => calls = found,
                StreamEvent::Usage { prompt, completion } => {
                    let (p, c) = reply.tokens.unwrap_or((0, 0));
                    reply.tokens = Some((p + prompt, c + completion));
                }
            })
            .await;
        match streamed {
            Ok(index) => {
                if let Some(level) = turn.effort {
                    if index > 0 {
                        events.send(Event::EffortWorked { model: turn.model.clone(), level, index });
                        // The accepted way goes first from now on.
                        let accepted = turn.candidates.remove(index);
                        turn.candidates.insert(0, accepted);
                    }
                }
            }
            Err(error) => {
                let body = error.downcast_ref::<api::HttpError>().map(|e| e.body.to_lowercase()).unwrap_or_default();
                if api::http_status(&error) == Some(400) && !tool_list.is_empty() && round == 1 && !body.contains("image") {
                    // A model without tool support: answer without tools.
                    tool_list.clear();
                    continue;
                }
                return Err(error);
            }
        }
        show(reply, &text, &reasoning, true);

        if calls.is_empty() || final_round {
            return Ok(outside);
        }
        messages.push(json!({
            "role": "assistant",
            "content": if text.is_empty() { Value::Null } else { Value::String(text.clone()) },
            "tool_calls": calls.iter().map(|c| c.wire()).collect::<Vec<_>>(),
        }));
        // Preambles like "Let me look that up" are status, not part of the answer.
        reply.content = prefix;

        for call in calls {
            let arguments: Value = serde_json::from_str(&call.arguments).unwrap_or(json!({}));
            let step_id = Uuid::new_v4();
            reply.steps.push(Step { id: step_id, tool: call.name.clone(), arguments: call.arguments.clone(), result: String::new(), state: StepState::Running });
            reply.status = Some(status(&call.name, &arguments));
            events.send(Event::Reply { chat, message: reply.clone() });

            let (output, state) = execute(turn, &call.name, &arguments, folder.as_ref(), &mut outside, events).await;
            if let Some(step) = reply.steps.iter_mut().find(|s| s.id == step_id) {
                step.result = output.chars().take(4_000).collect();
                step.state = state;
            }
            messages.push(json!({ "role": "tool", "tool_call_id": call.id, "content": output }));
        }
        reply.status = Some("Thinking…".into());
        events.send(Event::Reply { chat, message: reply.clone() });
    }
}

fn status(tool: &str, arguments: &Value) -> String {
    let text = |key: &str| arguments[key].as_str().unwrap_or("").to_string();
    match tool {
        "web_search" => format!("Searching the web for “{}”…", text("query")),
        "read_page" => format!("Reading {}…", text("url")),
        "remember" => "Remembering…".into(),
        "forget" => "Forgetting…".into(),
        "search_chats" => "Looking through earlier chats…".into(),
        "run_command" => format!("Running {}…", text("command")),
        _ => format!("Using {tool}…"),
    }
}

async fn execute(turn: &mut Turn, tool: &str, arguments: &Value, folder: Option<&PathBuf>, outside: &mut bool, events: &Events) -> (String, StepState) {
    let result = match tool {
        "web_search" => {
            *outside = true;
            tools::web_search(arguments).await
        }
        "read_page" => {
            *outside = true;
            tools::read_page(arguments).await
        }
        "remember" | "forget" if *outside => {
            // Text from the web or a file could otherwise plant memories.
            return ("Memory can't be changed in a reply that read web pages, files or command output. Ask the user to tell you directly.".into(), StepState::Denied);
        }
        "remember" => {
            let fact = arguments["fact"].as_str().unwrap_or("");
            let added = turn.memory.lock().unwrap().add(fact);
            events.send(Event::MemoriesChanged);
            Ok(if added { format!("Remembered: {fact}") } else { "Already remembered.".into() })
        }
        "forget" => {
            let number = arguments["number"].as_u64().or_else(|| arguments["number"].as_str().and_then(|s| s.parse().ok())).unwrap_or(0);
            let removed = turn.memory.lock().unwrap().forget(number as usize);
            events.send(Event::MemoriesChanged);
            Ok(removed.map_or(format!("There is no memory number {number}."), |m| format!("Forgot: {}", m.text)))
        }
        "search_chats" => Ok(tools::search_chats(arguments["query"].as_str().unwrap_or(""), &turn.other_chats)),
        "run_command" => {
            let (Some(folder), true) = (folder, turn.settings.commands) else {
                return ("Running commands is turned off.".into(), StepState::Denied);
            };
            let command = arguments["command"].as_str().unwrap_or("").to_string();
            if !turn.commands_allowed {
                let (sender, receiver) = oneshot::channel();
                events.send(Event::Approval { chat: turn.chat, command: command.clone(), folder: folder.display().to_string(), reply: sender });
                match receiver.await.unwrap_or(Approval::Deny) {
                    Approval::Deny => return ("The user declined to run this command.".into(), StepState::Denied),
                    Approval::AllowForChat => turn.commands_allowed = true,
                    Approval::Allow => {}
                }
            }
            *outside = true;
            tools::run_command(&command, folder).await
        }
        _ => Err(anyhow::anyhow!("There is no tool called {tool}.")),
    };
    match result {
        Ok(output) => (output, StepState::Done),
        Err(error) => (format!("Error: {error:#}"), StepState::Failed),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_thinking() {
        assert_eq!(split_thinking("<think>hm</think>\n\nYes"), ("hm".into(), "Yes".into()));
        assert_eq!(split_thinking("<think>still"), ("still".into(), String::new()));
        assert_eq!(split_thinking("Plain"), (String::new(), "Plain".into()));
    }
}
