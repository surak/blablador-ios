//! The chat screen. A full-screen view with the Blablador logo at the top of the conversation, which scrolls
//! with the mouse wheel, the scroll bar or Page Up/Down; dragging selects text and copies it; a click on a
//! tool call or on the thinking opens or closes it. Below: what is running, questions with buttons, messages
//! waiting their turn, the input box (history, / completion, @path completion) and a status line.
//!
//! The agent stays on the main thread and talks to the screen through `Screen` (which is a `Ui`); the screen
//! draws and reads the keyboard and mouse on its own thread, so typing, scrolling and Esc work while the
//! model answers. Lines typed during an answer wait in a queue and are sent after it.

use crate::llm::Usage;
use crate::plugin::ToolOutput;
use crate::ui::{Approval, Ui};
use ratatui::crossterm::event::{
    self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers,
    KeyboardEnhancementFlags, MouseButton, MouseEvent, MouseEventKind, PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use ratatui::crossterm::terminal::{self, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::crossterm::{cursor, execute};
use ratatui::layout::{Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph};
use ratatui::Frame;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// blablador-ng-notext.svg, 28 × 30 pixels, drawn two pixels per character cell in the terminal's own
/// text colour, so it is dark on light terminals and light on dark ones, like the SVG's dark mode.
const LOGO: [&str; 30] = [
    "...######################...",
    "..########################..",
    ".###....................###.",
    "###......................###",
    "##........................##",
    "##........................##",
    "##...###.......###........##",
    "##...####.....####........##",
    "##..#####.....#####..##...##",
    "##...####.....####...##...##",
    "##....##.......##....##...##",
    "##...................##...##",
    "##...................##...##",
    "##.......#####.......##...##",
    "##......######.......##...##",
    "##........##.........##...##",
    "##........##.........##...##",
    "##........##.........##...##",
    "##...................##...##",
    "##...................##...##",
    "##...................##...##",
    "###..................##...##",
    ".###.................##...##",
    "..#####################...##",
    "...#####################..##",
    "......................######",
    "........................####",
    ".........................###",
    "..........................##",
    "...........................#",
];

/// What the status says while the model works, as in the apps.
const VERBS: &[&str] = &[
    "Potatoing",
    "Spudding",
    "Mashing",
    "Tuberising",
    "Peeling",
    "Sprouting",
    "Roasting",
    "Baking",
    "Frying",
    "Boiling",
    "Chipping",
    "Hash-browning",
    "Rösti-ing",
    "Gratinating",
    "Scalloping",
    "Wedging",
    "Tater-totting",
    "Jacketing",
    "Eye-sprouting",
    "Earthing up",
    "Harvesting",
    "Digging",
    "Gnocchi-ing",
    "Croquetting",
    "Latke-ing",
    "Dauphinoising",
    "Smashing",
    "Crisping",
    "Fermenting",
];
const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const ACCENT: Color = Color::Rgb(0xf2, 0xb1, 0x34);
/// Lines of a tool's output shown before it is opened.
const PREVIEW: usize = 3;

fn verb() -> &'static str {
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos() as usize).unwrap_or(0);
    VERBS[n % VERBS.len()]
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Welcome,
    User,
    Answer,
    Thinking,
    Tool,
    Output,
    Notice,
    Error,
}

/// One thing in the conversation: a message, a tool call, a notice.
struct Item {
    kind: Kind,
    text: String,
    /// Tool: the summary of its arguments.
    title: String,
    /// Tool: its output, once it ended.
    output: Option<ToolOutput>,
    open: bool,
    done: bool,
    started: Instant,
    took: Duration,
    /// Rows drawn for a width; dropped when the item changes.
    cache: Option<(u16, Vec<Row>)>,
}

impl Item {
    fn new(kind: Kind, text: impl Into<String>) -> Item {
        Item {
            kind,
            text: text.into(),
            title: String::new(),
            output: None,
            open: false,
            done: true,
            started: Instant::now(),
            took: Duration::ZERO,
            cache: None,
        }
    }

    /// Whether a click shows more or less of it.
    fn foldable(&self) -> bool {
        match self.kind {
            Kind::Thinking => self.done && !self.text.trim().is_empty(),
            Kind::Tool => self.output.as_ref().is_some_and(|o| o.content.lines().count() > PREVIEW),
            _ => false,
        }
    }
}

#[derive(Clone)]
struct Row {
    line: Line<'static>,
    /// The same row as plain text, for copying.
    plain: String,
}

struct Question {
    name: String,
    summary: String,
    reason: String,
    answer: Sender<Approval>,
}

/// Where things were drawn, for the mouse.
#[derive(Default)]
struct Hits {
    transcript: Rect,
    bar: Option<Rect>,
    jump: Option<Rect>,
    input: Rect,
    buttons: Vec<(Rect, Approval)>,
    suggestions: Vec<(Rect, usize)>,
    /// For each transcript row on screen: which item and which absolute row.
    rows: Vec<(usize, usize)>,
    total: usize,
    top: usize,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct Point {
    row: usize,
    col: usize,
}

struct Info {
    model: String,
    effort: String,
    cwd: String,
    input_tokens: u64,
    output_tokens: u64,
}

struct State {
    items: Vec<Item>,
    input: Vec<char>,
    cursor: usize,
    history: Vec<String>,
    /// Position while going through the history, and what was typed before.
    browsing: Option<(usize, Vec<char>)>,
    /// None follows the end; Some is the first row shown.
    top: Option<usize>,
    busy: bool,
    verb: &'static str,
    since: Instant,
    queued: Vec<String>,
    question: Option<Question>,
    selected_button: usize,
    commands: Vec<(String, String)>,
    suggestion: usize,
    /// The suggestions were closed with Esc for this input.
    hide_suggestions: bool,
    selection: Option<(Point, Point)>,
    dragging: Option<Drag>,
    toast: Option<(String, Instant)>,
    /// Ctrl-C once more to quit.
    quit_armed: Option<Instant>,
    info: Info,
    hits: Hits,
    stop: bool,
    dirty: bool,
}

#[derive(Clone, Copy, PartialEq)]
enum Drag {
    Select,
    Bar,
}

impl State {
    fn changed(&mut self) {
        self.dirty = true;
    }

    fn push(&mut self, item: Item) {
        self.items.push(item);
        self.changed();
    }

    fn last_mut(&mut self, kind: Kind) -> Option<&mut Item> {
        let item = self.items.last_mut().filter(|i| i.kind == kind && !i.done)?;
        item.cache = None;
        Some(item)
    }

    fn toast(&mut self, text: impl Into<String>) {
        self.toast = Some((text.into(), Instant::now()));
        self.changed();
    }

    fn input_text(&self) -> String {
        self.input.iter().collect()
    }

    fn set_input(&mut self, text: &str) {
        self.input = text.chars().collect();
        self.cursor = self.input.len();
        self.hide_suggestions = false;
        self.suggestion = 0;
    }

