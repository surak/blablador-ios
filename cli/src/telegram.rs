//! bla on Telegram: the agent answering from your pocket, through a bot you own.
//!
//! `bla serve --telegram` long-polls `getUpdates` and runs one turn per message, in the folder it
//! was started in, with the same plugins, permissions and memory as the terminal. A voice note is
//! transcribed with Whisper first, so talking to it works the same way `/voice` does; with
//! `--speak` the answer comes back as a voice note read by Drama 3.
//!
//! This hands whoever can message the bot an agent that reads files and runs commands on the
//! machine it is started on, so the allow list is not optional: every message from a chat that is
//! not on it is refused before the model sees a word of it. A tool that would ask in the terminal
//! asks in the chat, and nothing runs until the answer comes back from an allowed chat.

use crate::agent::Agent;
use crate::llm::Usage;
use crate::plugin::ToolOutput;
use crate::session::Session;
use crate::ui::{Approval, Ui};
use serde_json::{json, Value};
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Telegram's own bot API, when no server of your own is given.
pub const TELEGRAM: &str = "https://api.telegram.org";
/// Telegram's limit for one message.
const MAX_MESSAGE: usize = 4000;
/// How long `getUpdates` is allowed to wait for something to happen.
const POLL_SECONDS: u64 = 30;
/// A question in the chat is given up on after this long, and answered no.
const ANSWER_WITHIN: Duration = Duration::from_secs(600);
/// Telegram stops showing "typing…" after about five seconds.
const TYPING_EVERY: Duration = Duration::from_secs(4);
/// Longer answers than this are not read aloud, however much was asked for.
const MAX_SPOKEN: usize = 1500;

pub struct Options {
    pub token: String,
    /// The only chats whose messages are run. Nothing works without at least one.
    pub allowed: Vec<i64>,
    /// Answer with a voice note as well as the text.
    pub speak: bool,
    /// What language to expect in voice notes; Whisper guesses without it.
    pub language: Option<String>,
    pub endpoint: String,
    pub key: String,
    /// Serving stops when this is set: Ctrl-C, and the end of a test.
    pub stop: Arc<AtomicBool>,
    /// Telegram itself, unless a bot API server of your own is given instead.
    pub api: String,
}

const HELP: &str = "bla, here in the chat.\n\n\
Send a message and it answers, in the folder it was started in, with the same tools it has in the terminal.\n\
Send a voice note and it listens.\n\n\
/new — forget this conversation and start again\n\
/speak — read the answers aloud, or stop\n\
/whoami — the id of this chat\n\
/help — this";

pub fn serve(agent: &mut Agent, options: Options) -> Result<(), String> {
    let bot = Bot::new(&options.token, &options.api);
    let me = bot.call("getMe", &json!({}))?;
    let name = me.get("username").and_then(|u| u.as_str()).unwrap_or("the bot").to_string();
    if options.allowed.is_empty() {
        return Err(format!(
            "Nobody is allowed to talk to @{name}. Message the bot, then start it again with --telegram-allow <id>: \
             the id is printed here for every message that is refused."
        ));
    }
    let folder = agent.session.cwd.display().to_string();
    println!("bla is on Telegram as @{name}, working in {folder}.");
    println!("Allowed chats: {}", options.allowed.iter().map(|c| c.to_string()).collect::<Vec<_>>().join(", "));
    println!("Ctrl-C stops it.");

    let mail = Mailbox::new(bot);
    let mut speak = options.speak;
    // One conversation per chat, kept while the bridge runs, so a chat picks up where it left off.
    let mut sessions: HashMap<i64, Session> = HashMap::new();
    let cwd = agent.session.cwd.clone();

    while !options.stop.load(Ordering::Relaxed) {
        let Some(update) = mail.next(POLL_SECONDS)? else { continue };
        let Some(message) = update.get("message") else { continue };
        let Some(chat) = message.pointer("/chat/id").and_then(|c| c.as_i64()) else { continue };
        // Everything about who is talking is decided here, before the model is involved at all.
        if !options.allowed.contains(&chat) {
            let who = message.pointer("/from/username").and_then(|u| u.as_str()).unwrap_or("someone");
            println!("Refused a message from {who} (chat {chat}). Add --telegram-allow {chat} to let them in.");
            let _ = mail.bot.send(chat, "This bla is not yours to talk to.");
            continue;
        }

        let text = match incoming(&mail.bot, message, &options) {
            Ok(Some(t)) => t,
            Ok(None) => continue,
            Err(e) => {
                let _ = mail.bot.send(chat, &format!("I couldn't read that: {e}"));
                continue;
            }
        };

        match text.trim() {
            "/help" | "/start" => {
                let _ = mail.bot.send(chat, HELP);
                continue;
            }
            "/whoami" => {
                let _ = mail.bot.send(chat, &format!("This chat is {chat}, and it is allowed."));
                continue;
            }
            "/speak" => {
                speak = !speak;
                let _ = mail.bot.send(chat, if speak { "I'll read the answers aloud." } else { "Back to text only." });
                continue;
            }
            "/new" => {
                sessions.remove(&chat);
                agent.switch(Session::new(&cwd, &agent.model.clone()));
                let _ = mail.bot.send(chat, "Starting again.");
                continue;
            }
            _ => {}
        }

        // Put this chat's own conversation back in front of the agent, with the plugins started
        // for it the way /resume does in the terminal.
        let session = sessions.remove(&chat).unwrap_or_else(|| Session::new(&cwd, &agent.model));
        agent.switch(session);
        agent.cancel.store(false, std::sync::atomic::Ordering::Relaxed);

        let mut ui = ChatUi::new(&mail, chat, speak, &options);
        let result = agent.turn(&text, &mut ui);
        ui.finish();
        if let Err(e) = result {
            let _ = mail.bot.send(chat, &format!("That went wrong: {e}"));
        }
        // Park it again under this chat; the agent holds a fresh one until the next message.
        let done = std::mem::replace(&mut agent.session, Session::new(&cwd, &agent.model));
        sessions.insert(chat, done);
    }
    Ok(())
}

