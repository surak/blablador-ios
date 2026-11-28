//! `bla swarm [ID]`: the members of a swarm side by side, live, in a terminal of their own while the chat that
//! coordinates them goes on in another. One pane per member — what it was woken with, what it writes, each tool
//! call — and the board's latest posts along the bottom. It only reads `~/.bla/swarms/<id>`: the workers' event
//! logs and state files and `board.jsonl`, so it can come and go without touching the swarm.

use crate::plugins::swarm::Board;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::crossterm::terminal::{self, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::crossterm::{cursor, execute};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};
use ratatui::Frame;
use serde_json::Value;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::Duration;
use unicode_width::UnicodeWidthChar;

const ACCENT: Color = Color::Rgb(0xf2, 0xb1, 0x34);
/// Only the end of a log is read: a member that has talked for an hour has a long one.
const TAIL: u64 = 400_000;

struct Pane {
    name: String,
    state: String,
    model: String,
    doing: String,
    lines: Vec<(String, Style)>,
}

fn swarms() -> PathBuf {
    crate::util::bla_home().join("swarms")
}

/// The swarm to show: the one named, else the one most recently changed.
fn find(id: Option<&str>) -> Result<PathBuf, String> {
    if let Some(id) = id {
        let dir = swarms().join(id);
        return if dir.join("board.jsonl").exists() || dir.join("title").exists() { Ok(dir) } else { Err(format!("No swarm {id}.")) };
    }
    let newest = std::fs::read_dir(swarms())
        .map_err(|_| "No swarms yet. Start one in bla with /swarm TASK.".to_string())?
        .filter_map(Result::ok)
        .filter_map(|e| {
            let p = e.path();
            let changed = std::fs::metadata(p.join("board.jsonl")).or_else(|_| e.metadata()).and_then(|m| m.modified()).ok()?;
            Some((changed, p))
        })
        .max_by_key(|(t, _)| *t);
    newest.map(|(_, p)| p).ok_or_else(|| "No swarms yet. Start one in bla with /swarm TASK.".into())
}

fn tail(path: &Path) -> String {
    let Ok(mut f) = std::fs::File::open(path) else { return String::new() };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let start = len.saturating_sub(TAIL);
    let _ = f.seek(SeekFrom::Start(start));
    let mut bytes = Vec::new();
    let _ = f.read_to_end(&mut bytes);
    let text = String::from_utf8_lossy(&bytes).into_owned();
    // A cut line at the start is no line at all.
    if start > 0 {
        text.split_once('\n').map(|(_, rest)| rest.to_string()).unwrap_or_default()
    } else {
        text
    }
}

/// A member's log as lines to show.
fn render_log(log: &str) -> Vec<(String, Style)> {
    let dim = Style::default().fg(Color::DarkGray);
    let mut out: Vec<(String, Style)> = Vec::new();
    let mut text = String::new();
    let flush = |text: &mut String, out: &mut Vec<(String, Style)>| {
        for l in text.trim_end().lines() {
            out.push((l.to_string(), Style::default()));
        }
        text.clear();
    };
    for line in log.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        let s = |k: &str| v[k].as_str().unwrap_or_default().to_string();
        match v["type"].as_str().unwrap_or_default() {
            "wake" => {
                flush(&mut text, &mut out);
                out.push((format!("── woke on {} ──", s("model")), Style::default().fg(ACCENT)));
                for p in s("prompt").lines().filter(|l| l.starts_with('#')) {
                    out.push((p.to_string(), dim));
                }
            }
            "text" => text.push_str(&s("text")),
            "reply_end" => flush(&mut text, &mut out),
            "tool_start" => {
                flush(&mut text, &mut out);
                out.push((format!("● {} {}", s("name"), s("summary")), Style::default().fg(Color::Cyan)));
            }
            "tool_end" if v["is_error"].as_bool() == Some(true) => {
                out.push((format!("  ✗ {}", s("content").lines().next().unwrap_or_default()), Style::default().fg(Color::Red)))
            }
            "denied" => out.push((format!("  ⊘ {} {}", s("name"), s("reason")), Style::default().fg(Color::Red))),
            "error" => out.push((format!("! {}", s("text")), Style::default().fg(Color::Red))),
            _ => {}
        }
    }
    flush(&mut text, &mut out);
    out
}