    /// Commands matching what is typed, while the input is a / command without arguments yet.
    fn suggestions(&self) -> Vec<usize> {
        if self.hide_suggestions || self.question.is_some() || self.input.first() != Some(&'/') || self.input.contains(&' ') || self.input.contains(&'\n') {
            return Vec::new();
        }
        let typed: String = self.input[1..].iter().collect::<String>().to_lowercase();
        self.commands.iter().enumerate().filter(|(_, (name, _))| name.starts_with(&typed)).map(|(i, _)| i).take(8).collect()
    }
}

/// The main thread's side of the screen.
pub struct Screen {
    state: Arc<Mutex<State>>,
    lines: Receiver<Option<String>>,
    thread: Option<std::thread::JoinHandle<()>>,
    history_file: PathBuf,
}

fn restore() {
    let mut out = std::io::stdout();
    let _ = execute!(out, PopKeyboardEnhancementFlags, DisableBracketedPaste, DisableMouseCapture, LeaveAlternateScreen, cursor::Show);
    let _ = terminal::disable_raw_mode();
}

impl Screen {
    /// Takes over the terminal. `cancel` is set by Esc or Ctrl-C to stop the answer.
    pub fn open(cancel: Arc<AtomicBool>, history_file: PathBuf) -> Result<Screen, String> {
        let history = std::fs::read_to_string(&history_file)
            .map(|t| t.lines().filter(|l| *l != "#V2" && !l.is_empty()).map(|l| l.replace("\\n", "\n").replace("\\\\", "\\")).collect())
            .unwrap_or_default();
        terminal::enable_raw_mode().map_err(|e| format!("terminal: {e}"))?;
        let mut out = std::io::stdout();
        execute!(out, EnterAlternateScreen, EnableMouseCapture, EnableBracketedPaste).map_err(|e| format!("terminal: {e}"))?;
        // Shift-Enter for a new line where the terminal can tell it apart.
        if terminal::supports_keyboard_enhancement().unwrap_or(false) {
            let _ = execute!(out, PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES));
        }
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            restore();
            previous(info);
        }));
        let state = Arc::new(Mutex::new(State {
            items: Vec::new(),
            input: Vec::new(),
            cursor: 0,
            history,
            browsing: None,
            top: None,
            busy: false,
            verb: verb(),
            since: Instant::now(),
            queued: Vec::new(),
            question: None,
            selected_button: 0,
            commands: Vec::new(),
            suggestion: 0,
            hide_suggestions: false,
            selection: None,
            dragging: None,
            toast: None,
            quit_armed: None,
            info: Info { model: String::new(), effort: String::new(), cwd: String::new(), input_tokens: 0, output_tokens: 0 },
            hits: Hits::default(),
            stop: false,
            dirty: true,
        }));
        let (send, lines) = channel();
        let shared = state.clone();
        let thread = std::thread::spawn(move || run(shared, send, cancel));
        Ok(Screen { state, lines, thread: Some(thread), history_file })
    }

    fn with<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let r = f(&mut state);
        state.dirty = true;
        r
    }

    /// The header: the logo, the version, the model and the folder, and lines under it.
    pub fn welcome(&self, lines: Vec<String>) {
        self.with(|s| s.push(Item::new(Kind::Welcome, lines.join("\n"))));
    }

    pub fn set_info(&self, model: &str, effort: Option<&str>, cwd: &str) {
        self.with(|s| {
            s.info.model = model.to_string();
            s.info.effort = effort.unwrap_or_default().to_string();
            s.info.cwd = cwd.to_string();
        });
    }

    pub fn set_commands(&self, commands: Vec<(String, String)>) {
        self.with(|s| s.commands = commands);
    }

    /// Plain output, such as a command's.
    pub fn say(&self, text: &str) {
        self.with(|s| s.push(Item::new(Kind::Output, clean(text))));
    }

    /// Everything but the header goes; for a new session.
    pub fn clear(&self) {
        self.with(|s| {
            s.items.retain(|i| i.kind == Kind::Welcome);
            s.top = None;
            s.selection = None;
            s.info.input_tokens = 0;
            s.info.output_tokens = 0;
        });
    }

    /// Waits for the next line the user sends; None when they quit.
    pub fn read_line(&mut self) -> Option<String> {
        self.with(|s| s.busy = false);
        let line = self.lines.recv().ok().flatten()?;
        self.with(|s| {
            if let Some(i) = s.queued.iter().position(|q| *q == line) {
                s.queued.remove(i);
            }
            if !line.trim().is_empty() {
                s.history.retain(|h| *h != line);
                s.history.push(line.clone());
            }
            s.push(Item::new(Kind::User, clean(&line)));
            s.top = None;
            s.busy = true;
            s.verb = verb();
            s.since = Instant::now();
        });
        let history: Vec<String> = self.with(|s| s.history.iter().rev().take(500).rev().cloned().collect());
        let mut text = String::from("#V2\n");
        for h in history {
            text.push_str(&h.replace('\\', "\\\\").replace('\n', "\\n"));
            text.push('\n');
        }
        if let Some(dir) = self.history_file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(&self.history_file, text);
        Some(line)
    }

    /// Gives the terminal back.
    pub fn close(mut self) {
        self.with(|s| s.stop = true);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        if let Some(t) = self.thread.take() {
            self.with(|s| s.stop = true);
            let _ = t.join();
        }
    }
}

impl Ui for Screen {
    fn text(&mut self, text: &str) {
        self.with(|s| {
            if let Some(t) = s.last_mut(Kind::Thinking) {
                t.done = true;
                t.took = t.started.elapsed();
            }
            match s.last_mut(Kind::Answer) {
                Some(item) => item.text.push_str(text),
                None => {
                    let mut item = Item::new(Kind::Answer, text);
                    item.done = false;
                    s.push(item);
                }
            }
        });
    }

    fn thinking(&mut self, text: &str) {
        self.with(|s| match s.last_mut(Kind::Thinking) {
            Some(item) => item.text.push_str(text),
            None => {
                if text.trim().is_empty() {
                    return;
                }
                let mut item = Item::new(Kind::Thinking, text.trim_start());
                item.done = false;
                s.push(item);
            }
        });
    }

    fn end_reply(&mut self) {
        self.with(|s| {
            for item in s.items.iter_mut().rev().take(3) {
                if !item.done && matches!(item.kind, Kind::Answer | Kind::Thinking) {
                    if item.kind == Kind::Thinking {
                        item.took = item.started.elapsed();
                    }
                    item.done = true;
                    item.cache = None;
                }
            }
        });
    }

    fn tool_start(&mut self, name: &str, summary: &str) {
        self.with(|s| {
            let mut item = Item::new(Kind::Tool, name);
            item.title = clean(summary);
            item.done = false;
            s.push(item);
        });
    }

    fn tool_end(&mut self, name: &str, output: &ToolOutput) {
        self.with(|s| {
            let item = s.items.iter_mut().rev().find(|i| i.kind == Kind::Tool && !i.done && i.text == name);
            match item {
                Some(item) => {
                    // A plan is always shown in full.
                    item.open = name == "update_plan";
                    item.output = Some(ToolOutput { content: clean(&output.content), is_error: output.is_error });
                    item.done = true;
                    item.took = item.started.elapsed();
                    item.cache = None;
                }
                // Refused before it started.
                None => {
                    let mut item = Item::new(Kind::Tool, name);
                    item.output = Some(ToolOutput { content: clean(&output.content), is_error: output.is_error });
                    s.push(item);
                }
            }
        });
    }

    fn approve(&mut self, name: &str, summary: &str, reason: &str) -> Approval {
        let (send, receive) = channel();
        self.with(|s| {
            s.question = Some(Question { name: name.to_string(), summary: clean(summary), reason: clean(reason), answer: send });
            s.selected_button = 0;
            s.top = None;
        });
        let answer = receive.recv().unwrap_or(Approval::No);
        self.with(|s| {
            let what = match answer {
                Approval::Once => "allowed",
                Approval::Always => "allowed from now on in this project",
                Approval::No => "declined",
            };
            s.push(Item::new(Kind::Notice, format!("{name} {what}")));
        });
        answer
    }

    fn notice(&mut self, text: &str) {
        self.with(|s| s.push(Item::new(Kind::Notice, clean(text))));
    }

    fn error(&mut self, text: &str) {
        self.with(|s| {
            if text == "cancelled" {
                s.push(Item::new(Kind::Notice, "Stopped."));
            } else {
                s.push(Item::new(Kind::Error, clean(text)));
            }
        });
    }

    fn usage(&mut self, usage: &Usage) {
        self.with(|s| {
            s.info.input_tokens = usage.input;
            s.info.output_tokens += usage.output;
        });
    }
}