/// The words of a message: what was typed, or what a voice note or an audio file says.
fn incoming(bot: &Bot, message: &Value, options: &Options) -> Result<Option<String>, String> {
    if let Some(text) = message.get("text").and_then(|t| t.as_str()) {
        return Ok(Some(text.to_string()));
    }
    let sound = message
        .get("voice")
        .or_else(|| message.get("audio"))
        .or_else(|| message.get("video_note"))
        .and_then(|v| v.get("file_id"))
        .and_then(|f| f.as_str());
    let Some(file_id) = sound else {
        return Ok(Some(message.get("caption").and_then(|c| c.as_str()).unwrap_or_default().to_string()).filter(|t: &String| !t.is_empty()));
    };
    let (bytes, name) = bot.file(file_id)?;
    // Telegram's voice notes are Opus in an Ogg wrapper; Whisper reads them as they are.
    let kind = if name.ends_with(".oga") || name.ends_with(".ogg") { "audio/ogg" } else { "audio/mpeg" };
    let text = crate::voice::transcribe_file(&options.endpoint, &options.key, &bytes, &name, kind, options.language.as_deref())?;
    if text.trim().is_empty() {
        return Err("there were no words in it".into());
    }
    Ok(Some(text))
}

/// The updates, and the ones taken out of order while a question waited for its answer.
struct Mailbox {
    bot: Bot,
    offset: RefCell<i64>,
    /// Updates read while waiting for an answer, which still have to be dealt with afterwards.
    waiting: RefCell<VecDeque<Value>>,
}

impl Mailbox {
    fn new(bot: Bot) -> Mailbox {
        Mailbox { bot, offset: RefCell::new(0), waiting: RefCell::new(VecDeque::new()) }
    }

    /// The next update, from what was put aside first; None when the poll brought nothing, so
    /// whoever is waiting gets a chance to notice it should stop.
    fn next(&self, timeout: u64) -> Result<Option<Value>, String> {
        if let Some(update) = self.waiting.borrow_mut().pop_front() {
            return Ok(Some(update));
        }
        let offset = *self.offset.borrow();
        let updates = self.bot.updates(offset, timeout)?;
        {
            let mut queue = self.waiting.borrow_mut();
            for u in updates {
                if let Some(id) = u.get("update_id").and_then(|i| i.as_i64()) {
                    *self.offset.borrow_mut() = id + 1;
                }
                queue.push_back(u);
            }
        }
        Ok(self.waiting.borrow_mut().pop_front())
    }

    /// Waits for the next thing said in one chat, keeping anything else for later.
    fn reply_from(&self, chat: i64, within: Duration) -> Option<String> {
        let until = Instant::now() + within;
        let mut keep = Vec::new();
        let answer = loop {
            if Instant::now() > until {
                break None;
            }
            let update = match self.next(5) {
                Ok(Some(u)) => u,
                Ok(None) => continue,
                Err(_) => break None,
            };
            let from_this_chat = update.pointer("/message/chat/id").and_then(|c| c.as_i64()) == Some(chat);
            match update.pointer("/message/text").and_then(|t| t.as_str()) {
                Some(text) if from_this_chat => break Some(text.to_string()),
                _ => keep.push(update),
            }
        };
        let mut queue = self.waiting.borrow_mut();
        for u in keep.into_iter().rev() {
            queue.push_front(u);
        }
        answer
    }
}

