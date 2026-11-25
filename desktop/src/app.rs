//! The window: chats on the left, the open chat in the middle, the composer at the bottom, and the
//! Settings, Knowledge and Memory windows.

use crate::api::Api;
use crate::chat::{self, Approval, Event, Events, Turn};
use crate::effort;
use crate::knowledge::{self, KnowledgeBase};
use crate::model::{self, Attachment, Conversation, Message, MemoryStore, Role, Settings, StepState};
use crate::{extract, storage};
use eframe::egui::{self, Color32, Key, RichText};
use egui_commonmark::{CommonMarkCache, CommonMarkViewer};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use tokio::sync::oneshot;
use uuid::Uuid;

struct PendingApproval {
    chat: Uuid,
    command: String,
    folder: String,
    reply: Option<oneshot::Sender<Approval>>,
}

/// Things a click asks for while the chat is being drawn, done afterwards.
enum Action {
    Regenerate,
    Copy(String),
}

pub struct App {
    runtime: tokio::runtime::Runtime,
    events: Events,
    receiver: Receiver<Event>,
    settings: Settings,
    api_key: String,
    key_draft: String,
    chats: Vec<Conversation>,
    current: Option<Uuid>,
    /// Replies being written, by chat: the reply's id and its task.
    running: HashMap<Uuid, (Uuid, tokio::task::JoinHandle<()>)>,
    models: Vec<String>,
    input: String,
    attachments: Vec<Attachment>,
    memory: Arc<Mutex<MemoryStore>>,
    bases: Vec<KnowledgeBase>,
    knowledge_progress: HashMap<Uuid, String>,
    approvals: Vec<PendingApproval>,
    /// Chats where the user chose "Allow for this chat".
    allowed_chats: HashSet<Uuid>,
    /// Questions asked aside (/btw) and their answers, shown above the composer.
    asides: Vec<crate::aside::Aside>,
    /// What the reply of each chat that keeps running must be told about asides asked meanwhile; the running
    /// turn shares it.
    aside_questions: Arc<Mutex<HashMap<Uuid, Vec<String>>>>,
    show_settings: bool,
    show_memory: bool,
    show_knowledge: bool,
    mapper: crate::mapper::Mapper,
    proteins: crate::proteins::Proteins,
    new_memory: String,
    new_base: String,
    renaming: Option<(Uuid, String)>,
    error: Option<String>,
    /// "Delete all chats" is waiting for its confirmation.
    confirm_delete_all: bool,
    /// "Forget everything" is waiting for its confirmation.
    confirm_forget_everything: bool,
    markdown: CommonMarkCache,
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>, runtime: tokio::runtime::Runtime) -> App {
        let (sender, receiver) = std::sync::mpsc::channel();
        let settings = Settings::load();
        cc.egui_ctx.set_visuals(if settings.dark { egui::Visuals::dark() } else { egui::Visuals::light() });
        add_system_fonts(&cc.egui_ctx);
        let api_key = storage::api_key();
        let mut app = App {
            runtime,
            events: Events { sender, context: cc.egui_ctx.clone() },
            receiver,
            show_settings: api_key.is_empty() && std::env::var_os("BLABLADOR_INPUT_PROBE").is_none(),
            key_draft: api_key.clone(),
            api_key,
            settings,
            chats: model::load_chats(),
            current: None,
            running: HashMap::new(),
            models: vec![],
            input: String::new(),
            attachments: vec![],
            memory: Arc::new(Mutex::new(MemoryStore::load())),
            bases: knowledge::load_bases(),
            knowledge_progress: HashMap::new(),
            approvals: vec![],
            allowed_chats: HashSet::new(),
            asides: vec![],
            aside_questions: Arc::new(Mutex::new(HashMap::new())),
            show_memory: false,
            show_knowledge: false,
            mapper: Default::default(),
            proteins: Default::default(),
            new_memory: String::new(),
            new_base: String::new(),
            renaming: None,
            error: None,
            confirm_delete_all: false,
            confirm_forget_everything: false,
            markdown: CommonMarkCache::default(),
        };
        app.current = app.chats.first().map(|c| c.id);
        app.load_models();
        app
    }

    fn api(&self) -> Api {
        Api::new(&self.settings.endpoint, &self.api_key, self.settings.timeout_minutes)
    }

    fn load_models(&self) {
        let api = self.api();
        let events = self.events.clone();
        self.runtime.spawn(async move {
            let models = api.models().await.map_err(|e| format!("{e:#}"));
            events.send(Event::Models(models));
        });
    }

    fn chat(&self, id: Uuid) -> Option<&Conversation> {
        self.chats.iter().find(|c| c.id == id)
    }

    fn chat_mut(&mut self, id: Uuid) -> Option<&mut Conversation> {
        self.chats.iter_mut().find(|c| c.id == id)
    }

    fn save_chats(&self) {
        model::save_chats(&self.chats);
    }

    fn new_chat(&mut self) {
        // Leaving a disappearing chat throws it away: it was never saved in the first place.
        self.delete_ephemeral();
        // An empty chat is reused rather than piling up.
        if let Some(empty) = self.chats.iter().find(|c| c.messages.is_empty()) {
            self.current = Some(empty.id);
            return;
        }
        let chat = Conversation::new();
        self.current = Some(chat.id);
        self.chats.insert(0, chat);
    }

    /// Starts a chat that leaves no trace: nothing is saved, not listed, not searched and nothing learned
    /// from it. It goes when the user starts another chat or closes the app.
    fn new_disappearing_chat(&mut self) {
        self.delete_ephemeral();
        let mut chat = Conversation::new();
        chat.ephemeral = true;
        chat.title = "Disappearing chat".into();
        self.current = Some(chat.id);
        self.chats.insert(0, chat);
    }

    /// Removes the disappearing chats, stopping what they were doing.
    fn delete_ephemeral(&mut self) {
        let going: Vec<Uuid> = self.chats.iter().filter(|c| c.ephemeral).map(|c| c.id).collect();
        if going.is_empty() {
            return;
        }
        for id in &going {
            self.stop(*id);
            self.asides.retain(|a| a.chat != *id);
            self.aside_questions.lock().unwrap().remove(id);
        }
        self.chats.retain(|c| !c.ephemeral);
        if self.current.is_some_and(|id| going.contains(&id)) {
            self.current = self.chats.first().map(|c| c.id);
        }
        self.save_chats();
    }

    /// The open chat is a disappearing one.
    fn is_disappearing(&self) -> bool {
        self.current.and_then(|id| self.chat(id)).is_some_and(|c| c.ephemeral)
    }

    /// Writes what a feature did into the chat history, so a protein job or a mapped room is in the history
    /// next to the questions asked around it, not only in its own window.
    fn record(&mut self, question: Option<String>, answer: String) {
        if self.current.is_none_or(|id| self.chat(id).is_none()) {
            self.new_chat();
        }
        let id = self.current.unwrap();
        let title = question.clone();
        let Some(chat) = self.chat_mut(id) else { return };
        if let Some(question) = question {
            chat.messages.push(Message::new(Role::User, question));
        }
        chat.messages.push(Message::new(Role::Assistant, answer));
        chat.updated = chrono::Utc::now();
        if chat.title == "New chat" {
            if let Some(title) = title {
                chat.title = title.chars().take(60).collect();
            }
        }
        self.save_chats();
    }

    fn handle_events(&mut self) {
        while let Ok(event) = self.receiver.try_recv() {
            match event {
                Event::Reply { chat, message } => self.replace_message(chat, message),
                Event::Done { chat, message } => {
                    self.replace_message(chat, message);
                    self.running.remove(&chat);
                    if let Some(c) = self.chat_mut(chat) {
                        c.updated = chrono::Utc::now();
                    }
                    self.save_chats();
                }
                Event::Approval { chat, command, folder, reply } => self.approvals.push(PendingApproval { chat, command, folder, reply: Some(reply) }),
                Event::Title { chat, title } => {
                    if let Some(c) = self.chat_mut(chat) {
                        c.title = title;
                    }
                    self.save_chats();
                }
                Event::Models(Ok(models)) => {
                    self.models = models;
                    self.error = None;
                }
                Event::Models(Err(error)) => self.error = Some(format!("Couldn't load the models: {error}")),
                Event::EffortWorked { model, level, index } => {
                    effort::remember(&model, level, index, &mut self.settings.effort_worked);
                    self.settings.save();
                }
                Event::MemoriesChanged => {}
                Event::KnowledgeProgress { base, text: Some(text) } => {
                    self.knowledge_progress.insert(base, text);
                }
                Event::KnowledgeProgress { base, text: None } => {
                    self.knowledge_progress.remove(&base);
                }
                Event::KnowledgeAdded { base, document, model } => {
                    if let Some(b) = self.bases.iter_mut().find(|b| b.id == base) {
                        b.documents.push(document);
                        b.embedding_model = model;
                    }
                    knowledge::save_bases(&self.bases);
                }
                Event::PictureRead { name, result } => {
                    let index = self.attachments.iter().position(|a| a.name == name && a.text == PICTURE_PENDING);
                    match (index, result) {
                        (Some(i), Ok(text)) => self.attachments[i].text = format!("[A picture, described by a vision model]\n{text}"),
                        (Some(i), Err(error)) => {
                            self.attachments.remove(i);
                            self.error = Some(error);
                        }
                        (None, _) => {}
                    }
                }
                Event::Error(error) => self.error = Some(error),
                Event::Aside(aside) => {
                    if let Some(existing) = self.asides.iter_mut().find(|a| a.id == aside.id) {
                        *existing = aside;
                    }
                }
                Event::AsideDone { aside, context, steps } => {
                    let origin = self.chat(aside.chat).map(|c| c.title.clone()).unwrap_or_else(|| "a chat".into());
                    let model = self.settings.model.clone();
                    if let Some(existing) = self.asides.iter_mut().find(|a| a.id == aside.id) {
                        *existing = aside.clone();
                    }
                    // What was asked aside is kept as a chat of its own, so it can be read again and followed
                    // up; nothing at all came back when there is no text: not worth a chat either.
                    if !aside.answer.trim().is_empty() || aside.is_error {
                        let mut conversation = crate::aside::keep(&aside, &origin, &model, &context, steps);
                        conversation.updated = chrono::Utc::now();
                        if let Some(card) = self.asides.iter_mut().find(|a| a.id == aside.id) {
                            card.answer_chat = Some(conversation.id);
                        }
                        self.chats.insert(0, conversation);
                        self.save_chats();
                    }
                }
            }
        }
    }

    fn replace_message(&mut self, chat: Uuid, message: Message) {
        if let Some(existing) = self.chat_mut(chat).and_then(|c| c.messages.iter_mut().find(|m| m.id == message.id)) {
            *existing = message;
        }
    }

    fn send(&mut self) {
        let text = self.input.trim().to_string();
        if text.is_empty() && self.attachments.is_empty() {
            return;
        }
        // /btw is answered beside the reply, not in place of it, so it may be asked while one is being
        // written. In a chat that doesn't exist yet there is nothing to ask beside: it starts the chat.
        if let Some(question) = crate::aside::command(&text) {
            if question.is_empty() {
                return;
            }
            if self.current.is_some_and(|id| self.chat(id).is_some()) {
                self.input.clear();
                self.ask_aside(question);
                return;
            }
        }
        if let Some(question) = crate::aside::command(&text) {
            // No chat yet: the question becomes the chat's first one.
            self.input = question;
        }
        if self.current.is_none_or(|id| self.chat(id).is_none()) {
            self.new_chat();
        }
        let id = self.current.unwrap();
        if self.running.contains_key(&id) {
            return;
        }
        if self.attachments.iter().any(|a| a.text == PICTURE_PENDING) {
            self.error = Some("Still looking at the picture; send again in a moment.".into());
            return;
        }
        let text = self.input.trim().to_string();
        let mut question = Message::new(Role::User, text);
        question.attachments = std::mem::take(&mut self.attachments);
        self.input.clear();
        let chat = self.chat_mut(id).unwrap();
        chat.messages.push(question);
        chat.updated = chrono::Utc::now();
        self.start_reply(id);
    }

    /// Asks a question aside: it goes into a chat of its own, with what was said in this one up to where the
    /// reply that is being written started, so the reply carries on undisturbed.
    fn ask_aside(&mut self, question: String) {
        let Some(chat_id) = self.current.filter(|id| self.chat(*id).is_some()) else { return };
        // One at a time: a second card would push the first out of sight.
        if self.asides.iter().any(|a| a.chat == chat_id && a.answer_chat.is_none()) {
            return;
        }
        let aside = crate::aside::Aside::new(question.clone(), chat_id);
        self.asides.push(aside.clone());
        // The reply that is being written is told about it before its next round, so it doesn't answer the
        // aside itself or wander off.
        if self.running.contains_key(&chat_id) {
            self.aside_questions.lock().unwrap().entry(chat_id).or_default().push(question);
        }

        let Some(chat) = self.chat(chat_id) else { return };
        let model = self.settings.model.clone();
        let busy = self.running.contains_key(&chat_id);
        let mut messages: Vec<Message> = chat.messages.iter().filter(|m| m.error.is_none() || m.role == Role::User).cloned().collect();
        // The reply being written is the last message: only half of it exists, so it is not context for the
        // aside, which is asked beside it.
        if busy && messages.last().is_some_and(|m| m.role == Role::Assistant) {
            messages.pop();
        }
        let context: Vec<serde_json::Value> = messages.iter().map(chat::wire).collect();
        let turn = crate::aside::Turn {
            api: self.api(),
            model,
            aside,
            context,
            web: self.settings.web_search,
        };
        self.runtime.spawn(crate::aside::run(turn, self.events.clone()));
    }

    /// Adds an empty reply to the chat and starts writing it.
    fn start_reply(&mut self, id: Uuid) {
        let model = self.settings.model.clone();
        let mut reply = Message::new(Role::Assistant, "");
        reply.model = Some(model.clone());
        reply.status = Some(crate::chat::potato_verb());
        let Some(chat) = self.chat(id) else { return };
        // A chat asked aside (/btw) carries the chat it came from, so a follow-up has that context.
        let history: Vec<Message> = chat.context.iter().cloned().chain(chat.messages.iter().cloned()).collect();
        let needs_title = chat.title == "New chat";
        let ephemeral = chat.ephemeral;
        let knowledge = self.bases.iter().filter(|b| chat.knowledge.contains(&b.id)).cloned().collect();
        // A disappearing chat can't quote other chats, and is never quoted by them.
        let other_chats = if ephemeral { vec![] } else { self.chats.iter().filter(|c| c.id != id && !c.ephemeral).cloned().collect() };
        let effort = effort::level(&model, &self.settings.efforts);
        let candidates = effort.map(|level| effort::candidates(&model, level, &self.settings.effort_worked)).unwrap_or_default();
        let turn = Turn {
            api: self.api(),
            model,
            effort,
            candidates,
            settings: self.settings.clone(),
            chat: id,
            history,
            other_chats,
            knowledge,
            memory: self.memory.clone(),
            commands_allowed: self.allowed_chats.contains(&id),
            needs_title,
            ephemeral,
            aside_questions: self.aside_questions.clone(),
            reply: reply.clone(),
        };
        let reply_id = reply.id;
        self.chat_mut(id).unwrap().messages.push(reply);
        self.save_chats();
        let handle = self.runtime.spawn(chat::run(turn, self.events.clone()));
        self.running.insert(id, (reply_id, handle));
    }

    fn stop(&mut self, id: Uuid) {
        let Some((reply_id, handle)) = self.running.remove(&id) else { return };
        handle.abort();
        self.approvals.retain(|a| a.chat != id);
        if let Some(reply) = self.chat_mut(id).and_then(|c| c.messages.iter_mut().find(|m| m.id == reply_id)) {
            reply.status = None;
            for step in reply.steps.iter_mut().filter(|s| s.state == StepState::Running) {
                step.state = StepState::Failed;
            }
            if reply.content.is_empty() {
                reply.error = Some("Stopped.".into());
            }
        }
        self.save_chats();
    }

    /// Deletes every chat, like the apps' "Delete all chats". The desktop app keeps no chat index —
    /// `search_chats` reads the chats themselves — so forgetting them needs nothing more.
    fn delete_all_chats(&mut self) {
        for id in self.running.keys().copied().collect::<Vec<_>>() {
            self.stop(id);
        }
        self.approvals.clear();
        self.chats.clear();
        self.current = None;
        self.save_chats();
        self.new_chat();
    }

    /// "Forget everything": the chats go and so does the memory, so in the end nothing of the user stays on
    /// the device — neither what they said in a chat nor what was learned about them from it.
    fn forget_everything(&mut self) {
        self.delete_all_chats();
        self.memory.lock().unwrap().delete_all();
    }

    fn regenerate(&mut self) {
        let Some(id) = self.current else { return };
        if self.running.contains_key(&id) {
            return;
        }
        let Some(chat) = self.chat_mut(id) else { return };
        if chat.messages.last().is_some_and(|m| m.role == Role::Assistant) {
            chat.messages.pop();
        }
        if chat.messages.last().is_some_and(|m| m.role == Role::User) {
            self.start_reply(id);
        }
    }

    fn attach(&mut self, paths: Vec<PathBuf>) {
        for path in paths {
            let name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
            if let Ok(bytes) = std::fs::read(&path) {
                if extract::is_picture(&bytes) {
                    self.read_picture(name, bytes);
                    continue;
                }
            }
            match extract::text_of(&path) {
                Ok(text) => self.attachments.push(Attachment {
                    name: path.file_name().unwrap_or_default().to_string_lossy().into(),
                    text: text.chars().take(extract::MAX_ATTACHMENT).collect(),
                }),
                Err(error) => self.error = Some(format!("{error:#}")),
            }
        }
    }

    /// A picture becomes text the chat model can read: a vision model describes it and copies out any text in it.
    /// The chat's own model is asked first, then Blablador's default, which can see.
    fn read_picture(&mut self, name: String, bytes: Vec<u8>) {
        self.attachments.push(Attachment { name: name.clone(), text: PICTURE_PENDING.into() });
        let api = self.api();
        let events = self.events.clone();
        let model = self.settings.model.clone();
        self.runtime.spawn(async move {
            let result = async {
                let picture = extract::picture_data_url(&bytes).map_err(|e| e.to_string())?;
                let prompt = "Describe this picture in detail for someone who can't see it: what and who is in it, the setting, \
                    and anything notable. Copy out every piece of text in it exactly, in its language.";
                let first = api.look_at(&model, prompt, &picture).await;
                let answer = match first {
                    Err(_) if model != blablador_models::DEFAULT_MODEL => api.look_at(blablador_models::DEFAULT_MODEL, prompt, &picture).await,
                    other => other,
                };
                answer.map_err(|e| format!("Couldn't read the picture: {e:#}"))
            }
            .await;
            events.send(Event::PictureRead { name, result });
        });
    }

    fn add_to_knowledge(&mut self, base: KnowledgeBase, files: Vec<PathBuf>) {
        let api = self.api();
        let events = self.events.clone();
        self.runtime.spawn(async move {
            let mut base = base;
            for (number, file) in files.iter().enumerate() {
                let name = file.file_name().unwrap_or_default().to_string_lossy().to_string();
                let label = if files.len() > 1 { format!("{name} · {}/{}", number + 1, files.len()) } else { name.clone() };
                let progress = |percent: u32| events.send(Event::KnowledgeProgress { base: base.id, text: Some(format!("Indexing {label} · {percent}%")) });
                match knowledge::index(&api, &base, file, progress).await {
                    Ok((document, model)) => {
                        base.embedding_model = model.clone();
                        events.send(Event::KnowledgeAdded { base: base.id, document, model });
                    }
                    Err(error) => events.send(Event::Error(format!("{name}: {error:#}"))),
                }
            }
            events.send(Event::KnowledgeProgress { base: base.id, text: None });
        });
    }

    // MARK: drawing

    fn sidebar(&mut self, ui: &mut egui::Ui) {
        ui.add_space(6.0);
        if ui.add_sized([ui.available_width(), 28.0], egui::Button::new("New chat")).clicked() {
            self.new_chat();
        }
        // Beside New chat, where a chat is started. Its title is the line's label while it lasts.
        if ui.add_sized([ui.available_width(), 24.0], egui::Button::new("👁 Disappearing chat")).clicked() {
            self.new_disappearing_chat();
        }
        ui.add_space(6.0);
        let bottom = 5.0 * 26.0 + 12.0;
        egui::ScrollArea::vertical().max_height(ui.available_height() - bottom).auto_shrink([false, false]).show(ui, |ui| {
            let mut delete = None;
            let mut pick = None;
            // A disappearing chat stays out of the list while it lasts.
            for chat in self.chats.iter().filter(|c| !c.ephemeral) {
                let busy = self.running.contains_key(&chat.id);
                let title = if busy { format!("● {}", chat.title) } else { chat.title.clone() };
                let response = ui.add_sized([ui.available_width(), 22.0], egui::SelectableLabel::new(self.current == Some(chat.id), title));
                if response.clicked() {
                    pick = Some(chat.id);
                }
                response.context_menu(|ui| {
                    if ui.button("Rename…").clicked() {
                        self.renaming = Some((chat.id, chat.title.clone()));
                        ui.close_menu();
                    }
                    if ui.button("Delete").clicked() {
                        delete = Some(chat.id);
                        ui.close_menu();
                    }
                });
            }
            // Picking a chat from the list leaves the disappearing one behind for good.
            if let Some(id) = pick {
                self.delete_ephemeral();
                self.current = Some(id);
            }
            if let Some(id) = delete {
                self.stop(id);
                self.chats.retain(|c| c.id != id);
                // Its aside cards go with it.
                self.asides.retain(|a| a.chat != id);
                self.aside_questions.lock().unwrap().remove(&id);
                if self.current == Some(id) {
                    self.current = self.chats.first().map(|c| c.id);
                }
                self.save_chats();
            }
        });
        ui.with_layout(egui::Layout::bottom_up(egui::Align::Min), |ui| {
            ui.add_space(6.0);
            for (label, flag) in [("Settings", &mut self.show_settings), ("Memory", &mut self.show_memory), ("Knowledge", &mut self.show_knowledge), ("3D room", &mut self.mapper.open), ("Proteins…", &mut self.proteins.open)] {
                if ui.add_sized([ui.available_width(), 24.0], egui::Button::new(label).selected(*flag)).clicked() {
                    *flag = !*flag;
                }
            }
        });
    }

    fn toolbar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal_wrapped(|ui| {
            let mut model = self.settings.model.clone();
            egui::ComboBox::from_id_salt("model").width(280.0).selected_text(&model).show_ui(ui, |ui| {
                let current = self.settings.model.clone();
                if !self.models.contains(&current) {
                    ui.selectable_value(&mut model, current.clone(), &current);
                }
                for id in &self.models {
                    ui.selectable_value(&mut model, id.clone(), id);
                }
            });
            if ui.button("⟳").on_hover_text("Reload the models").clicked() {
                self.load_models();
            }
            if model != self.settings.model {
                self.settings.model = model;
                self.settings.save();
            }

            let levels = effort::levels(&self.settings.model);
            if let Some(mut level) = effort::level(&self.settings.model, &self.settings.efforts) {
                let before = level;
                egui::ComboBox::from_id_salt("effort").selected_text(format!("Thinking: {}", level.name())).show_ui(ui, |ui| {
                    for option in levels {
                        ui.selectable_value(&mut level, option, option.name());
                    }
                });
                if level != before {
                    self.settings.efforts.insert(self.settings.model.clone(), level.raw().into());
                    self.settings.save();
                }
            }

            ui.separator();
            let mut changed = ui.toggle_value(&mut self.settings.web_search, "Web").on_hover_text("Search the web and read pages").changed();
            changed |= ui.toggle_value(&mut self.settings.memory, "Memory").on_hover_text("Remember facts about you across chats").changed();
            let has_folder = self.settings.workspace.is_some();
            let commands = ui
                .add_enabled(has_folder, egui::Button::new("Commands").selected(self.settings.commands))
                .on_hover_text("Run shell commands in the folder chosen in Settings, after you approve each one")
                .on_disabled_hover_text("Choose a folder in Settings first");
            if commands.clicked() {
                self.settings.commands = !self.settings.commands;
                changed = true;
            }
            if changed {
                self.settings.save();
            }

            if let Some(id) = self.current {
                let selected = self.chat(id).map(|c| c.knowledge.len()).unwrap_or(0);
                let label = if selected > 0 { format!("Knowledge ({selected})") } else { "Knowledge".into() };
                ui.menu_button(label, |ui| {
                    if self.bases.is_empty() {
                        ui.label("No knowledge bases yet.");
                    }
                    let bases: Vec<(Uuid, String)> = self.bases.iter().map(|b| (b.id, b.name.clone())).collect();
                    let mut changed = false;
                    if let Some(chat) = self.chats.iter_mut().find(|c| c.id == id) {
                        for (base, name) in bases {
                            let mut on = chat.knowledge.contains(&base);
                            if ui.checkbox(&mut on, name).changed() {
                                chat.knowledge.retain(|b| *b != base);
                                if on {
                                    chat.knowledge.push(base);
                                }
                                changed = true;
                            }
                        }
                    }
                    if changed {
                        self.save_chats();
                    }
                    ui.separator();
                    if ui.button("Manage…").clicked() {
                        self.show_knowledge = true;
                        ui.close_menu();
                    }
                });
            }
        });
    }

    fn messages(&mut self, ui: &mut egui::Ui) -> Vec<Action> {
        let mut actions = Vec::new();
        let Some(chat) = self.current.and_then(|id| self.chats.iter().find(|c| c.id == id)) else {
            empty_state(ui);
            return actions;
        };
        if chat.messages.is_empty() {
            empty_state(ui);
            return actions;
        }
        let busy = self.running.contains_key(&chat.id);
        let last = chat.messages.len() - 1;
        let width = ui.available_width().min(860.0);
        egui::ScrollArea::vertical().auto_shrink([false, false]).stick_to_bottom(true).show(ui, |ui| {
            ui.vertical_centered(|ui| {
                ui.set_max_width(width);
                ui.with_layout(egui::Layout::top_down(egui::Align::Min), |ui| {
                    for (index, message) in chat.messages.iter().enumerate() {
                        ui.add_space(10.0);
                        match message.role {
                            Role::User => user_message(ui, message),
                            Role::Assistant => {
                                assistant_message(ui, message, &mut self.markdown);
                                ui.horizontal(|ui| {
                                    if !message.content.is_empty() && ui.small_button("Copy").clicked() {
                                        actions.push(Action::Copy(message.content.clone()));
                                    }
                                    if index == last && !busy && ui.small_button("Regenerate").clicked() {
                                        actions.push(Action::Regenerate);
                                    }
                                    if let Some((prompt, completion)) = message.tokens {
                                        ui.weak(format!("{prompt} + {completion} tokens"));
                                    }
                                });
                            }
                        }
                    }
                    ui.add_space(12.0);
                });
            });
        });
        actions
    }

    /// The aside cards of the open chat: a /btw question and its answer, while the reply keeps being written.
    fn asides(&mut self, ui: &mut egui::Ui) {
        let Some(chat_id) = self.current else { return };
        let cards: Vec<crate::aside::Aside> = self.asides.iter().filter(|a| a.chat == chat_id).cloned().collect();
        let mut close = None;
        let mut open = None;
        for aside in cards {
            ui.add_space(4.0);
            egui::Frame::group(ui.style()).show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.strong("Aside");
                    ui.weak(&aside.question);
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.small_button("✕").on_hover_text("Dismiss").clicked() {
                            close = Some(aside.id);
                        }
                        if aside.answer_chat.is_some() && ui.small_button("Open chat").clicked() {
                            open = Some(aside.id);
                        }
                    });
                });
                if aside.shown().is_empty() {
                    ui.horizontal(|ui| {
                        ui.spinner();
                        ui.weak(aside.status.clone().unwrap_or_else(|| "Thinking…".into()));
                    });
                } else {
                    ui.add(egui::Label::new(aside.shown()).wrap().selectable(true));
                    if aside.is_error {
                        ui.colored_label(Color32::from_rgb(220, 80, 70), "The answer failed.");
                    }
                    if let Some(status) = &aside.status {
                        ui.weak(status);
                    }
                }
            });
        }
        if let Some(id) = close {
            // Closing a card that is still being answered stops it; a finished one is only hidden.
            self.asides.retain(|a| a.id != id);
        }
        if let Some(id) = open {
            if let Some(chat) = self.asides.iter().find(|a| a.id == id).and_then(|a| a.answer_chat) {
                self.delete_ephemeral();
                self.current = Some(chat);
                self.asides.retain(|a| a.id != id);
            }
        }
    }

    fn composer(&mut self, ui: &mut egui::Ui) {
        ui.add_space(6.0);
        self.asides(ui);
        if self.is_disappearing() {
            let mut end = false;
            egui::Frame::new().fill(ui.visuals().faint_bg_color).corner_radius(8.0).inner_margin(8.0).show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label("👁");
                    ui.vertical(|ui| {
                        ui.strong("This chat disappears");
                        ui.weak("Nothing is saved, and nothing of it is remembered or heard in other chats.");
                    });
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.button("✕").on_hover_text("End the disappearing chat").clicked() {
                            end = true;
                        }
                    });
                });
            });
            ui.add_space(4.0);
            if end {
                self.new_chat();
            }
        }
        if !self.attachments.is_empty() {
            ui.horizontal_wrapped(|ui| {
                let mut remove = None;
                for (index, file) in self.attachments.iter().enumerate() {
                    if ui.button(if file.text == PICTURE_PENDING { format!("🖼 {} · reading…  ✕", file.name) } else { format!("📄 {}  ✕", file.name) }).on_hover_text("Remove").clicked() {
                        remove = Some(index);
                    }
                }
                if let Some(index) = remove {
                    self.attachments.remove(index);
                }
            });
        }
        let busy = self.current.is_some_and(|id| self.running.contains_key(&id));
        let editor_id = egui::Id::new("composer");
        // Enter sends, Shift+Enter starts a new line.
        let focused = ui.memory(|m| m.has_focus(editor_id));
        let enter = focused && !busy && ui.input_mut(|i| i.consume_key(egui::Modifiers::NONE, Key::Enter));
        // Typing while no text field has the keyboard goes into the composer: on Windows the window can be focused
        // with nothing inside it focused, and then every key fell on the floor.
        let stray = !ui.ctx().wants_keyboard_input()
            && !self.show_settings
            && self.approvals.is_empty()
            && ui.input(|i| i.viewport().focused.unwrap_or(false));
        if stray {
            // Taken out of the events, or the composer, focused below, would read them again this frame.
            let typed: String = ui.input_mut(|i| {
                let typed = i.events.iter().filter_map(|e| if let egui::Event::Text(t) = e { Some(t.as_str()) } else { None }).collect();
                i.events.retain(|e| !matches!(e, egui::Event::Text(_)));
                typed
            });
            if !typed.is_empty() {
                self.input.push_str(&typed);
                ui.memory_mut(|m| m.request_focus(editor_id));
                if let Some(mut state) = egui::TextEdit::load_state(ui.ctx(), editor_id) {
                    let end = egui::text::CCursor::new(self.input.chars().count());
                    state.cursor.set_char_range(Some(egui::text::CCursorRange::one(end)));
                    state.store(ui.ctx(), editor_id);
                }
            }
        }
        ui.horizontal(|ui| {
            if ui.button("Attach").on_hover_text("Add PDFs, text files or pictures").clicked() {
                if let Some(paths) = rfd::FileDialog::new().pick_files() {
                    self.attach(paths);
                }
            }
            let button_width = 70.0;
            // Focus the composer whenever nothing else has focus and the window itself is focused, and before it
            // reads this frame's keys: taking focus every frame stole it from other fields, focusing before Windows
            // gives the window focus left text input (IME) off, and on Windows the focus also goes away by itself,
            // so taking it back only while the box was empty lost every key after the first letter.
            let window_focused = ui.input(|i| i.viewport().focused.unwrap_or(false));
            let nothing_focused = ui.memory(|m| m.focused().is_none());
            if window_focused && nothing_focused && self.approvals.is_empty() && !self.show_settings {
                ui.memory_mut(|m| m.request_focus(editor_id));
            }
            let editor = egui::TextEdit::multiline(&mut self.input)
                .id(editor_id)
                .hint_text("Message Blablador")
                .desired_rows(2)
                .desired_width(ui.available_width() - button_width - 8.0);
            ui.add(editor);
            if busy {
                if ui.add_sized([button_width, 32.0], egui::Button::new("Stop")).clicked() {
                    if let Some(id) = self.current {
                        self.stop(id);
                    }
                }
            } else if ui.add_sized([button_width, 32.0], egui::Button::new("Send")).clicked() || enter {
                self.send();
            }
        });
        ui.add_space(6.0);
    }

    fn settings_window(&mut self, ctx: &egui::Context) {
        let mut open = self.show_settings;
        egui::Window::new("Settings").open(&mut open).default_width(480.0).show(ctx, |ui| {
            egui::Grid::new("settings").num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
                ui.label("API key");
                ui.horizontal(|ui| {
                    ui.add(egui::TextEdit::singleline(&mut self.key_draft).password(true).desired_width(260.0));
                    if ui.button("Save").clicked() {
                        storage::set_api_key(&self.key_draft);
                        self.api_key = self.key_draft.trim().to_string();
                        self.load_models();
                    }
                });
                ui.end_row();
                ui.label("");
                ui.hyperlink_to("Get a key at Helmholtz Codebase", "https://sdlaml.pages.jsc.fz-juelich.de/ai/guides/blablador_api_access/");
                ui.end_row();

                ui.label("Endpoint");
                ui.horizontal(|ui| {
                    let response = ui.add(egui::TextEdit::singleline(&mut self.settings.endpoint).desired_width(260.0));
                    if response.lost_focus() {
                        self.settings.save();
                        self.load_models();
                    }
                    if ui.button("Default").clicked() {
                        self.settings.endpoint = crate::api::DEFAULT_ENDPOINT.into();
                        self.settings.save();
                        self.load_models();
                    }
                });
                ui.end_row();

                ui.label("Wait for answers");
                let label = |m: u64| if m == 0 { "No limit".to_string() } else { format!("{m} minutes") };
                let before = self.settings.timeout_minutes;
                egui::ComboBox::from_id_salt("timeout").selected_text(label(before)).show_ui(ui, |ui| {
                    for minutes in [2, 5, 10, 30, 0] {
                        ui.selectable_value(&mut self.settings.timeout_minutes, minutes, label(minutes));
                    }
                });
                if before != self.settings.timeout_minutes {
                    self.settings.save();
                }
                ui.end_row();

                ui.label("Command folder");
                ui.horizontal(|ui| {
                    ui.label(self.settings.workspace.as_deref().unwrap_or("None"));
                    if ui.button("Choose…").clicked() {
                        if let Some(folder) = rfd::FileDialog::new().pick_folder() {
                            self.settings.workspace = Some(folder.display().to_string());
                            self.settings.save();
                        }
                    }
                    if self.settings.workspace.is_some() && ui.button("Clear").clicked() {
                        self.settings.workspace = None;
                        self.settings.commands = false;
                        self.settings.save();
                    }
                });
                ui.end_row();
            });
            ui.separator();
            let mut changed = ui.checkbox(&mut self.settings.learn, "Learn from every chat (the helper model picks facts to remember)").changed();
            changed |= ui.checkbox(&mut self.settings.search_chats, "Let the model search earlier chats").changed();
            if ui.checkbox(&mut self.settings.dark, "Dark appearance").changed() {
                ctx.set_visuals(if self.settings.dark { egui::Visuals::dark() } else { egui::Visuals::light() });
                changed = true;
            }
            ui.separator();
            ui.label("Custom instructions");
            changed |= ui
                .add(egui::TextEdit::multiline(&mut self.settings.instructions).hint_text("How Blablador should answer, what it should know about you…").desired_rows(4).desired_width(f32::INFINITY))
                .lost_focus();
            if changed {
                self.settings.save();
            }
            ui.separator();
            if self.confirm_delete_all {
                ui.label("Delete every chat? The history is forgotten, so earlier chats can't be searched any more. Memory is kept. This can't be undone.");
                ui.horizontal(|ui| {
                    if ui.button("Delete all chats").clicked() {
                        self.delete_all_chats();
                        self.confirm_delete_all = false;
                    }
                    if ui.button("Keep them").clicked() {
                        self.confirm_delete_all = false;
                    }
                });
            } else if ui.button("Delete all chats…").clicked() {
                self.confirm_delete_all = true;
            }
            if self.confirm_forget_everything {
                ui.label("Delete every chat and every memory? What Blablador learned about you and the memories you added go too, so it starts over knowing nothing about you. This can't be undone.");
                ui.horizontal(|ui| {
                    if ui.button("Forget everything").clicked() {
                        self.forget_everything();
                        self.confirm_forget_everything = false;
                    }
                    if ui.button("Keep them").clicked() {
                        self.confirm_forget_everything = false;
                    }
                });
            } else if ui.button("Forget everything…").on_hover_text("Deletes every chat and every memory").clicked() {
                self.confirm_forget_everything = true;
            }
            ui.separator();
            ui.weak(format!("Blablador {} · data in {}", env!("CARGO_PKG_VERSION"), storage::data_dir().display()));
            ui.weak("Everything saved is encrypted; the key is in the system keyring.");
        });
        if !open {
            self.confirm_delete_all = false;
            self.confirm_forget_everything = false;
        }
        self.show_settings = open;
    }

    fn memory_window(&mut self, ctx: &egui::Context) {
        let mut open = self.show_memory;
        egui::Window::new("Memory").open(&mut open).default_width(460.0).show(ctx, |ui| {
            ui.label("What Blablador remembers about you in every chat.");
            ui.horizontal(|ui| {
                let response = ui.add(egui::TextEdit::singleline(&mut self.new_memory).hint_text("Add a fact").desired_width(340.0));
                let enter = response.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter));
                if (ui.button("Add").clicked() || enter) && !self.new_memory.trim().is_empty() {
                    self.memory.lock().unwrap().add(&self.new_memory);
                    self.new_memory.clear();
                }
            });
            ui.separator();
            let memories = self.memory.lock().unwrap().memories.clone();
            if memories.is_empty() {
                ui.weak("Nothing yet.");
            }
            egui::ScrollArea::vertical().max_height(400.0).show(ui, |ui| {
                for (number, memory) in memories.iter().enumerate() {
                    ui.horizontal(|ui| {
                        if ui.small_button("✕").on_hover_text("Forget").clicked() {
                            self.memory.lock().unwrap().delete(memory.id);
                        }
                        ui.label(format!("{}. {}", number + 1, memory.text));
                    });
                }
            });
            ui.separator();
            if self.confirm_forget_everything {
                ui.label("Delete every chat and every memory? What Blablador learned about you and the memories you added go too. This can't be undone.");
                ui.horizontal(|ui| {
                    if ui.button("Forget everything").clicked() {
                        self.forget_everything();
                        self.confirm_forget_everything = false;
                    }
                    if ui.button("Keep them").clicked() {
                        self.confirm_forget_everything = false;
                    }
                });
            } else if !memories.is_empty() && ui.button("Forget everything…").clicked() {
                self.confirm_forget_everything = true;
            }
        });
        if !open {
            self.confirm_forget_everything = false;
        }
        self.show_memory = open;
    }

    fn knowledge_window(&mut self, ctx: &egui::Context) {
        let mut open = self.show_knowledge;
        egui::Window::new("Knowledge").open(&mut open).default_width(500.0).show(ctx, |ui| {
            ui.label("Documents Blablador searches when a chat uses the knowledge base. Choose them per chat in the Knowledge menu.");
            ui.horizontal(|ui| {
                ui.add(egui::TextEdit::singleline(&mut self.new_base).hint_text("New knowledge base").desired_width(300.0));
                if ui.button("Create").clicked() && !self.new_base.trim().is_empty() {
                    self.bases.push(KnowledgeBase {
                        id: Uuid::new_v4(),
                        name: self.new_base.trim().into(),
                        documents: vec![],
                        embedding_model: crate::api::EMBEDDING_MODEL.into(),
                    });
                    self.new_base.clear();
                    knowledge::save_bases(&self.bases);
                }
            });
            ui.separator();
            let mut add = None;
            let mut delete = None;
            let mut remove_document = None;
            egui::ScrollArea::vertical().max_height(480.0).show(ui, |ui| {
                for base in &self.bases {
                    egui::CollapsingHeader::new(format!("{} · {} documents", base.name, base.documents.len())).id_salt(base.id).default_open(true).show(ui, |ui| {
                        if let Some(progress) = self.knowledge_progress.get(&base.id) {
                            ui.horizontal(|ui| {
                                ui.spinner();
                                ui.label(progress);
                            });
                        }
                        for document in &base.documents {
                            ui.horizontal(|ui| {
                                if ui.small_button("✕").on_hover_text("Remove").clicked() {
                                    remove_document = Some((base.id, document.id));
                                }
                                ui.label(format!("{} · {} passages", document.name, document.chunks));
                            });
                        }
                        ui.horizontal(|ui| {
                            let idle = !self.knowledge_progress.contains_key(&base.id);
                            if ui.add_enabled(idle, egui::Button::new("Add files…")).clicked() {
                                if let Some(files) = rfd::FileDialog::new().add_filter("Documents", &["pdf", "txt", "md", "markdown", "csv", "json", "html", "tex", "rst"]).pick_files() {
                                    add = Some((base.clone(), files));
                                }
                            }
                            if ui.button("Delete base").clicked() {
                                delete = Some(base.id);
                            }
                        });
                    });
                }
            });
            if let Some((base, files)) = add {
                self.add_to_knowledge(base, files);
            }
            if let Some((base, document)) = remove_document {
                knowledge::remove_document(base, document);
                if let Some(b) = self.bases.iter_mut().find(|b| b.id == base) {
                    b.documents.retain(|d| d.id != document);
                }
                knowledge::save_bases(&self.bases);
            }
            if let Some(id) = delete {
                knowledge::delete_base(id);
                self.bases.retain(|b| b.id != id);
                for chat in &mut self.chats {
                    chat.knowledge.retain(|b| *b != id);
                }
                knowledge::save_bases(&self.bases);
                self.save_chats();
            }
        });
        self.show_knowledge = open;
    }

    fn approval_window(&mut self, ctx: &egui::Context) {
        let Some(pending) = self.approvals.first_mut() else { return };
        let mut answer = None;
        let title = self.chats.iter().find(|c| c.id == pending.chat).map(|c| c.title.clone()).unwrap_or_default();
        egui::Window::new("Run this command?").collapsible(false).resizable(false).anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0]).show(ctx, |ui| {
            ui.label(format!("Blablador wants to run a command for “{title}” in {}:", pending.folder));
            egui::Frame::group(ui.style()).show(ui, |ui| {
                ui.add(egui::Label::new(RichText::new(&pending.command).monospace()).wrap());
            });
            ui.horizontal(|ui| {
                if ui.button("Allow").clicked() {
                    answer = Some(Approval::Allow);
                }
                if ui.button("Allow for this chat").clicked() {
                    answer = Some(Approval::AllowForChat);
                }
                if ui.button("Don't allow").clicked() {
                    answer = Some(Approval::Deny);
                }
            });
        });
        if let Some(answer) = answer {
            let mut pending = self.approvals.remove(0);
            if answer == Approval::AllowForChat {
                self.allowed_chats.insert(pending.chat);
            }
            if let Some(reply) = pending.reply.take() {
                let _ = reply.send(answer);
            }
        }
    }
}