fn load(dir: &Path) -> Vec<Pane> {
    let logs = dir.join("logs");
    let mut names: Vec<String> = std::fs::read_dir(&logs)
        .map(|r| {
            r.filter_map(Result::ok)
                .filter_map(|e| e.file_name().to_str().and_then(|n| n.strip_suffix(".state")).map(String::from))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
        .into_iter()
        .map(|name| {
            let state = std::fs::read_to_string(logs.join(format!("{name}.state"))).unwrap_or_default();
            let mut it = state.lines();
            let (state, model, doing) = (it.next().unwrap_or("").to_string(), it.next().unwrap_or("").to_string(), it.next().unwrap_or("").to_string());
            let lines = render_log(&tail(&logs.join(format!("{name}.jsonl"))));
            Pane { name, state, model, doing, lines }
        })
        .collect()
}

/// Wraps to the width and keeps what fits at the bottom.
fn fit(lines: &[(String, Style)], width: usize, height: usize) -> Vec<Line<'static>> {
    let mut rows: Vec<Line> = Vec::new();
    for (text, style) in lines {
        let mut row = String::new();
        let mut w = 0;
        for c in text.chars() {
            let cw = c.width().unwrap_or(0);
            if w + cw > width.max(1) {
                rows.push(Line::from(Span::styled(std::mem::take(&mut row), *style)));
                w = 0;
            }
            row.push(c);
            w += cw;
        }
        rows.push(Line::from(Span::styled(row, *style)));
    }
    let skip = rows.len().saturating_sub(height);
    rows.split_off(skip)
}

fn draw(frame: &mut Frame, board: &Board, panes: &[Pane], selected: usize, zoom: bool) {
    let area = frame.area();
    let posts: Vec<_> = board.posts().into_iter().filter(|p| !p.private).collect();
    let [top, main, bottom] = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(5), Constraint::Length(8)])
        .areas(area);
    let working = panes.iter().filter(|p| p.state == "working").count();
    let header = format!(
        " {} · {} members, {working} working · {} posts · ←→ select · z zoom · q quit",
        board.title(),
        panes.len(),
        posts.len()
    );
    frame.render_widget(Paragraph::new(Span::styled(header, Style::default().add_modifier(Modifier::BOLD))), top);

    let shown: Vec<(usize, &Pane)> = if zoom { panes.iter().enumerate().filter(|(i, _)| *i == selected).collect() } else { panes.iter().enumerate().collect() };
    if shown.is_empty() {
        frame.render_widget(Paragraph::new(" No members yet: the coordinator adds them with swarm_add."), main);
    }
    // One row up to four members, two rows above that.
    let rows = if shown.len() > 4 { 2 } else { 1 };
    let per_row = shown.len().div_ceil(rows).max(1);
    let row_areas = Layout::default().direction(Direction::Vertical).constraints(vec![Constraint::Ratio(1, rows as u32); rows]).split(main);
    for (r, chunk) in shown.chunks(per_row).enumerate() {
        let cols = Layout::default()
            .direction(Direction::Horizontal)
            .constraints(vec![Constraint::Ratio(1, chunk.len() as u32); chunk.len()])
            .split(row_areas[r]);
        for ((i, pane), rect) in chunk.iter().zip(cols.iter()) {
            draw_pane(frame, pane, *rect, *i == selected);
        }
    }

    let dim = Style::default().fg(Color::DarkGray);
    let block = Block::default().borders(Borders::TOP).border_style(dim).title(" Board ");
    let inner = block.inner(bottom);
    frame.render_widget(block, bottom);
    let lines: Vec<(String, Style)> = posts
        .iter()
        .map(|p| {
            let to = p.to.iter().map(|t| format!("@{t}")).collect::<Vec<_>>().join(" ");
            (format!("#{} @{} → {to}: {}", p.n, p.from, p.text.replace('\n', " ")), Style::default())
        })
        .collect();
    // One line each on the board: the panes are where the detail is.
    let rows: Vec<Line> = lines
        .iter()
        .rev()
        .take(inner.height as usize)
        .rev()
        .map(|(t, s)| Line::from(Span::styled(crate::util::clip(t, inner.width as usize * 3).to_string(), *s)))
        .collect();
    frame.render_widget(Paragraph::new(rows), inner);
}