/// Text without terminal escape codes or control characters, tabs as spaces.
pub fn clean(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.peek() {
                Some('[') => {
                    chars.next();
                    while let Some(&n) = chars.peek() {
                        chars.next();
                        if ('@'..='~').contains(&n) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    // OSC: up to BEL or ESC \.
                    while let Some(n) = chars.next() {
                        if n == '\u{7}' || (n == '\u{1b}' && chars.peek() == Some(&'\\')) {
                            chars.next();
                            break;
                        }
                    }
                }
                _ => {
                    chars.next();
                }
            },
            '\t' => out.push_str("    "),
            '\r' => {
                if chars.peek() != Some(&'\n') {
                    out.push('\n');
                }
            }
            '\n' => out.push('\n'),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

// ---------- Laying out text ----------

/// Fills rows of at most `width` columns word by word, with a prefix on the first row and another on the rest.
struct Wrap {
    width: usize,
    rest: (String, Style),
    rows: Vec<Row>,
    spans: Vec<Span<'static>>,
    plain: String,
    col: usize,
    indent: usize,
}

impl Wrap {
    fn new(width: usize, first: (&str, Style), rest: (&str, Style)) -> Wrap {
        let width = width.max(first.0.width().max(rest.0.width()) + 8);
        let mut w = Wrap { width, rest: (rest.0.to_string(), rest.1), rows: Vec::new(), spans: Vec::new(), plain: String::new(), col: 0, indent: 0 };
        w.start(first.0, first.1);
        w
    }

    fn start(&mut self, prefix: &str, style: Style) {
        if !prefix.is_empty() {
            self.spans.push(Span::styled(prefix.to_string(), style));
        }
        self.plain = prefix.to_string();
        self.col = prefix.width();
        self.indent = self.col;
    }

    fn newline(&mut self) {
        let spans = std::mem::take(&mut self.spans);
        let plain = std::mem::take(&mut self.plain);
        self.rows.push(Row { line: Line::from(spans), plain });
        let (p, s) = self.rest.clone();
        self.start(&p, s);
    }

    fn put(&mut self, text: &str, style: Style) {
        match self.spans.last_mut() {
            Some(last) if last.style == style && self.col > self.indent => last.content.to_mut().push_str(text),
            _ => self.spans.push(Span::styled(text.to_string(), style)),
        }
        self.plain.push_str(text);
        self.col += text.width();
    }

    fn word(&mut self, word: &str, style: Style) {
        let w = word.width();
        let space = word.chars().all(char::is_whitespace);
        if space && self.col == self.indent && !self.rows.is_empty() {
            return;
        }
        if self.col + w <= self.width {
            self.put(word, style);
        } else if space {
            self.newline();
        } else if w <= self.width - self.indent.max(self.rest.0.width()) && self.col > self.indent {
            self.newline();
            self.put(word, style);
        } else {
            for c in word.chars() {
                let cw = c.width().unwrap_or(0);
                if self.col + cw > self.width {
                    self.newline();
                }
                let mut b = [0; 4];
                self.put(c.encode_utf8(&mut b), style);
            }
        }
    }

    fn text(&mut self, text: &str, style: Style) {
        let mut start = 0;
        let mut space = None;
        for (i, c) in text.char_indices() {
            let s = c.is_whitespace();
            if space.is_some_and(|was| was != s) {
                self.word(&text[start..i], style);
                start = i;
            }
            space = Some(s);
        }
        if start < text.len() {
            self.word(&text[start..], style);
        }
    }

    fn finish(mut self) -> Vec<Row> {
        if !self.spans.is_empty() || self.rows.is_empty() || self.col > self.indent {
            self.newline();
        }
        self.rows
    }
}

fn wrapped(text: &str, width: usize, first: (&str, Style), rest: (&str, Style), style: Style) -> Vec<Row> {
    let mut rows = Vec::new();
    for (i, line) in text.split('\n').enumerate() {
        let mut w = if i == 0 { Wrap::new(width, first, rest) } else { Wrap::new(width, rest, rest) };
        w.text(line, style);
        rows.extend(w.finish());
    }
    rows
}

/// `**bold**`, `*italic*` and `code` within a line.
fn inline(text: &str, base: Style) -> Vec<(String, Style)> {
    let mut out: Vec<(String, Style)> = Vec::new();
    let mut rest = text;
    let mut buf = String::new();
    while !rest.is_empty() {
        let marker = if rest.starts_with("**") {
            Some(("**", base.add_modifier(Modifier::BOLD)))
        } else if rest.starts_with('`') {
            Some(("`", base.fg(ACCENT)))
        } else {
            None
        };
        if let Some((m, style)) = marker {
            if let Some(end) = rest[m.len()..].find(m).filter(|&e| e > 0) {
                if !buf.is_empty() {
                    out.push((std::mem::take(&mut buf), base));
                }
                out.push((rest[m.len()..m.len() + end].to_string(), style));
                rest = &rest[m.len() * 2 + end..];
                continue;
            }
        }
        let c = rest.chars().next().unwrap_or(' ');
        buf.push(c);
        rest = &rest[c.len_utf8()..];
    }
    if !buf.is_empty() {
        out.push((buf, base));
    }
    out
}

/// Markdown as the model writes it: headings, lists, quotes, code blocks and inline styles.
fn markdown(text: &str, width: usize, first: &str, first_style: Style) -> Vec<Row> {
    let pad = "  ";
    let mut rows: Vec<Row> = Vec::new();
    let mut fence: Option<String> = None;
    let mut first_row = true;
    let code = Style::default().fg(Color::Rgb(0x9c, 0xdc, 0xfe));
    for line in text.split('\n') {
        let prefix = if first_row { (first, first_style) } else { (pad, Style::default()) };
        first_row = false;
        let trimmed = line.trim_start();
        if let Some(lang) = trimmed.strip_prefix("```") {
            if fence.is_some() {
                fence = None;
            } else {
                fence = Some(lang.trim().to_string());
                let label = if lang.trim().is_empty() { "code".to_string() } else { lang.trim().to_string() };
                rows.extend(wrapped(&format!("╭ {label}"), width, prefix, (pad, Style::default()), Style::default().fg(Color::DarkGray)));
            }
            continue;
        }
        if fence.is_some() {
            let mut w = Wrap::new(width, prefix, (pad, Style::default()));
            w.put("│ ", Style::default().fg(Color::DarkGray));
            w.indent = w.col;
            w.rest.0 = format!("{pad}│ ");
            w.text(line, code);
            rows.extend(w.finish());
            continue;
        }
        let (runs, rest_prefix): (Vec<(String, Style)>, String) = if let Some(h) = trimmed.strip_prefix('#') {
            let h = h.trim_start_matches('#').trim();
            (inline(h, Style::default().add_modifier(Modifier::BOLD).fg(ACCENT)), pad.into())
        } else if let Some(q) = trimmed.strip_prefix("> ").or(trimmed.strip_prefix(">")) {
            (
                vec![("▎ ".into(), Style::default().fg(Color::DarkGray))]
                    .into_iter()
                    .chain(inline(q, Style::default().add_modifier(Modifier::ITALIC)))
                    .collect(),
                format!("{pad}▎ "),
            )
        } else if let Some(item) = trimmed.strip_prefix("- ").or(trimmed.strip_prefix("* ")).or(trimmed.strip_prefix("+ ")) {
            let indent = " ".repeat(line.len() - trimmed.len());
            (std::iter::once((format!("{indent}• "), Style::default().fg(ACCENT))).chain(inline(item, Style::default())).collect(), format!("{pad}{indent}  "))
        } else if trimmed.starts_with("---") && trimmed.chars().all(|c| c == '-') {
            (vec![("─".repeat(width.saturating_sub(4).min(60)), Style::default().fg(Color::DarkGray))], pad.into())
        } else {
            let indent = line.len() - trimmed.len();
            let numbered = trimmed.split_once(". ").filter(|(n, _)| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit())).map(|(n, _)| n.len() + 2);
            let hang = indent + numbered.unwrap_or(0);
            (inline(line, Style::default()), format!("{pad}{}", " ".repeat(hang)))
        };
        let mut w = Wrap::new(width, prefix, (&rest_prefix, Style::default()));
        for (t, s) in runs {
            w.text(&t, s);
        }
        rows.extend(w.finish());
    }
    rows
}

fn blank() -> Row {
    Row { line: Line::default(), plain: String::new() }
}

fn elapsed(d: Duration) -> String {
    let s = d.as_secs();
    if s < 60 {
        format!("{}s", s)
    } else {
        format!("{}m {}s", s / 60, s % 60)
    }
}

fn welcome(text: &str, width: usize) -> Vec<Row> {
    let dim = Style::default().fg(Color::DarkGray);
    let logo: Vec<String> = LOGO
        .chunks(2)
        .map(|pair| {
            pair[0]
                .chars()
                .zip(pair[1].chars())
                .map(|(a, b)| match (a == '#', b == '#') {
                    (true, true) => '█',
                    (true, false) => '▀',
                    (false, true) => '▄',
                    _ => ' ',
                })
                .collect()
        })
        .collect();
    let mut info: Vec<(String, Style)> = vec![
        (String::new(), Style::default()),
        (String::new(), Style::default()),
        (format!("bla {}", env!("CARGO_PKG_VERSION")), Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)),
        ("BLABLADOR on the command line".into(), Style::default()),
        (String::new(), Style::default()),
    ];
    for (i, line) in text.lines().enumerate() {
        info.push((line.to_string(), if i < 2 { Style::default() } else { dim }));
    }
    let side = width >= 28 + 2 + 30;
    let mut rows = Vec::new();
    if width >= 30 {
        for (i, l) in logo.iter().enumerate() {
            let mut spans = vec![Span::raw(" "), Span::raw(l.clone())];
            let mut plain = format!(" {l}");
            if side {
                if let Some((t, s)) = info.get(i) {
                    let t = crate::util::clip(t, width.saturating_sub(33) * 3).to_string();
                    spans.push(Span::raw("   "));
                    spans.push(Span::styled(t.clone(), *s));
                    plain.push_str("   ");
                    plain.push_str(&t);
                }
            }
            rows.push(Row { line: Line::from(spans), plain });
        }
    }
    let from = if side && width >= 30 { logo.len() } else { 0 };
    for (t, s) in info.iter().skip(from) {
        rows.extend(wrapped(t, width, (" ", Style::default()), (" ", Style::default()), *s));
    }
    rows
}