fn empty_state(ui: &mut egui::Ui) {
    ui.vertical_centered(|ui| {
        ui.add_space(ui.available_height() / 3.0);
        ui.heading("Blablador");
        ui.weak("Ask anything. Attach PDFs or text files, or drop them here.");
    });
}

fn user_message(ui: &mut egui::Ui, message: &Message) {
    ui.with_layout(egui::Layout::right_to_left(egui::Align::Min), |ui| {
        egui::Frame::new().fill(ui.visuals().faint_bg_color.gamma_multiply(2.5)).corner_radius(10.0).inner_margin(10.0).show(ui, |ui| {
            ui.set_max_width(ui.available_width() * 0.8);
            ui.vertical(|ui| {
                for file in &message.attachments {
                    ui.weak(format!("📄 {}", file.name));
                }
                if !message.content.is_empty() {
                    ui.add(egui::Label::new(&message.content).wrap().selectable(true));
                }
            });
        });
    });
}

fn assistant_message(ui: &mut egui::Ui, message: &Message, cache: &mut CommonMarkCache) {
    if !message.reasoning.trim().is_empty() {
        egui::CollapsingHeader::new(RichText::new("Thinking").weak()).id_salt((message.id, "thinking")).show(ui, |ui| {
            ui.add(egui::Label::new(RichText::new(message.reasoning.trim()).weak()).wrap().selectable(true));
        });
    }
    for step in &message.steps {
        let mark = match step.state {
            StepState::Running => "…",
            StepState::Done => "✔",
            StepState::Failed => "✖",
            StepState::Denied => "⊘",
        };
        let detail = serde_json::from_str::<serde_json::Value>(&step.arguments)
            .ok()
            .and_then(|v| ["query", "url", "command", "fact"].iter().find_map(|k| v[k].as_str().map(String::from)))
            .unwrap_or_default();
        egui::CollapsingHeader::new(RichText::new(format!("{mark} {} {}", step.tool, detail)).weak()).id_salt(step.id).show(ui, |ui| {
            ui.add(egui::Label::new(RichText::new(&step.result).monospace().small()).wrap().selectable(true));
        });
    }
    if !message.content.is_empty() {
        CommonMarkViewer::new().show(ui, cache, &message.content);
    }
    if let Some(status) = &message.status {
        ui.horizontal(|ui| {
            ui.spinner();
            ui.weak(status);
        });
    }
    if let Some(error) = &message.error {
        ui.colored_label(Color32::from_rgb(220, 80, 70), error);
    }
    if !message.citations.is_empty() {
        egui::CollapsingHeader::new(RichText::new(format!("Sources · {}", message.citations.len())).weak()).id_salt((message.id, "sources")).show(ui, |ui| {
            for (index, citation) in message.citations.iter().enumerate() {
                let page = citation.page.map(|p| format!(", page {p}")).unwrap_or_default();
                ui.strong(format!("[K{}] {}{}", index + 1, citation.document, page));
                ui.add(egui::Label::new(RichText::new(citation.text.chars().take(400).collect::<String>()).weak()).wrap());
            }
        });
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.handle_events();
        // CI types into the window and reads back what reached the composer.
        if let Some(path) = std::env::var_os("BLABLADOR_INPUT_PROBE") {
            let (keys, texts, imes) = ctx.input(|i| {
                i.raw.events.iter().fold((0, 0, 0), |(k, t, m), e| match e {
                    egui::Event::Key { .. } => (k + 1, t, m),
                    egui::Event::Text(_) => (k, t + 1, m),
                    egui::Event::Ime(_) => (k, t, m + 1),
                    _ => (k, t, m),
                })
            });
            let counts = ctx.data_mut(|d| {
                let c = d.get_temp_mut_or_default::<(usize, usize, usize)>(egui::Id::new("probe"));
                *c = (c.0 + keys, c.1 + texts, c.2 + imes);
                *c
            });
            let focused = ctx.memory(|m| m.has_focus(egui::Id::new("composer")));
            let window = ctx.input(|i| i.viewport().focused);
            let focused = format!("{focused} focus={:?} composer_id={:?}", ctx.memory(|m| m.focused()), egui::Id::new("composer"));
            let _ = std::fs::write(path, format!("{}\nkeys={} text={} ime={} composer_focused={focused} window_focused={window:?}",
                self.input, counts.0, counts.1, counts.2));
            ctx.request_repaint_after(std::time::Duration::from_millis(200));
        }

        let dropped: Vec<PathBuf> = ctx.input(|i| i.raw.dropped_files.iter().filter_map(|f| f.path.clone()).collect());
        if !dropped.is_empty() {
            self.attach(dropped);
        }
        if ctx.input_mut(|i| i.consume_key(egui::Modifiers::COMMAND, Key::N)) {
            self.new_chat();
        }

        egui::SidePanel::left("chats").resizable(true).default_width(230.0).show(ctx, |ui| self.sidebar(ui));
        egui::TopBottomPanel::top("toolbar").show(ctx, |ui| {
            ui.add_space(4.0);
            self.toolbar(ui);
            if let Some(error) = self.error.clone() {
                ui.horizontal(|ui| {
                    ui.colored_label(Color32::from_rgb(220, 80, 70), error);
                    if ui.small_button("✕").clicked() {
                        self.error = None;
                    }
                });
            }
            ui.add_space(4.0);
        });
        egui::TopBottomPanel::bottom("composer").show(ctx, |ui| self.composer(ui));
        let actions = egui::CentralPanel::default().show(ctx, |ui| self.messages(ui)).inner;
        for action in actions {
            match action {
                Action::Regenerate => self.regenerate(),
                Action::Copy(text) => ctx.copy_text(text),
            }
        }

        self.settings_window(ctx);
        self.memory_window(ctx);
        self.knowledge_window(ctx);
        let api = self.api();
        self.mapper.window(ctx, &self.runtime, api.clone());
        for (question, answer) in self.mapper.take_notes() {
            self.record(question, answer);
        }
        self.proteins.update(ctx, &self.runtime, &api);
        for note in self.proteins.take_notes() {
            self.record(note.question, note.answer);
        }
        self.approval_window(ctx);

        if let Some((id, mut title)) = self.renaming.take() {
            let mut keep = true;
            let mut done = false;
            egui::Window::new("Rename chat").collapsible(false).resizable(false).anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0]).show(ctx, |ui| {
                let response = ui.text_edit_singleline(&mut title);
                response.request_focus();
                done = response.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter));
                ui.horizontal(|ui| {
                    done |= ui.button("Rename").clicked();
                    keep = !ui.button("Cancel").clicked();
                });
            });
            if done && !title.trim().is_empty() {
                if let Some(chat) = self.chat_mut(id) {
                    chat.title = title.trim().into();
                }
                self.save_chats();
            } else if keep && !done {
                self.renaming = Some((id, title));
            }
        }
    }
}