fn draw_pane(frame: &mut Frame, pane: &Pane, rect: Rect, selected: bool) {
    let color = match pane.state.as_str() {
        "working" => Color::Green,
        "killed" => Color::DarkGray,
        _ => Color::Yellow,
    };
    let title = Line::from(vec![
        Span::styled(format!(" @{} ", pane.name), Style::default().add_modifier(Modifier::BOLD)),
        Span::styled(format!("{} ", pane.state), Style::default().fg(color)),
    ]);
    let model = Line::from(Span::styled(format!(" {} ", pane.model), Style::default().fg(Color::DarkGray))).right_aligned();
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(if selected { BorderType::Thick } else { BorderType::Rounded })
        .border_style(Style::default().fg(if selected { ACCENT } else { color }))
        .title(title)
        .title_bottom(model);
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    let mut lines = pane.lines.clone();
    if pane.state == "working" && !pane.doing.is_empty() {
        lines.push((format!("… {}", pane.doing), Style::default().fg(Color::Green)));
    }
    frame.render_widget(Paragraph::new(fit(&lines, inner.width as usize, inner.height as usize)), inner);
}

pub fn run(id: Option<&str>) -> Result<(), String> {
    let dir = find(id)?;
    let board = Board { dir: dir.clone() };
    terminal::enable_raw_mode().map_err(|e| e.to_string())?;
    let mut out = std::io::stdout();
    let _ = execute!(out, EnterAlternateScreen, cursor::Hide);
    let restore = || {
        let _ = execute!(std::io::stdout(), LeaveAlternateScreen, cursor::Show);
        let _ = terminal::disable_raw_mode();
    };
    let backend = ratatui::backend::CrosstermBackend::new(std::io::stdout());
    let mut term = match ratatui::Terminal::new(backend) {
        Ok(t) => t,
        Err(e) => {
            restore();
            return Err(e.to_string());
        }
    };
    let (mut selected, mut zoom) = (0usize, false);
    loop {
        let panes = load(&dir);
        selected = selected.min(panes.len().saturating_sub(1));
        let _ = term.draw(|f| draw(f, &board, &panes, selected, zoom));
        if event::poll(Duration::from_millis(400)).unwrap_or(false) {
            if let Ok(Event::Key(k)) = event::read() {
                if k.kind == KeyEventKind::Release {
                    continue;
                }
                match k.code {
                    KeyCode::Char('q') | KeyCode::Esc if !zoom || k.code == KeyCode::Char('q') => break,
                    KeyCode::Esc => zoom = false,
                    KeyCode::Char('c') if k.modifiers.contains(event::KeyModifiers::CONTROL) => break,
                    KeyCode::Right | KeyCode::Tab | KeyCode::Char('l') => selected = (selected + 1) % panes.len().max(1),
                    KeyCode::Left | KeyCode::BackTab | KeyCode::Char('h') => selected = (selected + panes.len().max(1) - 1) % panes.len().max(1),
                    KeyCode::Char('z') | KeyCode::Enter => zoom = !zoom,
                    _ => {}
                }
            }
        }
    }
    restore();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_log_reads_as_a_pane() {
        let log = [
            r##"{"type":"wake","model":"alias-code","prompt":"New posts:\n#1 @coordinator → @parser: Brief\n\nDo it."}"##,
            r#"{"type":"text","text":"Reading "}"#,
            r#"{"type":"text","text":"the parser."}"#,
            r#"{"type":"tool_start","name":"read","summary":"src/parse.rs"}"#,
            r#"{"type":"tool_end","name":"read","content":"no such file","is_error":true}"#,
            r#"{"type":"reply_end"}"#,
        ]
        .join("\n");
        let lines: Vec<String> = render_log(&log).into_iter().map(|(t, _)| t).collect();
        assert_eq!(lines, ["── woke on alias-code ──", "#1 @coordinator → @parser: Brief", "Reading the parser.", "● read src/parse.rs", "  ✗ no such file"]);
        let rows = fit(&[("abcdef".into(), Style::default())], 4, 1);
        assert_eq!(rows.len(), 1, "keeps the bottom");
    }
}