/// The rows of one item at a width; a blank row separates items.
fn render(item: &Item, width: usize, tick: usize, verb: &str) -> Vec<Row> {
    let dim = Style::default().fg(Color::DarkGray);
    let mut rows = vec![blank()];
    match item.kind {
        Kind::Welcome => return welcome(&item.text, width),
        Kind::User => rows.extend(wrapped(
            &item.text,
            width,
            ("› ", Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)),
            ("  ", Style::default()),
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Kind::Answer => rows.extend(markdown(item.text.trim_matches('\n'), width, "● ", Style::default())),
        Kind::Thinking => {
            let star = if item.done { "✻ ".to_string() } else { format!("{} ", SPINNER[tick % SPINNER.len()]) };
            // The same potato verbs the apps use while a reply is being worked out.
            let head = if !item.done {
                format!("{verb}…")
            } else if item.took < Duration::from_secs(1) {
                "Thought process".into()
            } else {
                format!("Thought process, {}", elapsed(item.took))
            };
            let hint = if item.done && !item.open {
                "  (click to show)"
            } else if item.open {
                "  (click to hide)"
            } else {
                ""
            };
            let mut w = Wrap::new(width, (&star, Style::default().fg(ACCENT)), ("  ", dim));
            w.text(&head, Style::default().add_modifier(Modifier::ITALIC));
            w.text(hint, dim);
            rows.extend(w.finish());
            let text = item.text.trim();
            if item.open {
                rows.extend(wrapped(text, width, ("  ", dim), ("  ", dim), dim.add_modifier(Modifier::ITALIC)));
            } else if !item.done {
                let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
                let tail = lines[lines.len().saturating_sub(2)..].join("\n");
                let mut more = wrapped(&tail, width, ("  ", dim), ("  ", dim), dim.add_modifier(Modifier::ITALIC));
                let n = more.len();
                rows.extend(more.drain(n.saturating_sub(2)..));
            }
        }
        Kind::Tool => {
            let (mark, color) = match &item.output {
                None => (SPINNER[tick % SPINNER.len()], ACCENT),
                Some(o) if o.is_error => ("●", Color::Red),
                Some(_) => ("●", Color::Green),
            };
            let mut w = Wrap::new(width, (&format!("{mark} "), Style::default().fg(color)), ("  ", Style::default()));
            w.text(&item.text, Style::default().add_modifier(Modifier::BOLD));
            w.text(" ", Style::default());
            w.text(&item.title, Style::default());
            if item.done && item.took >= Duration::from_secs(2) {
                w.text(&format!("  {}", elapsed(item.took)), dim);
            }
            rows.extend(w.finish());
            if let Some(o) = &item.output {
                let style = if o.is_error { Style::default().fg(Color::Red) } else { dim };
                let lines: Vec<&str> = o.content.trim_end().lines().collect();
                let shown = if item.open { lines.len() } else { PREVIEW.min(lines.len()) };
                let text = lines[..shown].join("\n");
                if !text.is_empty() {
                    rows.extend(wrapped(&text, width, ("  ⎿ ", dim), ("    ", dim), style));
                }
                if lines.len() > shown {
                    rows.extend(wrapped(&format!("… {} more lines (click to show)", lines.len() - shown), width, ("    ", dim), ("    ", dim), dim));
                } else if item.open && lines.len() > PREVIEW {
                    rows.extend(wrapped("(click to hide)", width, ("    ", dim), ("    ", dim), dim));
                }
            }
        }
        Kind::Output => rows.extend(wrapped(&item.text, width, ("", Style::default()), ("", Style::default()), Style::default())),
        Kind::Notice => rows.extend(wrapped(&item.text, width, ("  ", dim), ("  ", dim), dim)),
        Kind::Error => {
            rows.extend(wrapped(&item.text, width, ("✗ ", Style::default().fg(Color::Red)), ("  ", Style::default()), Style::default().fg(Color::Red)))
        }
    }
    rows
}

// ---------- The input box ----------

/// Where each character of the input goes in a box `width` wide: (row, column), plus the end.
fn input_layout(input: &[char], width: usize) -> Vec<(usize, usize)> {
    let width = width.max(4);
    let mut pos = Vec::with_capacity(input.len() + 1);
    let (mut row, mut col) = (0, 0);
    for &c in input {
        if c == '\n' {
            pos.push((row, col));
            row += 1;
            col = 0;
            continue;
        }
        let w = c.width().unwrap_or(0);
        if col + w > width {
            row += 1;
            col = 0;
        }
        pos.push((row, col));
        col += w;
    }
    if col >= width {
        row += 1;
        col = 0;
    }
    pos.push((row, col));
    pos
}

fn input_lines(input: &[char], width: usize) -> Vec<String> {
    let layout = input_layout(input, width);
    let rows = layout.last().map(|p| p.0 + 1).unwrap_or(1);
    let mut lines = vec![String::new(); rows];
    for (i, &c) in input.iter().enumerate() {
        if c != '\n' {
            lines[layout[i].0].push(c);
        }
    }
    lines
}

// ---------- Drawing ----------

fn draw(frame: &mut Frame, s: &mut State, tick: usize) {
    let area = frame.area();
    let dim = Style::default().fg(Color::DarkGray);
    let mut hits = Hits::default();
    let inner_width = area.width.saturating_sub(4).max(4) as usize;
    let input_rows = input_lines(&s.input, inner_width).len().clamp(1, 8) as u16;

    let mut bottom: Vec<(u16, &str)> = Vec::new();
    let status_h = if s.busy || s.toast.is_some() { 1 } else { 0 };
    let question_h = if s.question.is_some() { 5 } else { 0 };
    let queue_h = s.queued.len().min(3) as u16;
    bottom.push((status_h, "status"));
    let below = status_h + question_h + queue_h + input_rows + 2 + 1;
    let transcript = Rect { x: 0, y: 0, width: area.width, height: area.height.saturating_sub(below) };
    let mut y = transcript.height;

    // The conversation.
    let width = transcript.width.saturating_sub(2).max(10) as usize;
    let mut flat: Vec<(usize, usize)> = Vec::new();
    let verb = s.verb;
    for (i, item) in s.items.iter_mut().enumerate() {
        let animated = !item.done;
        if animated || item.cache.as_ref().map(|c| c.0) != Some(width as u16) {
            item.cache = Some((width as u16, render(item, width, tick, verb)));
        }
        let n = item.cache.as_ref().map(|c| c.1.len()).unwrap_or(0);
        flat.extend((0..n).map(|r| (i, r)));
    }
    let total = flat.len();
    let height = transcript.height as usize;
    let max_top = total.saturating_sub(height);
    if s.top.is_some_and(|t| t >= max_top) {
        s.top = None;
    }
    let top = s.top.unwrap_or(max_top);
    let selection = s.selection.map(|(a, b)| if (a.row, a.col) <= (b.row, b.col) { (a, b) } else { (b, a) });
    for (screen_row, &(item, r)) in flat.iter().skip(top).take(height).enumerate() {
        let row = &s.items[item].cache.as_ref().expect("rendered").1[r];
        let y = transcript.y + screen_row as u16;
        frame.buffer_mut().set_line(transcript.x + 1, y, &row.line, width as u16);
        hits.rows.push((item, top + screen_row));
        if let Some((a, b)) = selection {
            let abs = top + screen_row;
            if abs >= a.row && abs <= b.row {
                let from = if abs == a.row { a.col } else { 0 };
                let to = if abs == b.row { b.col } else { width };
                for x in from..to.min(width) {
                    if let Some(cell) = frame.buffer_mut().cell_mut(Position::new(transcript.x + 1 + x as u16, y)) {
                        cell.set_style(Style::default().add_modifier(Modifier::REVERSED));
                    }
                }
            }
        }
    }
    // The scroll bar, when there is more than fits.
    if total > height && height > 0 {
        let bar = Rect { x: transcript.width.saturating_sub(1), y: transcript.y, width: 1, height: transcript.height };
        let thumb = (height * height / total).max(1);
        let pos = if max_top == 0 { 0 } else { (height - thumb) * top / max_top };
        for i in 0..height {
            let (symbol, style) = if i >= pos && i < pos + thumb { ("┃", Style::default().fg(ACCENT)) } else { ("│", dim) };
            frame.buffer_mut().set_string(bar.x, bar.y + i as u16, symbol, style);
        }
        hits.bar = Some(bar);
        if s.top.is_some() {
            let below = total - (top + height);
            let label = format!(" ↓ {below} more lines · click or End ");
            let w = label.width() as u16;
            let r = Rect { x: transcript.width.saturating_sub(w + 2), y: transcript.y + transcript.height - 1, width: w, height: 1 };
            frame.render_widget(Clear, r);
            frame.buffer_mut().set_string(r.x, r.y, &label, Style::default().fg(Color::Black).bg(ACCENT));
            hits.jump = Some(r);
        }
    }
    hits.transcript = transcript;
    hits.total = total;
    hits.top = top;

    // What is running, or a short message.
    if status_h > 0 {
        let line = if let Some((t, _)) = &s.toast {
            Line::from(Span::styled(format!("  {t}"), Style::default().fg(ACCENT)))
        } else {
            Line::from(vec![
                Span::styled(format!("  {} ", SPINNER[tick % SPINNER.len()]), Style::default().fg(ACCENT)),
                Span::styled(format!("{}… ", s.verb), Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)),
                Span::styled(format!("({} · Esc to stop)", elapsed(s.since.elapsed())), dim),
            ])
        };
        frame.render_widget(Paragraph::new(line), Rect { x: 0, y, width: area.width, height: 1 });
        y += 1;
    }

    // A question with buttons.
    if let Some(q) = &s.question {
        let r = Rect { x: 0, y, width: area.width, height: question_h };
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(ACCENT))
            .title(Span::styled(" Allow? ", Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)));
        let inner = block.inner(r);
        frame.render_widget(block, r);
        let head = Line::from(vec![
            Span::styled(format!("{} ", q.name), Style::default().add_modifier(Modifier::BOLD)),
            Span::raw(q.summary.lines().next().unwrap_or_default().to_string()),
        ]);
        frame.render_widget(Paragraph::new(head), Rect { height: 1, ..inner });
        frame.render_widget(
            Paragraph::new(Span::styled(q.reason.lines().next().unwrap_or_default().to_string(), dim)),
            Rect { y: inner.y + 1, height: 1, ..inner },
        );
        let mut x = inner.x;
        for (i, (label, answer)) in
            [(" Yes (y) ", Approval::Once), (" Always here (a) ", Approval::Always), (" No (n) ", Approval::No)].into_iter().enumerate()
        {
            let w = label.width() as u16;
            let style = if i == s.selected_button {
                Style::default().fg(Color::Black).bg(ACCENT).add_modifier(Modifier::BOLD)
            } else {
                Style::default().add_modifier(Modifier::REVERSED)
            };
            let b = Rect { x, y: inner.y + 2, width: w.min(inner.right().saturating_sub(x)), height: 1 };
            frame.buffer_mut().set_string(b.x, b.y, label, style);
            hits.buttons.push((b, answer));
            x += w + 2;
        }
        y += question_h;
    }

    // Messages waiting for the answer to end.
    for q in s.queued.iter().take(3) {
        let line = Line::from(vec![Span::styled("  ⏳ ", dim), Span::styled(crate::util::clip(q.lines().next().unwrap_or_default(), 300).to_string(), dim)]);
        frame.render_widget(Paragraph::new(line), Rect { x: 0, y, width: area.width, height: 1 });
        y += 1;
    }

    // The input.
    let r = Rect { x: 0, y, width: area.width, height: input_rows + 2 };
    let border = if s.question.is_some() { dim } else { Style::default().fg(ACCENT) };
    let block = Block::default().borders(Borders::ALL).border_type(BorderType::Rounded).border_style(border);
    let inner = Rect { x: r.x + 2, y: r.y + 1, width: r.width.saturating_sub(4), height: input_rows };
    frame.render_widget(block, r);
    hits.input = inner;
    let layout = input_layout(&s.input, inner_width);
    let cursor_at = layout[s.cursor.min(s.input.len())];
    let first_row = cursor_at.0.saturating_sub(input_rows as usize - 1);
    if s.input.is_empty() {
        let hint =
            if s.busy { "Type to queue a message · Esc stops the answer" } else { "Ask anything · / commands · @file · !shell · Shift-Enter new line" };
        frame.buffer_mut().set_string(inner.x, inner.y, hint, dim);
    } else {
        for (i, text) in input_lines(&s.input, inner_width).iter().enumerate().skip(first_row).take(input_rows as usize) {
            let style = if s.input.first() == Some(&'/') || s.input.first() == Some(&'!') { Style::default().fg(ACCENT) } else { Style::default() };
            frame.buffer_mut().set_string(inner.x, inner.y + (i - first_row) as u16, text, style);
        }
    }
    frame.buffer_mut().set_string(r.x + 1, inner.y, "›", Style::default().fg(ACCENT).add_modifier(Modifier::BOLD));
    if s.question.is_none() {
        frame.set_cursor_position(Position::new(inner.x + cursor_at.1 as u16, inner.y + (cursor_at.0 - first_row) as u16));
    }
    y += input_rows + 2;

    // The status line.
    let mut parts = vec![s.info.model.clone()];
    if !s.info.effort.is_empty() {
        parts.push(format!("effort {}", s.info.effort));
    }
    if s.info.input_tokens > 0 {
        parts.push(format!("{} in · {} out", tokens(s.info.input_tokens), tokens(s.info.output_tokens)));
    }
    parts.push(s.info.cwd.clone());
    let left = format!("  {}", parts.join(" · "));
    let right = "wheel scrolls · drag copies · click opens ";
    let line = if left.width() + right.width() + 2 <= area.width as usize {
        Line::from(vec![Span::styled(left.clone(), dim), Span::raw(" ".repeat(area.width as usize - left.width() - right.width())), Span::styled(right, dim)])
    } else {
        Line::from(Span::styled(left, dim))
    };
    frame.render_widget(Paragraph::new(line), Rect { x: 0, y, width: area.width, height: 1 });

    // / suggestions, over the conversation just above the input.
    let suggestions = s.suggestions();
    if !suggestions.is_empty() {
        s.suggestion = s.suggestion.min(suggestions.len() - 1);
        let h = suggestions.len() as u16;
        let top = r.y.saturating_sub(h);
        let name_w = suggestions.iter().map(|&i| s.commands[i].0.width()).max().unwrap_or(0) + 2;
        for (n, &i) in suggestions.iter().enumerate() {
            let row = Rect { x: 1, y: top + n as u16, width: area.width.saturating_sub(2), height: 1 };
            let (name, help) = &s.commands[i];
            let selected = n == s.suggestion;
            let style = if selected { Style::default().fg(Color::Black).bg(ACCENT) } else { Style::default() };
            frame.render_widget(Clear, row);
            let line = Line::from(vec![
                Span::styled(format!(" /{name:<name_w$}"), style.add_modifier(Modifier::BOLD)),
                Span::styled(format!("{help} "), if selected { style } else { dim }),
            ]);
            frame.render_widget(Paragraph::new(line).style(style), row);
            hits.suggestions.push((row, n));
        }
    }
    s.hits = hits;
}

