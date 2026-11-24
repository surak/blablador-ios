//! /btw: a question asked aside while a long reply is being written. It is answered in a chat of its own,
//! reading the open chat up to the point where that reply started, so the reply itself is not disturbed.

use crate::api::{Api, StreamEvent};
use crate::chat::{self, Events};
use crate::model::{Conversation, Message, Role};
use crate::tools;
use serde_json::{json, Map, Value};
use std::time::{Duration, Instant};
use uuid::Uuid;

/// Tool rounds for one aside: a question asked aside wants an answer quickly.
pub const MAX_ROUNDS: usize = 4;
/// The card on screen is updated at most this often while the answer streams.
const STREAM_INTERVAL: Duration = Duration::from_millis(80);

/// A question asked aside, as the card in the window shows it.
#[derive(Clone, Debug)]
pub struct Aside {
    pub id: Uuid,
    pub question: String,
    /// The chat the aside was asked in.
    pub chat: Uuid,
    pub answer: String,
    /// Shows it is still being answered: a potato verb, "Searching the web…".
    pub status: Option<String>,
    pub is_error: bool,
    /// The chat the answer was kept in, once it has one.
    pub answer_chat: Option<Uuid>,
}

impl Aside {
    pub fn new(question: impl Into<String>, chat: Uuid) -> Aside {
        Aside {
            id: Uuid::new_v4(),
            question: question.into(),
            chat,
            answer: String::new(),
            status: Some(format!("{}…", chat::potato_verb())),
            is_error: false,
            answer_chat: None,
        }
    }

    /// The answer as the card shows it.
    pub fn shown(&self) -> &str {
        self.answer.trim()
    }
}

/// The question in "/btw <text>"; "" for a bare /btw; None when the text isn't the command.
pub fn command(text: &str) -> Option<String> {
    let trimmed = text.trim();
    let lower = trimmed.to_lowercase();
    if lower != "/btw" && !lower.starts_with("/btw ") && !lower.starts_with("/btw\n") {
        return None;
    }
    Some(trimmed["/btw".len()..].trim().to_string())
}

/// How the model is asked, with what was said in the chat before: the aside shares the chat up to the
/// question the long reply is answering, and never sees that reply, which is only half written.
pub fn prompt(question: &str, context: &[Value]) -> Vec<Value> {
    let system = "The user asks you something aside (/btw) while you are writing a longer answer in the chat; \
        the question is answered on its own, so it must not be about finishing that answer. Answer briefly and \
        directly, in the user's language, with a tool only when the question really needs one. What was said in \
        the chat before is below for context; the answer you are writing there is not part of it.";
    let mut messages = vec![json!({ "role": "system", "content": system })];
    messages.extend(context.iter().cloned());
    messages.push(json!({ "role": "user", "content": question }));
    messages
}

const RESUME: &str = "While you were writing, the user asked something aside (in a separate window): \"{{question}}\". \
    That is answered separately and is not part of this answer. Don't answer it here; continue your answer where \
    it stopped and finish it.";

/// What the reply that keeps running is told, so the aside doesn't pull it off its task.
pub fn resume_note(question: &str) -> String {
    RESUME.replace("{{question}}", &question.chars().take(500).collect::<String>())
}

/// What one aside needs to be answered.
pub struct Turn {
    pub api: Api,
    pub model: String,
    pub aside: Aside,
    /// The chat's messages up to where the long reply started, on the wire.
    pub context: Vec<Value>,
    /// Whether web tools may be used to look the answer up.
    pub web: bool,
}