/// What a turn looks like in a chat: tool calls as they happen, the answer when it is done.
struct ChatUi<'a> {
    mail: &'a Mailbox,
    chat: i64,
    speak: bool,
    endpoint: String,
    key: String,
    answer: String,
    typed_at: Instant,
}

impl<'a> ChatUi<'a> {
    fn new(mail: &'a Mailbox, chat: i64, speak: bool, options: &Options) -> ChatUi<'a> {
        let _ = mail.bot.typing(chat);
        ChatUi {
            mail,
            chat,
            speak,
            endpoint: options.endpoint.clone(),
            key: options.key.clone(),
            answer: String::new(),
            typed_at: Instant::now(),
        }
    }

    /// Telegram stops showing "typing…" on its own, so it is said again while the agent works.
    fn still_working(&mut self) {
        if self.typed_at.elapsed() > TYPING_EVERY {
            let _ = self.mail.bot.typing(self.chat);
            self.typed_at = Instant::now();
        }
    }

    /// The answer, in messages Telegram will take, and aloud when that was asked for.
    fn finish(&mut self) {
        let text = std::mem::take(&mut self.answer);
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        for piece in split(text, MAX_MESSAGE) {
            let _ = self.mail.bot.send(self.chat, &piece);
        }
        if self.speak && text.len() <= MAX_SPOKEN {
            match crate::voice::speech_mp3(&self.endpoint, &self.key, text, None) {
                Ok(mp3) => {
                    let _ = self.mail.bot.voice(self.chat, &mp3);
                }
                Err(e) => println!("Drama 3: {e}"),
            }
        }
    }
}

impl Ui for ChatUi<'_> {
    fn text(&mut self, text: &str) {
        self.answer.push_str(text);
        self.still_working();
    }

    fn thinking(&mut self, _text: &str) {
        self.still_working();
    }

    /// One turn of the model ended; its answer goes out before any tools run again.
    fn end_reply(&mut self) {
        self.finish();
    }

    fn tool_start(&mut self, name: &str, summary: &str) {
        let _ = self.mail.bot.send(self.chat, &format!("⚙ {name} {}", crate::util::clip(summary, 200)));
        self.typed_at = Instant::now() - TYPING_EVERY;
        self.still_working();
    }

    fn tool_end(&mut self, _name: &str, output: &ToolOutput) {
        if output.is_error {
            let _ = self.mail.bot.send(self.chat, &format!("… that failed: {}", crate::util::clip(&output.content, 500)));
        }
        self.still_working();
    }

    /// Nothing runs on the machine until the chat says so.
    fn approve(&mut self, name: &str, summary: &str, reason: &str) -> Approval {
        let question = format!("May I?\n\n{name} {}\n{reason}\n\nReply yes, always, or no.", crate::util::clip(summary, 500));
        if self.mail.bot.send(self.chat, &question).is_err() {
            return Approval::No;
        }
        match self.mail.reply_from(self.chat, ANSWER_WITHIN) {
            Some(answer) => match answer.trim().to_lowercase().as_str() {
                "yes" | "y" | "ok" | "sim" | "ja" => Approval::Once,
                "always" | "a" | "sempre" | "immer" => Approval::Always,
                _ => Approval::No,
            },
            None => {
                let _ = self.mail.bot.send(self.chat, "Nobody answered, so I left it alone.");
                Approval::No
            }
        }
    }

    fn notice(&mut self, text: &str) {
        let _ = self.mail.bot.send(self.chat, text);
    }

    fn error(&mut self, text: &str) {
        let _ = self.mail.bot.send(self.chat, &format!("⚠ {text}"));
    }

    fn usage(&mut self, _usage: &Usage) {}
}

/// Text in pieces Telegram will take, broken at a line end where there is one.
pub(crate) fn split(text: &str, max: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while rest.len() > max {
        // `max` counts bytes, and the last of them can fall inside a character (ü, あ, an emoji).
        let mut cut = max;
        while !rest.is_char_boundary(cut) {
            cut -= 1;
        }
        let window = &rest[..cut];
        let at = window.rfind("\n\n").or_else(|| window.rfind('\n')).or_else(|| window.rfind(' ')).unwrap_or(cut);
        let at = rest[..at].char_indices().last().map(|(i, c)| i + c.len_utf8()).unwrap_or(at);
        out.push(rest[..at].trim_end().to_string());
        rest = rest[at..].trim_start();
    }
    if !rest.is_empty() {
        out.push(rest.to_string());
    }
    out
}