fn tokens(n: u64) -> String {
    if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        n.to_string()
    }
}

// ---------- Input ----------

/// The selected text, row by row.
fn selected_text(s: &State) -> String {
    let Some((a, b)) = s.selection else {
        return String::new();
    };
    let (a, b) = if (a.row, a.col) <= (b.row, b.col) { (a, b) } else { (b, a) };
    let width = s.hits.transcript.width.saturating_sub(2).max(10) as usize;
    let mut rows: Vec<&Row> = Vec::new();
    for item in &s.items {
        if let Some((_, r)) = &item.cache {
            rows.extend(r.iter());
        }
    }
    let mut out = Vec::new();
    for (i, row) in rows.iter().enumerate().take(b.row + 1).skip(a.row) {
        let from = if i == a.row { a.col } else { 0 };
        let to = if i == b.row { b.col } else { width };
        let mut col = 0;
        let mut text = String::new();
        for c in row.plain.chars() {
            let w = c.width().unwrap_or(0);
            if col >= from && col < to {
                text.push(c);
            }
            col += w;
        }
        out.push(text.trim_end().to_string());
    }
    out.join("\n")
}

fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Copies to the clipboard: the system's tool where there is one, and OSC 52 for terminals over SSH.
fn copy(text: &str) {
    use std::process::{Command, Stdio};
    let tools: &[&[&str]] = if cfg!(target_os = "macos") {
        &[&["pbcopy"]]
    } else if cfg!(windows) {
        &[&["clip"]]
    } else {
        &[&["wl-copy"], &["xclip", "-selection", "clipboard"], &["xsel", "--clipboard", "--input"]]
    };
    for tool in tools {
        if let Ok(mut child) = Command::new(tool[0]).args(&tool[1..]).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(text.as_bytes());
            }
            if child.wait().is_ok_and(|s| s.success()) {
                return;
            }
        }
    }
    let mut out = std::io::stdout();
    let _ = write!(out, "\u{1b}]52;c;{}\u{7}", base64(text.as_bytes()));
    let _ = out.flush();
}