/// Answers the aside, telling the window how it is doing.
pub async fn run(turn: Turn, events: Events) {
    let started = Instant::now();
    let mut aside = turn.aside.clone();
    let mut context = turn.context.clone();
    let mut tools_used = Vec::new();
    let mut error: Option<String> = None;
    let mut answer = String::new();

    let tool_list = if turn.web { vec![tools::web_search_tool(), tools::read_page_tool()] } else { Vec::new() };
    for round in 0..MAX_ROUNDS {
        let mut text = String::new();
        let mut shown = Instant::now() - STREAM_INTERVAL;
        let mut found = Vec::new();
        let streamed = turn
            .api
            .stream_chat(&turn.model, &prompt(&aside.question, &context), &tool_list, &[Map::new()], |event| {
                match event {
                    StreamEvent::Content(delta) => text.push_str(&delta),
                    StreamEvent::ToolCalls(found_calls) => found = found_calls,
                    StreamEvent::Reasoning(_) | StreamEvent::Usage { .. } => {}
                }
                if shown.elapsed() >= STREAM_INTERVAL {
                    shown = Instant::now();
                    aside.answer = chat::split_thinking(&text).1;
                    aside.status = None;
                    events.send(chat::Event::Aside(aside.clone()));
                }
            })
            .await;
        match streamed {
            Ok(_) => {}
            Err(failure) => {
                error = Some(format!("{failure:#}"));
                break;
            }
        }
        answer = chat::split_thinking(&text).1.trim().to_string();
        let calls = found;
        if calls.is_empty() || round == MAX_ROUNDS - 1 {
            break;
        }
        context.push(json!({
            "role": "assistant",
            "content": if answer.is_empty() { Value::Null } else { Value::String(answer.clone()) },
            "tool_calls": calls.iter().map(|c| c.wire()).collect::<Vec<_>>(),
        }));
        for call in &calls {
            let arguments: Value = serde_json::from_str(&call.arguments).unwrap_or(json!({}));
            aside.status = status(&call.name, &arguments);
            aside.answer = answer.clone();
            events.send(chat::Event::Aside(aside.clone()));
            let (output, state) = execute(&call.name, &arguments).await;
            tools_used.push(crate::model::Step {
                id: Uuid::new_v4(),
                tool: call.name.clone(),
                arguments: call.arguments.clone(),
                result: output.chars().take(4_000).collect(),
                state,
            });
            context.push(json!({ "role": "tool", "tool_call_id": call.id, "content": output }));
        }
        answer.clear();
    }

    aside.answer = match (&error, answer.is_empty()) {
        (Some(message), _) => message.clone(),
        (None, true) if tools_used.is_empty() => "No answer.".into(),
        (None, true) => aside.answer.clone(),
        (None, false) => answer.clone(),
    };
    aside.is_error = error.is_some();
    aside.status = None;
    let _ = started;
    events.send(chat::Event::AsideDone { aside: aside.clone(), context, steps: tools_used });
}

fn status(tool: &str, arguments: &Value) -> Option<String> {
    let text = |key: &str| arguments[key].as_str().unwrap_or("").to_string();
    match tool {
        "web_search" => Some(format!("Searching “{}”…", text("query"))),
        "read_page" => Some(format!("Reading {}…", text("url"))),
        _ => Some(format!("Using {tool}…")),
    }
}

/// An aside may only look things up: nothing that changes anything.
async fn execute(tool: &str, arguments: &Value) -> (String, crate::model::StepState) {
    use crate::model::StepState;
    let result = match tool {
        "web_search" => tools::web_search(arguments).await,
        "read_page" => tools::read_page(arguments).await,
        _ => return (format!("A question asked aside can't use {tool}. Answer with what you know."), StepState::Denied),
    };
    match result {
        Ok(output) => (output, StepState::Done),
        Err(failure) => (format!("Error: {failure:#}"), StepState::Failed),
    }
}

/// What a wire message held, as a message, for the aside's chat (pictures stay a note).
pub fn context_messages(context: &[Value]) -> Vec<Message> {
    context
        .iter()
        .filter_map(|wire| {
            let role = match wire["role"].as_str()? {
                "user" => Role::User,
                "assistant" => Role::Assistant,
                _ => return None,
            };
            let content = match &wire["content"] {
                Value::String(text) => text.clone(),
                Value::Array(parts) => {
                    let mut texts: Vec<String> = parts.iter().filter_map(|p| p["text"].as_str().map(String::from)).collect();
                    let pictures = parts.iter().filter(|p| p["type"].as_str() == Some("image_url")).count();
                    if pictures > 0 {
                        texts.push(format!("[{pictures} picture(s)]"));
                    }
                    texts.join("\n")
                }
                _ => String::new(),
            };
            (!content.is_empty()).then(|| Message::new(role, content))
        })
        .collect()
}