struct Bot {
    token: String,
    /// Telegram itself, or the bot API server given instead of it.
    base: String,
    agent: ureq::Agent,
}

impl Bot {
    fn new(token: &str, base: &str) -> Bot {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(20))
            // Longer than the long poll, or every wait would end in a timeout.
            .timeout_read(Duration::from_secs(POLL_SECONDS + 30))
            .user_agent(concat!("bla/", env!("CARGO_PKG_VERSION")))
            .build();
        Bot { token: token.to_string(), base: base.trim_end_matches('/').to_string(), agent }
    }

    fn call(&self, method: &str, body: &Value) -> Result<Value, String> {
        let answer = self
            .agent
            .post(&format!("{}/bot{}/{method}", self.base, self.token))
            .set("Content-Type", "application/json")
            .send_string(&body.to_string());
        let value: Value = match answer {
            Ok(r) => r.into_json().map_err(|e| format!("Telegram: {e}"))?,
            Err(ureq::Error::Status(code, r)) => {
                let text = r.into_string().unwrap_or_default();
                // The token is in the URL, never in what we print.
                return Err(format!("Telegram said {code}: {}", crate::util::clip(text.trim(), 300)));
            }
            Err(e) => return Err(format!("Telegram: {e}")),
        };
        if value.get("ok").and_then(|o| o.as_bool()) != Some(true) {
            return Err(format!("Telegram: {}", value.get("description").and_then(|d| d.as_str()).unwrap_or("it said no")));
        }
        Ok(value.get("result").cloned().unwrap_or(Value::Null))
    }

    fn updates(&self, offset: i64, timeout: u64) -> Result<Vec<Value>, String> {
        let body = json!({"offset": offset, "timeout": timeout, "allowed_updates": ["message"]});
        match self.call("getUpdates", &body) {
            Ok(Value::Array(list)) => Ok(list),
            Ok(_) => Ok(Vec::new()),
            // A network hiccup is not a reason to stop being on Telegram.
            Err(e) => {
                println!("Telegram: {e}");
                std::thread::sleep(Duration::from_secs(5));
                Ok(Vec::new())
            }
        }
    }

    fn send(&self, chat: i64, text: &str) -> Result<(), String> {
        self.call("sendMessage", &json!({"chat_id": chat, "text": text, "disable_web_page_preview": true})).map(|_| ())
    }

    fn typing(&self, chat: i64) -> Result<(), String> {
        self.call("sendChatAction", &json!({"chat_id": chat, "action": "typing"})).map(|_| ())
    }

    /// The answer read aloud, as a file Telegram shows with a play button.
    fn voice(&self, chat: i64, mp3: &[u8]) -> Result<(), String> {
        let boundary = format!("bla-{}", crate::util::random_hex(16));
        let mut body = Vec::new();
        body.extend(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n{chat}\r\n").as_bytes());
        body.extend(
            format!("--{boundary}\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"answer.mp3\"\r\nContent-Type: audio/mpeg\r\n\r\n")
                .as_bytes(),
        );
        body.extend(mp3);
        body.extend(format!("\r\n--{boundary}--\r\n").as_bytes());
        self.agent
            .post(&format!("{}/bot{}/sendAudio", self.base, self.token))
            .set("Content-Type", &format!("multipart/form-data; boundary={boundary}"))
            .send_bytes(&body)
            .map_err(|e| format!("Telegram: {e}"))
            .map(|_| ())
    }

    /// A file somebody sent, as bytes.
    fn file(&self, file_id: &str) -> Result<(Vec<u8>, String), String> {
        let info = self.call("getFile", &json!({"file_id": file_id}))?;
        let path = info.get("file_path").and_then(|p| p.as_str()).ok_or("Telegram didn't say where that file is.")?;
        let name = path.rsplit('/').next().unwrap_or("sound").to_string();
        let answer = self
            .agent
            .get(&format!("{}/file/bot{}/{path}", self.base, self.token))
            .call()
            .map_err(|e| format!("Telegram: {e}"))?;
        let mut bytes = Vec::new();
        std::io::Read::read_to_end(&mut answer.into_reader(), &mut bytes).map_err(|e| format!("Telegram: {e}"))?;
        Ok((bytes, name))
    }
}