/// Completes the @path being typed at the cursor with names in the folder.
fn complete_path(s: &mut State) -> bool {
    let before: String = s.input[..s.cursor].iter().collect();
    let Some(at) = before.rfind('@') else {
        return false;
    };
    let word = &before[at + 1..];
    if word.contains(char::is_whitespace) {
        return false;
    }
    let (dir, prefix) = match word.rfind('/') {
        Some(i) => (&word[..=i], &word[i + 1..]),
        None => ("", word),
    };
    let base = if dir.is_empty() { PathBuf::from(".") } else { crate::util::resolve(&std::env::current_dir().unwrap_or_default(), dir) };
    let Ok(entries) = std::fs::read_dir(base) else {
        return false;
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            (name.starts_with(prefix) && (!name.starts_with('.') || prefix.starts_with('.'))).then(|| if e.path().is_dir() { format!("{name}/") } else { name })
        })
        .collect();
    names.sort();
    let Some(first) = names.first() else {
        return false;
    };
    // The longest start all names share.
    let mut common = first.clone();
    for n in &names[1..] {
        while !n.starts_with(&common) {
            common.pop();
        }
    }
    if common.len() <= prefix.len() {
        s.toast(names.iter().take(12).cloned().collect::<Vec<_>>().join("  "));
        return true;
    }
    let add: Vec<char> = common[prefix.len()..].chars().collect();
    let n = add.len();
    s.input.splice(s.cursor..s.cursor, add);
    s.cursor += n;
    true
}

fn insert(s: &mut State, text: &str) {
    let chars: Vec<char> = text.replace("\r\n", "\n").replace('\r', "\n").chars().collect();
    let n = chars.len();
    s.input.splice(s.cursor..s.cursor, chars);
    s.cursor += n;
    s.browsing = None;
    s.hide_suggestions = false;
}

fn scroll(s: &mut State, by: isize) {
    let height = s.hits.transcript.height as usize;
    let max_top = s.hits.total.saturating_sub(height);
    let top = s.top.unwrap_or(max_top) as isize + by;
    let top = top.clamp(0, max_top as isize) as usize;
    s.top = if top >= max_top { None } else { Some(top) };
}

fn answer(s: &mut State, a: Approval) {
    if let Some(q) = s.question.take() {
        let _ = q.answer.send(a);
    }
}

