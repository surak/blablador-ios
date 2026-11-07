//! Chats, messages, settings and long-term memory, with their encrypted storage.

use crate::{api, storage};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    User,
    Assistant,
}

/// A file attached to a question, as the text the model reads.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Attachment {
    pub name: String,
    pub text: String,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum StepState {
    Running,
    Done,
    Failed,
    Denied,
}

/// A tool call made while answering.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Step {
    pub id: Uuid,
    pub tool: String,
    pub arguments: String,
    pub result: String,
    pub state: StepState,
}

/// A knowledge base passage used to answer.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Citation {
    pub document: String,
    pub page: Option<u32>,
    pub text: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Message {
    pub id: Uuid,
    pub role: Role,
    pub content: String,
    #[serde(default)]
    pub reasoning: String,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
    #[serde(default)]
    pub steps: Vec<Step>,
    #[serde(default)]
    pub citations: Vec<Citation>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub tokens: Option<(u64, u64)>,
    pub created: DateTime<Utc>,
    /// "Searching the web…" and the like while the reply is being written; not saved.
    #[serde(skip)]
    pub status: Option<String>,
}

impl Message {
    pub fn new(role: Role, content: impl Into<String>) -> Message {
        Message {
            id: Uuid::new_v4(),
            role,
            content: content.into(),
            reasoning: String::new(),
            attachments: vec![],
            steps: vec![],
            citations: vec![],
            error: None,
            model: None,
            tokens: None,
            created: Utc::now(),
            status: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Conversation {
    pub id: Uuid,
    pub title: String,
    pub messages: Vec<Message>,
    /// Knowledge bases searched for every question in this chat.
    #[serde(default)]
    pub knowledge: Vec<Uuid>,
    pub created: DateTime<Utc>,
    pub updated: DateTime<Utc>,
}

impl Conversation {
    pub fn new() -> Conversation {
        let now = Utc::now();
        Conversation { id: Uuid::new_v4(), title: "New chat".into(), messages: vec![], knowledge: vec![], created: now, updated: now }
    }
}

pub fn load_chats() -> Vec<Conversation> {
    let mut chats: Vec<Conversation> = storage::read_json(&storage::path("chats.json")).unwrap_or_default();
    chats.sort_by(|a, b| b.updated.cmp(&a.updated));
    chats
}

pub fn save_chats(chats: &[Conversation]) {
    storage::write_json(&storage::path("chats.json"), &chats);
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub endpoint: String,
    pub model: String,
    /// Thinking effort per model.
    pub efforts: HashMap<String, String>,
    /// Which way of asking for an effort each model accepted (see effort.rs).
    pub effort_worked: HashMap<String, usize>,
    pub instructions: String,
    pub timeout_minutes: u64,
    pub web_search: bool,
    pub memory: bool,
    pub learn: bool,
    pub search_chats: bool,
    pub commands: bool,
    /// Folder commands run in.
    pub workspace: Option<String>,
    pub dark: bool,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            endpoint: api::DEFAULT_ENDPOINT.into(),
            model: api::DEFAULT_MODEL.into(),
            efforts: HashMap::new(),
            effort_worked: HashMap::new(),
            instructions: String::new(),
            timeout_minutes: 10,
            web_search: true,
            memory: true,
            learn: false,
            search_chats: true,
            commands: false,
            workspace: None,
            dark: true,
        }
    }
}

impl Settings {
    pub fn load() -> Settings {
        storage::read_json(&storage::path("settings.json")).unwrap_or_default()
    }

    pub fn save(&self) {
        storage::write_json(&storage::path("settings.json"), self);
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Memory {
    pub id: Uuid,
    pub text: String,
    pub created: DateTime<Utc>,
}

/// Long-term memory: facts about the user that every chat sees, numbered so the model can forget one.
#[derive(Default)]
pub struct MemoryStore {
    pub memories: Vec<Memory>,
}

impl MemoryStore {
    pub const MAX: usize = 500;
    /// Up to this many memories are always sent; beyond it only those sharing words with the question.
    const ALWAYS_SENT: usize = 30;

    pub fn load() -> MemoryStore {
        MemoryStore { memories: storage::read_json(&storage::path("memories.json")).unwrap_or_default() }
    }

    fn save(&self) {
        storage::write_json(&storage::path("memories.json"), &self.memories);
    }

    pub fn add(&mut self, text: &str) -> bool {
        let text = text.trim();
        if text.is_empty() || self.memories.iter().any(|m| m.text.eq_ignore_ascii_case(text)) {
            return false;
        }
        self.memories.push(Memory { id: Uuid::new_v4(), text: text.into(), created: Utc::now() });
        if self.memories.len() > Self::MAX {
            self.memories.remove(0);
        }
        self.save();
        true
    }

    pub fn forget(&mut self, number: usize) -> Option<Memory> {
        if number == 0 || number > self.memories.len() {
            return None;
        }
        let removed = self.memories.remove(number - 1);
        self.save();
        Some(removed)
    }

    pub fn delete(&mut self, id: Uuid) {
        self.memories.retain(|m| m.id != id);
        self.save();
    }

    pub fn system_prompt(&self, question: &str) -> String {
        let mut prompt = String::from("You have a long-term memory of the user that lasts across chats. Call remember when the user shares something lasting about themselves (name, job, preferences, ongoing projects) or asks you to remember something; save one short fact per call, written in the third person. Call forget with a number when the user says a memory is wrong or asks you to forget it. Never save passwords, keys or other secrets.");
        if self.memories.is_empty() {
            return prompt + " You don't remember anything yet.";
        }
        let mut shown: Vec<usize> = (0..self.memories.len()).collect();
        if self.memories.len() > Self::ALWAYS_SENT {
            let asked = words(question);
            let mut scored: Vec<(usize, usize)> =
                shown.iter().map(|&i| (i, words(&self.memories[i].text).intersection(&asked).count())).filter(|(_, s)| *s > 0).collect();
            scored.sort_by(|a, b| b.1.cmp(&a.1));
            let mut keep: HashSet<usize> = scored.into_iter().take(20).map(|(i, _)| i).collect();
            keep.extend(self.memories.len().saturating_sub(10)..self.memories.len());
            shown.retain(|i| keep.contains(i));
        }
        prompt += "\n\nWhat you remember about the user:\n";
        for i in shown {
            prompt += &format!("{}. {}\n", i + 1, self.memories[i].text);
        }
        prompt
    }
}

/// Lowercased words of four letters or more, for keyword matching.
pub fn words(text: &str) -> HashSet<String> {
    text.split(|c: char| !c.is_alphanumeric()).filter(|w| w.chars().count() >= 4).map(|w| w.to_lowercase()).collect()
}
