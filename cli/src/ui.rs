//! What the user sees. The terminal shows text as it streams and one line per tool call; `--json` writes
//! one JSON object per event instead, for scripts and other programs.

use crate::llm::Usage;
use crate::plugin::ToolOutput;
use crate::util::Style;
use serde_json::json;
use std::io::{BufRead, IsTerminal, Write};

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Approval {
    Once,
    /// For the rest of the session.
    Always,
    No,
}

pub trait Ui {
    fn text(&mut self, text: &str);
    fn thinking(&mut self, text: &str);
    /// The end of one model reply.
    fn end_reply(&mut self);
    fn tool_start(&mut self, name: &str, summary: &str);
    fn tool_end(&mut self, name: &str, output: &ToolOutput);
    fn approve(&mut self, name: &str, summary: &str, reason: &str) -> Approval;
    fn notice(&mut self, text: &str);
    fn error(&mut self, text: &str);
    fn usage(&mut self, _usage: &Usage) {}
}

pub struct Terminal {
    /// In a chat everything goes to stdout; in one-shot mode only the answer does, the rest to stderr.
    pub chat: bool,
    pub show_thinking: bool,
    out: Style,
    err: Style,
    in_thinking: bool,
    line_open: bool,
}

impl Terminal {
    pub fn new(chat: bool, show_thinking: bool) -> Terminal {
        Terminal { chat, show_thinking, out: Style::stdout(), err: Style::stderr(), in_thinking: false, line_open: false }
    }

    fn side(&mut self, text: &str) {
        self.close_line();
        if self.chat {
            println!("{text}");
        } else {
            eprintln!("{text}");
        }
    }

    fn close_line(&mut self) {
        if self.line_open {
            if self.in_thinking && !self.chat {
                eprintln!();
            } else {
                println!();
            }
            self.line_open = false;
        }
        self.in_thinking = false;
    }

    fn side_style(&self) -> &Style {
        if self.chat {
            &self.out
        } else {
            &self.err
        }
    }
}

/// The first lines of a tool's output, dimmed, for the chat view.
fn preview(text: &str, lines: usize) -> String {
    let all: Vec<&str> = text.lines().collect();
    let mut shown: Vec<String> = all.iter().take(lines).map(|l| crate::util::clip(l, 160).to_string()).collect();
    if all.len() > lines {
        shown.push(format!("… {} more lines", all.len() - lines));
    }
    shown.iter().map(|l| format!("  {l}")).collect::<Vec<_>>().join("\n")
}

impl Ui for Terminal {
    fn text(&mut self, text: &str) {
        if self.in_thinking {
            self.close_line();
        }
        print!("{text}");
        let _ = std::io::stdout().flush();
        self.line_open = !text.ends_with('\n');
    }

    fn thinking(&mut self, text: &str) {
        if !self.show_thinking {
            return;
        }
        let styled = self.side_style().dim(text);
        if self.chat {
            print!("{styled}");
            let _ = std::io::stdout().flush();
        } else {
            eprint!("{styled}");
        }
        self.in_thinking = true;
        self.line_open = !text.ends_with('\n');
    }

    fn end_reply(&mut self) {
        self.close_line();
    }

    fn tool_start(&mut self, name: &str, summary: &str) {
        let s = self.side_style();
        let line = format!("{} {} {}", s.cyan("●"), s.bold(name), crate::util::clip(summary, 200));
        self.side(&line);
    }

    fn tool_end(&mut self, _name: &str, output: &ToolOutput) {
        if output.is_error {
            let line = self.side_style().red(&preview(&output.content, 4));
            self.side(&line);
        } else if self.chat {
            let line = self.side_style().dim(&preview(&output.content, 3));
            self.side(&line);
        }
    }

    fn approve(&mut self, name: &str, summary: &str, reason: &str) -> Approval {
        self.close_line();
        let s = Style::stderr();
        eprintln!("{} {} {}", s.yellow("?"), s.bold(name), summary);
        if !reason.is_empty() {
            eprintln!("  {}", s.dim(reason));
        }
        eprint!("  Allow? [y]es  [a]lways here  [n]o › ");
        let _ = std::io::stderr().flush();
        let answer = read_answer();
        if answer.is_empty() {
            eprintln!("(no one to answer: no)");
        }
        match answer.trim().to_lowercase().as_str() {
            "y" | "yes" => Approval::Once,
            "a" | "always" => Approval::Always,
            _ => Approval::No,
        }
    }

    fn notice(&mut self, text: &str) {
        let line = self.side_style().dim(text);
        self.side(&line);
    }

    fn error(&mut self, text: &str) {
        self.close_line();
        eprintln!("{}", Style::stderr().red(text));
    }

    fn usage(&mut self, usage: &Usage) {
        if self.chat {
            let line = self.out.dim(&format!("  {} in · {} out", usage.input, usage.output));
            self.side(&line);
        }
    }
}

/// An answer typed at the terminal, even when stdin is a pipe.
fn read_answer() -> String {
    let mut line = String::new();
    if std::io::stdin().is_terminal() {
        let _ = std::io::stdin().lock().read_line(&mut line);
    } else {
        #[cfg(unix)]
        if let Ok(tty) = std::fs::File::open("/dev/tty") {
            let _ = std::io::BufReader::new(tty).read_line(&mut line);
        }
    }
    line
}

/// One JSON object per line on stdout.
pub struct Json;

impl Json {
    fn emit(&self, value: serde_json::Value) {
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{value}");
        let _ = out.flush();
    }
}

impl Ui for Json {
    fn text(&mut self, text: &str) {
        self.emit(json!({"type": "text", "text": text}));
    }
    fn thinking(&mut self, text: &str) {
        self.emit(json!({"type": "thinking", "text": text}));
    }
    fn end_reply(&mut self) {
        self.emit(json!({"type": "reply_end"}));
    }
    fn tool_start(&mut self, name: &str, summary: &str) {
        self.emit(json!({"type": "tool_start", "name": name, "summary": summary}));
    }
    fn tool_end(&mut self, name: &str, output: &ToolOutput) {
        self.emit(json!({"type": "tool_end", "name": name, "content": output.content, "is_error": output.is_error}));
    }
    fn approve(&mut self, name: &str, summary: &str, reason: &str) -> Approval {
        self.emit(json!({"type": "denied", "name": name, "summary": summary, "reason": reason}));
        Approval::No
    }
    fn notice(&mut self, text: &str) {
        self.emit(json!({"type": "notice", "text": text}));
    }
    fn error(&mut self, text: &str) {
        self.emit(json!({"type": "error", "text": text}));
    }
    fn usage(&mut self, usage: &Usage) {
        self.emit(json!({"type": "usage", "input": usage.input, "output": usage.output}));
    }
}