fn key(s: &mut State, k: KeyEvent, lines: &Sender<Option<String>>, cancel: &AtomicBool) {
    let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
    let alt = k.modifiers.contains(KeyModifiers::ALT);
    let shift = k.modifiers.contains(KeyModifiers::SHIFT);
    if !(ctrl && k.code == KeyCode::Char('c')) {
        s.quit_armed = None;
    }
    if s.question.is_some() {
        match k.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => answer(s, Approval::Once),
            KeyCode::Char('a') | KeyCode::Char('A') => answer(s, Approval::Always),
            KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => answer(s, Approval::No),
            KeyCode::Char('c') if ctrl => answer(s, Approval::No),
            KeyCode::Left | KeyCode::BackTab => s.selected_button = s.selected_button.saturating_sub(1),
            KeyCode::Right | KeyCode::Tab => s.selected_button = (s.selected_button + 1).min(2),
            KeyCode::Enter => {
                let a = [Approval::Once, Approval::Always, Approval::No][s.selected_button];
                answer(s, a)
            }
            KeyCode::PageUp => scroll(s, -(s.hits.transcript.height as isize - 2)),
            KeyCode::PageDown => scroll(s, s.hits.transcript.height as isize - 2),
            _ => {}
        }
        return;
    }
    let suggestions = s.suggestions();
    match k.code {
        KeyCode::Char('c') if ctrl => {
            if s.selection.is_some() {
                let text = selected_text(s);
                copy(&text);
                s.selection = None;
                s.toast("Copied.");
            } else if s.busy {
                if s.quit_armed.is_some_and(|t| t.elapsed() < Duration::from_secs(2)) {
                    restore();
                    std::process::exit(130);
                }
                cancel.store(true, Ordering::Relaxed);
                s.quit_armed = Some(Instant::now());
                s.toast("Stopping… (Ctrl-C again to quit)");
            } else if !s.input.is_empty() {
                s.set_input("");
            } else if s.quit_armed.is_some_and(|t| t.elapsed() < Duration::from_secs(2)) {
                let _ = lines.send(None);
            } else {
                s.quit_armed = Some(Instant::now());
                s.toast("Press Ctrl-C again to quit");
            }
        }
        KeyCode::Char('d') if ctrl && s.input.is_empty() => {
            if s.busy {
                restore();
                std::process::exit(130);
            }
            let _ = lines.send(None);
        }
        KeyCode::Esc => {
            if !suggestions.is_empty() {
                s.hide_suggestions = true;
            } else if s.selection.is_some() {
                s.selection = None;
            } else if s.busy {
                cancel.store(true, Ordering::Relaxed);
                s.toast("Stopping…");
            } else {
                s.top = None;
            }
        }
        KeyCode::Enter if shift || alt => insert(s, "\n"),
        KeyCode::Char('j') if ctrl => insert(s, "\n"),
        KeyCode::Enter if s.cursor > 0 && s.input.get(s.cursor - 1) == Some(&'\\') => {
            s.input.remove(s.cursor - 1);
            s.cursor -= 1;
            insert(s, "\n");
        }
        KeyCode::Enter | KeyCode::Tab if !suggestions.is_empty() => {
            let name = s.commands[suggestions[s.suggestion.min(suggestions.len() - 1)]].0.clone();
            let complete = s.input_text() == format!("/{name}");
            if complete && k.code == KeyCode::Enter {
                s.set_input("");
                let _ = lines.send(Some(format!("/{name}")));
                if s.busy {
                    s.queued.push(format!("/{name}"));
                }
            } else {
                s.set_input(&format!("/{name} "));
            }
        }
        KeyCode::Tab => {
            complete_path(s);
        }
        KeyCode::Enter => {
            let text = s.input_text();
            if text.trim().is_empty() {
                return;
            }
            s.set_input("");
            s.browsing = None;
            s.selection = None;
            if s.busy {
                s.queued.push(text.clone());
            }
            s.top = None;
            let _ = lines.send(Some(text));
        }
        KeyCode::Char('o') if ctrl => {
            // Opens or closes every tool output and thought.
            let open = !s.items.iter().any(|i| i.open);
            for item in s.items.iter_mut().filter(|i| i.foldable()) {
                item.open = open;
                item.cache = None;
            }
        }
        KeyCode::Char('l') if ctrl => s.top = None,
        KeyCode::Char('a') if ctrl => s.cursor = line_start(s),
        KeyCode::Char('e') if ctrl => s.cursor = line_end(s),
        KeyCode::Char('u') if ctrl => {
            let start = line_start(s);
            s.input.drain(start..s.cursor);
            s.cursor = start;
        }
        KeyCode::Char('k') if ctrl => {
            let end = line_end(s);
            s.input.drain(s.cursor..end);
        }
        KeyCode::Char('w') if ctrl => {
            let mut start = s.cursor;
            while start > 0 && s.input[start - 1].is_whitespace() {
                start -= 1;
            }
            while start > 0 && !s.input[start - 1].is_whitespace() {
                start -= 1;
            }
            s.input.drain(start..s.cursor);
            s.cursor = start;
        }
        KeyCode::Backspace if alt => {
            let mut start = s.cursor;
            while start > 0 && !s.input[start - 1].is_alphanumeric() {
                start -= 1;
            }
            while start > 0 && s.input[start - 1].is_alphanumeric() {
                start -= 1;
            }
            s.input.drain(start..s.cursor);
            s.cursor = start;
        }
        KeyCode::Char(c) if !ctrl => {
            let mut b = [0; 4];
            insert(s, c.encode_utf8(&mut b));
            s.suggestion = 0;
        }
        KeyCode::Backspace if s.cursor > 0 => {
            s.cursor -= 1;
            s.input.remove(s.cursor);
            s.hide_suggestions = false;
        }
        KeyCode::Delete if s.cursor < s.input.len() => {
            s.input.remove(s.cursor);
        }
        KeyCode::Left if alt || ctrl => {
            while s.cursor > 0 && !s.input[s.cursor - 1].is_alphanumeric() {
                s.cursor -= 1;
            }
            while s.cursor > 0 && s.input[s.cursor - 1].is_alphanumeric() {
                s.cursor -= 1;
            }
        }
        KeyCode::Right if alt || ctrl => {
            while s.cursor < s.input.len() && !s.input[s.cursor].is_alphanumeric() {
                s.cursor += 1;
            }
            while s.cursor < s.input.len() && s.input[s.cursor].is_alphanumeric() {
                s.cursor += 1;
            }
        }
        KeyCode::Left => s.cursor = s.cursor.saturating_sub(1),
        KeyCode::Right => s.cursor = (s.cursor + 1).min(s.input.len()),
        KeyCode::Home if ctrl => s.top = Some(0),
        KeyCode::End if ctrl => s.top = None,
        KeyCode::Home => s.cursor = line_start(s),
        KeyCode::End if s.input.is_empty() => s.top = None,
        KeyCode::End => s.cursor = line_end(s),
        KeyCode::Up if !suggestions.is_empty() => s.suggestion = s.suggestion.checked_sub(1).unwrap_or(suggestions.len() - 1),
        KeyCode::Down if !suggestions.is_empty() => s.suggestion = (s.suggestion + 1) % suggestions.len(),
        KeyCode::Up if shift => scroll(s, -1),
        KeyCode::Down if shift => scroll(s, 1),
        KeyCode::Up => {
            let width = s.hits.input.width.max(4) as usize;
            let layout = input_layout(&s.input, width);
            let (row, col) = layout[s.cursor];
            if row > 0 {
                s.cursor = nearest(&layout, row - 1, col);
            } else {
                history(s, -1);
            }
        }
        KeyCode::Down => {
            let width = s.hits.input.width.max(4) as usize;
            let layout = input_layout(&s.input, width);
            let (row, col) = layout[s.cursor];
            if row < layout.last().map(|p| p.0).unwrap_or(0) {
                s.cursor = nearest(&layout, row + 1, col);
            } else {
                history(s, 1);
            }
        }
        KeyCode::PageUp => scroll(s, -(s.hits.transcript.height as isize - 2)),
        KeyCode::PageDown => scroll(s, s.hits.transcript.height as isize - 2),
        _ => {}
    }
}

fn line_start(s: &State) -> usize {
    let mut i = s.cursor;
    while i > 0 && s.input[i - 1] != '\n' {
        i -= 1;
    }
    i
}

fn line_end(s: &State) -> usize {
    let mut i = s.cursor;
    while i < s.input.len() && s.input[i] != '\n' {
        i += 1;
    }
    i
}

/// The character position closest to a row and column of the input box.
fn nearest(layout: &[(usize, usize)], row: usize, col: usize) -> usize {
    let mut best = None;
    for (i, &(r, c)) in layout.iter().enumerate() {
        if r == row && c <= col {
            best = Some(i);
        }
        if r > row {
            break;
        }
    }
    best.or_else(|| layout.iter().position(|&(r, _)| r == row)).unwrap_or(layout.len() - 1)
}

fn history(s: &mut State, step: isize) {
    if s.history.is_empty() {
        return;
    }
    let (index, typed) = match s.browsing.take() {
        Some(b) => b,
        None if step > 0 => return,
        None => (s.history.len(), s.input.clone()),
    };
    let next = index as isize + step;
    if next < 0 {
        s.browsing = Some((index, typed));
        return;
    }
    let next = next as usize;
    if next >= s.history.len() {
        s.input = typed;
        s.cursor = s.input.len();
        return;
    }
    s.input = s.history[next].chars().collect();
    s.cursor = s.input.len();
    s.browsing = Some((next, typed));
}

