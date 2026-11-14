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
    show_settings: bool,
    show_memory: bool,
    show_knowledge: bool,
    mapper: crate::mapper::Mapper,
    new_memory: String,
    new_base: String,
    renaming: Option<(Uuid, String)>,
    error: Option<String>,
    markdown: CommonMarkCache,
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>, runtime: tokio::runtime::Runtime) -> App {
        let (sender, receiver) = std::sync::mpsc::channel();
        let settings = Settings::load();
        cc.egui_ctx.set_visuals(if settings.dark { egui::Visuals::dark() } else { egui::Visuals::light() });
        let api_key = storage::api_key();
        let mut app = App {
            runtime,
            events: Events { sender, context: cc.egui_ctx.clone() },
            receiver,
            show_settings: api_key.is_empty(),
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
            show_memory: false,
            show_knowledge: false,
            mapper: Default::default(),
            new_memory: String::new(),
            new_base: String::new(),
            renaming: None,
            error: None,
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
        // An empty chat is reused rather than piling up.
        if let Some(empty) = self.chats.iter().find(|c| c.messages.is_empty()) {
            self.current = Some(empty.id);
            return;
        }
        let chat = Conversation::new();
        self.current = Some(chat.id);
        self.chats.insert(0, chat);
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
                Event::Error(error) => self.error = Some(error),
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
        if self.current.is_none_or(|id| self.chat(id).is_none()) {
            self.new_chat();
        }
        let id = self.current.unwrap();
        if self.running.contains_key(&id) {
            return;
        }
        let mut question = Message::new(Role::User, text);
        question.attachments = std::mem::take(&mut self.attachments);
        self.input.clear();
        let chat = self.chat_mut(id).unwrap();
        chat.messages.push(question);
        chat.updated = chrono::Utc::now();
        self.start_reply(id);
    }

    /// Adds an empty reply to the chat and starts writing it.
    fn start_reply(&mut self, id: Uuid) {
        let model = self.settings.model.clone();
        let mut reply = Message::new(Role::Assistant, "");
        reply.model = Some(model.clone());
        reply.status = Some(crate::chat::potato_verb());
        let Some(chat) = self.chat(id) else { return };
        let history = chat.messages.clone();
        let needs_title = chat.title == "New chat";
        let knowledge = self.bases.iter().filter(|b| chat.knowledge.contains(&b.id)).cloned().collect();
        let other_chats = self.chats.iter().filter(|c| c.id != id).cloned().collect();
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
            match extract::text_of(&path) {
                Ok(text) => self.attachments.push(Attachment {
                    name: path.file_name().unwrap_or_default().to_string_lossy().into(),
                    text: text.chars().take(extract::MAX_ATTACHMENT).collect(),
                }),
                Err(error) => self.error = Some(format!("{error:#}")),
            }
        }
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
        ui.add_space(6.0);
        let bottom = 3.0 * 26.0 + 12.0;
        egui::ScrollArea::vertical().max_height(ui.available_height() - bottom).auto_shrink([false, false]).show(ui, |ui| {
            let mut delete = None;
            for chat in &self.chats {
                let busy = self.running.contains_key(&chat.id);
                let title = if busy { format!("● {}", chat.title) } else { chat.title.clone() };
                let response = ui.add_sized([ui.available_width(), 22.0], egui::SelectableLabel::new(self.current == Some(chat.id), title));
                if response.clicked() {
                    self.current = Some(chat.id);
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
            if let Some(id) = delete {
                self.stop(id);
                self.chats.retain(|c| c.id != id);
                if self.current == Some(id) {
                    self.current = self.chats.first().map(|c| c.id);
                }
                self.save_chats();
            }
        });
        ui.with_layout(egui::Layout::bottom_up(egui::Align::Min), |ui| {
            ui.add_space(6.0);
            for (label, flag) in [("Settings", &mut self.show_settings), ("Memory", &mut self.show_memory), ("Knowledge", &mut self.show_knowledge), ("3D room", &mut self.mapper.open)] {
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

    fn composer(&mut self, ui: &mut egui::Ui) {
        ui.add_space(6.0);
        if !self.attachments.is_empty() {
            ui.horizontal_wrapped(|ui| {
                let mut remove = None;
                for (index, file) in self.attachments.iter().enumerate() {
                    if ui.button(format!("📄 {}  ✕", file.name)).on_hover_text("Remove").clicked() {
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
        ui.horizontal(|ui| {
            if ui.button("Attach").on_hover_text("Add PDFs or text files").clicked() {
                if let Some(paths) = rfd::FileDialog::new().pick_files() {
                    self.attach(paths);
                }
            }
            let button_width = 70.0;
            let editor = egui::TextEdit::multiline(&mut self.input)
                .id(editor_id)
                .hint_text("Message Blablador")
                .desired_rows(2)
                .desired_width(ui.available_width() - button_width - 8.0);
            let response = ui.add(editor);
            // Focus the composer only when nothing else has focus and the window itself is focused: taking focus
            // every frame stole it from other fields, and focusing before Windows gives the window focus left
            // text input (IME) off, so nothing could be typed.
            let window_focused = ui.input(|i| i.viewport().focused.unwrap_or(false));
            let nothing_focused = ui.memory(|m| m.focused().is_none());
            if self.input.is_empty() && window_focused && nothing_focused && self.approvals.is_empty() && !self.show_settings {
                response.request_focus();
            }
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
            ui.weak(format!("Blablador {} · data in {}", env!("CARGO_PKG_VERSION"), storage::data_dir().display()));
            ui.weak("Everything saved is encrypted; the key is in the system keyring.");
        });
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
        });
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
        self.mapper.window(ctx, &self.runtime, api);
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
