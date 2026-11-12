//! Project context: `AGENTS.md` (or `CLAUDE.md`) from `~/.bla` and from every folder between the project
//! root and the working directory, the git branch, and `@path` mentions that attach a file to the message.

use crate::plugin::{Plugin, Session};
use crate::util;
use std::path::{Path, PathBuf};

const MAX_CONTEXT_FILE: usize = 40 * 1024;
const MAX_MENTION: usize = 100 * 1024;

pub struct Context;

/// Instruction files, outermost first.
pub fn instruction_files(cwd: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let global = util::bla_home().join("AGENTS.md");
    if global.is_file() {
        found.push(global);
    }
    let root = crate::config::project_root(cwd);
    let mut dirs: Vec<&Path> = cwd.ancestors().take_while(|d| d.starts_with(&root)).collect();
    dirs.reverse();
    for dir in dirs {
        for name in ["AGENTS.md", "CLAUDE.md"] {
            let file = dir.join(name);
            if file.is_file() {
                found.push(file);
                break;
            }
        }
    }
    found
}

fn git_branch(cwd: &Path) -> Option<String> {
    let root = crate::config::project_root(cwd);
    let head = std::fs::read_to_string(root.join(".git").join("HEAD")).ok()?;
    head.trim().strip_prefix("ref: refs/heads/").map(String::from).or_else(|| Some(format!("detached at {}", util::clip(head.trim(), 12))))
}

/// Attaches files mentioned as `@path` (inside the working directory) to the message.
pub fn expand_mentions(cwd: &Path, text: &str) -> String {
    let mut attached = String::new();
    let mut seen = Vec::new();
    for word in text.split_whitespace() {
        let Some(name) = word.strip_prefix('@') else { continue };
        let name = name.trim_end_matches([',', '.', ';', ':', '!', '?', ')']);
        if name.is_empty() || seen.contains(&name) {
            continue;
        }
        let path = util::resolve(cwd, name);
        if !path.is_file() || !util::inside(cwd, &path) {
            continue;
        }
        let Ok(bytes) = std::fs::read(&path) else { continue };
        if bytes.len() > MAX_MENTION || bytes.iter().take(8000).any(|&b| b == 0) {
            continue;
        }
        seen.push(name);
        attached.push_str(&format!("\n\n<file path=\"{name}\">\n{}\n</file>", String::from_utf8_lossy(&bytes).trim_end()));
    }
    format!("{text}{attached}")
}

impl Plugin for Context {
    fn name(&self) -> &str {
        "context"
    }
    fn description(&self) -> &str {
        "AGENTS.md and CLAUDE.md instructions, the git branch, and @file mentions"
    }
    fn system_prompt(&self, session: &Session, sections: &mut Vec<String>) {
        for file in instruction_files(session.cwd) {
            if let Ok(text) = std::fs::read_to_string(&file) {
                let text = util::clip(text.trim(), MAX_CONTEXT_FILE);
                if !text.is_empty() {
                    sections.push(format!("Instructions from {}:\n\n{text}", file.display()));
                }
            }
        }
        if let Some(branch) = git_branch(session.cwd) {
            sections.push(format!("This is a git repository, on branch {branch}."));
        }
    }
    fn user_prompt(&self, session: &Session, text: &mut String) -> Result<(), String> {
        if text.contains('@') {
            *text = expand_mentions(session.cwd, text);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_instructions_and_mentions() {
        let dir = std::env::temp_dir().join(format!("bla-ctx-{}", util::random_hex(8)));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        let dir = dir.canonicalize().unwrap();
        std::fs::write(dir.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::write(dir.join("CLAUDE.md"), "root rules").unwrap();
        std::fs::write(dir.join("sub/AGENTS.md"), "sub rules").unwrap();
        std::fs::write(dir.join("sub/notes.txt"), "the notes").unwrap();
        let files = instruction_files(&dir.join("sub"));
        assert!(files.ends_with(&[dir.join("CLAUDE.md"), dir.join("sub/AGENTS.md")]));
        assert_eq!(git_branch(&dir.join("sub")).as_deref(), Some("main"));
        let text = expand_mentions(&dir.join("sub"), "look at @notes.txt, and @missing");
        assert!(text.contains("<file path=\"notes.txt\">\nthe notes\n</file>"));
        assert!(!expand_mentions(&dir.join("sub"), "@../CLAUDE.md").contains("<file"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