/// An attached picture's text until the vision model has described it.
const PICTURE_PENDING: &str = "(looking at the picture…)";

/// The system's own fonts behind egui's, for what egui's lack: answers are full of ⁻¹, ≈, α, → and the like, which
/// showed as boxes. Only fallbacks, so the look stays the same; a font that isn't there is skipped.
fn add_system_fonts(ctx: &egui::Context) {
    let candidates: &[&str] = if cfg!(windows) {
        &["C:\\Windows\\Fonts\\segoeui.ttf", "C:\\Windows\\Fonts\\seguisym.ttf", "C:\\Windows\\Fonts\\cambria.ttc"]
    } else if cfg!(target_os = "macos") {
        &["/System/Library/Fonts/Supplemental/Arial Unicode.ttf", "/System/Library/Fonts/Apple Symbols.ttf"]
    } else {
        &["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
          "/usr/share/fonts/noto/NotoSans-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf"]
    };
    let mut fonts = egui::FontDefinitions::default();
    for (index, path) in candidates.iter().enumerate() {
        let Ok(bytes) = std::fs::read(path) else { continue };
        let name = format!("system-{index}");
        fonts.font_data.insert(name.clone(), std::sync::Arc::new(egui::FontData::from_owned(bytes)));
        for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
            fonts.families.entry(family).or_default().push(name.clone());
        }
    }
    ctx.set_fonts(fonts);
}