fn inside(r: Rect, x: u16, y: u16) -> bool {
    x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

fn point(s: &State, x: u16, y: u16) -> Point {
    let t = s.hits.transcript;
    let y = y.clamp(t.y, (t.y + t.height).saturating_sub(1));
    let row = s.hits.top + (y - t.y) as usize;
    Point { row: row.min(s.hits.total.saturating_sub(1)), col: x.saturating_sub(t.x + 1) as usize }
}

fn bar_to(s: &mut State, y: u16) {
    if let Some(bar) = s.hits.bar {
        let height = s.hits.transcript.height as usize;
        let max_top = s.hits.total.saturating_sub(height);
        let frac = (y.saturating_sub(bar.y) as f64 / bar.height.saturating_sub(1).max(1) as f64).clamp(0.0, 1.0);
        let top = (frac * max_top as f64).round() as usize;
        s.top = if top >= max_top { None } else { Some(top) };
    }
}

fn mouse(s: &mut State, m: MouseEvent) {
    let (x, y) = (m.column, m.row);
    match m.kind {
        MouseEventKind::ScrollUp => scroll(s, -3),
        MouseEventKind::ScrollDown => scroll(s, 3),
        MouseEventKind::Down(MouseButton::Left) => {
            if let Some(&(_, a)) = s.hits.buttons.iter().find(|(r, _)| inside(*r, x, y)) {
                answer(s, a);
                return;
            }
            if let Some(&(_, n)) = s.hits.suggestions.iter().find(|(r, _)| inside(*r, x, y)) {
                let list = s.suggestions();
                if let Some(&i) = list.get(n) {
                    let name = s.commands[i].0.clone();
                    s.set_input(&format!("/{name} "));
                }
                return;
            }
            if s.hits.jump.is_some_and(|r| inside(r, x, y)) {
                s.top = None;
                return;
            }
            if s.hits.bar.is_some_and(|r| inside(r, x, y)) {
                s.dragging = Some(Drag::Bar);
                bar_to(s, y);
                return;
            }
            if inside(s.hits.input, x, y) || inside(Rect { x: 0, y: s.hits.input.y, width: s.hits.transcript.width, height: s.hits.input.height }, x, y) {
                let width = s.hits.input.width.max(4) as usize;
                let layout = input_layout(&s.input, width);
                let first_row = layout[s.cursor.min(s.input.len())].0.saturating_sub(s.hits.input.height as usize - 1);
                let row = first_row + y.saturating_sub(s.hits.input.y) as usize;
                s.cursor = nearest(&layout, row, x.saturating_sub(s.hits.input.x) as usize);
                return;
            }
            if inside(s.hits.transcript, x, y) {
                let p = point(s, x, y);
                s.selection = Some((p, p));
                s.dragging = Some(Drag::Select);
            }
        }
        MouseEventKind::Drag(MouseButton::Left) => match s.dragging {
            Some(Drag::Bar) => bar_to(s, y),
            Some(Drag::Select) => {
                // Past the top or bottom edge, the view follows.
                let t = s.hits.transcript;
                if y < t.y + 1 {
                    scroll(s, -1);
                } else if y + 1 >= t.y + t.height {
                    scroll(s, 1);
                }
                let p = point(s, x, y);
                if let Some(sel) = s.selection.as_mut() {
                    sel.1 = p;
                }
            }
            None => {}
        },
        MouseEventKind::Up(MouseButton::Left) => {
            let drag = s.dragging.take();
            if drag != Some(Drag::Select) {
                return;
            }
            match s.selection {
                Some((a, b)) if a == b => {
                    // A click: open or close what is under it.
                    s.selection = None;
                    let row = (y.saturating_sub(s.hits.transcript.y)) as usize;
                    if let Some(&(item, _)) = s.hits.rows.get(row) {
                        if s.items[item].foldable() {
                            s.items[item].open = !s.items[item].open;
                            s.items[item].cache = None;
                        }
                    }
                }
                Some(_) => {
                    let text = selected_text(s);
                    if !text.trim().is_empty() {
                        copy(&text);
                        let n = text.lines().count();
                        s.toast(if n == 1 { "Copied.".to_string() } else { format!("Copied {n} lines.") });
                    }
                }
                None => {}
            }
        }
        _ => {}
    }
}

/// The screen's thread: draws and handles keys and the mouse until the main thread closes it.
fn run(state: Arc<Mutex<State>>, lines: Sender<Option<String>>, cancel: Arc<AtomicBool>) {
    let backend = ratatui::backend::CrosstermBackend::new(std::io::stdout());
    let Ok(mut terminal) = ratatui::Terminal::new(backend) else {
        restore();
        let _ = lines.send(None);
        return;
    };
    let _ = terminal.clear();
    let started = Instant::now();
    let mut last_tick = usize::MAX;
    loop {
        let tick = (started.elapsed().as_millis() / 90) as usize;
        {
            let mut s = state.lock().unwrap_or_else(|e| e.into_inner());
            if s.stop {
                break;
            }
            if s.toast.as_ref().is_some_and(|(_, t)| t.elapsed() > Duration::from_secs(3)) {
                s.toast = None;
                s.dirty = true;
            }
            let animating = s.busy || s.items.iter().any(|i| !i.done);
            if s.dirty || (animating && tick != last_tick) {
                s.dirty = false;
                last_tick = tick;
                let _ = terminal.draw(|f| draw(f, &mut s, tick));
            }
        }
        if !event::poll(Duration::from_millis(30)).unwrap_or(false) {
            continue;
        }
        // Handle everything that is waiting before drawing again.
        let mut s = state.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            match event::read() {
                Ok(Event::Key(k)) if k.kind != KeyEventKind::Release => key(&mut s, k, &lines, &cancel),
                Ok(Event::Mouse(m)) => mouse(&mut s, m),
                Ok(Event::Paste(text)) => {
                    if s.question.is_none() {
                        insert(&mut s, &text);
                    }
                }
                Ok(Event::Resize(..)) => {
                    let _ = terminal.autoresize();
                }
                _ => {}
            }
            if !event::poll(Duration::ZERO).unwrap_or(false) {
                break;
            }
        }
        s.dirty = true;
    }
    restore();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_words_and_long_words() {
        let rows = wrapped("hello world this is bla", 12, ("● ", Style::default()), ("  ", Style::default()), Style::default());
        let plain: Vec<&str> = rows.iter().map(|r| r.plain.as_str()).collect();
        assert!(plain.iter().all(|p| p.width() <= 12), "{plain:?}");
        assert_eq!(plain.join(" ").split_whitespace().collect::<Vec<_>>().join(" "), "● hello world this is bla");
        let rows = wrapped(&"x".repeat(30), 12, ("", Style::default()), ("", Style::default()), Style::default());
        assert!(rows.len() >= 2);
    }

    #[test]
    fn cleans_escape_codes() {
        assert_eq!(clean("\u{1b}[31mred\u{1b}[0m\tx\r\n"), "red    x\n");
    }

    #[test]
    fn markdown_code_and_lists() {
        let rows = markdown("# Title\n- one\n```rust\nlet x = 1;\n```\nsome `code` and **bold**", 40, "● ", Style::default());
        let plain: Vec<String> = rows.iter().map(|r| r.plain.clone()).collect();
        assert_eq!(plain[0], "● Title");
        assert!(plain[1].contains("• one"));
        assert!(plain.iter().any(|p| p.contains("│ let x = 1;")));
        assert!(plain.last().unwrap().contains("some code and bold"));
    }

    #[test]
    fn logo_is_drawn() {
        let rows = welcome("model\nfolder", 80);
        assert_eq!(rows.len(), 15);
        assert!(rows[0].plain.contains('▄') || rows[0].plain.contains('█'));
        assert!(rows.iter().any(|r| r.plain.contains("bla ")));
    }

    #[test]
    fn base64_matches() {
        assert_eq!(base64(b"bla"), "Ymxh");
        assert_eq!(base64(b"bl"), "Ymw=");
    }

    #[test]
    fn input_layout_wraps() {
        let input: Vec<char> = "abcdef\ngh".chars().collect();
        let layout = input_layout(&input, 4);
        assert_eq!(layout[4], (1, 0));
        assert_eq!(*layout.last().unwrap(), (2, 2));
    }
}