/// Saves an aside as a chat of its own: the question, the answer, and what was said in the chat it was asked
/// in, so it reads on its own and a follow-up has the context.
pub fn keep(aside: &Aside, origin: &str, model: &str, context: &[Value], steps: Vec<crate::model::Step>) -> Conversation {
    let mut conversation = Conversation::new();
    conversation.title = title(&aside.question);
    let mut asked = Message::new(Role::User, aside.question.clone());
    asked.aside_of = Some(origin.to_string());
    let mut reply = Message::new(Role::Assistant, aside.answer.clone());
    reply.error = aside.is_error.then(|| "The answer failed.".to_string());
    reply.model = Some(model.to_string());
    reply.steps = steps;
    conversation.messages = vec![asked, reply];
    conversation.context = context_messages(context);
    conversation
}

/// The first line of a question, as a chat title.
pub fn title(text: &str) -> String {
    let first = text.lines().next().unwrap_or(text);
    if first.chars().count() > 40 { first.chars().take(40).collect::<String>() + "…" } else { first.to_string() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_command() {
        assert_eq!(command("/btw what is JUPITER?").as_deref(), Some("what is JUPITER?"));
        assert_eq!(command("  /BTW  Write it in German ").as_deref(), Some("Write it in German"));
        assert_eq!(command("/btw\nand that?").as_deref(), Some("and that?"));
        assert_eq!(command("/btw").as_deref(), Some(""));
        assert_eq!(command("/btwish"), None);
        assert_eq!(command("so /btw what"), None);
        assert_eq!(command("/goal do it"), None);
    }

    /// The note that keeps the long reply on its own task names the aside, so the model can ignore it.
    #[test]
    fn resume_note_names_the_question() {
        let note = resume_note("what is JUPITER?");
        assert!(note.contains("what is JUPITER?"));
        assert!(!note.contains("{{question}}"));
        // A model that quotes the question at length can't push its own answer out of the window.
        assert!(resume_note(&"x".repeat(5_000)).chars().count() < 1_000);
    }

    /// The aside reads the chat up to where the long reply started, and never that reply itself.
    #[test]
    fn prompt_puts_the_question_last() {
        let context = vec![json!({ "role": "user", "content": "Write a long report." })];
        let prompt = prompt("And what is JUPITER?", &context);
        assert_eq!(prompt.first().unwrap()["role"], "system");
        assert!(prompt.first().unwrap()["content"].as_str().unwrap().contains("aside"));
        assert_eq!(prompt.last().unwrap()["content"], "And what is JUPITER?");
    }

    /// A kept aside chat carries the chat it came from, so it can be followed up like any other.
    #[test]
    fn kept_chat_carries_its_context() {
        let mut aside = Aside::new("And what is JUPITER?", Uuid::new_v4());
        aside.answer = "A JUWELS Booster partition at JSC.".into();
        let context = vec![
            json!({ "role": "user", "content": "Write a long report on our clusters." }),
            json!({ "role": "assistant", "content": "Here is the first part…" }),
        ];
        let conversation = keep(&aside, "Clusters", "m", &context, vec![]);
        assert_eq!(conversation.messages.len(), 2);
        assert_eq!(conversation.messages[0].aside_of.as_deref(), Some("Clusters"));
        assert_eq!(conversation.context.len(), 2);
        assert_eq!(conversation.context[1].content, "Here is the first part…");
    }

    #[test]
    fn pictures_in_the_context_become_a_note() {
        let context = vec![json!({ "role": "user", "content": [
            { "type": "text", "text": "look" },
            { "type": "image_url", "image_url": { "url": "data:x" } }
        ] })];
        let messages = context_messages(&context);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].content, "look\n[1 picture(s)]");
    }
}
