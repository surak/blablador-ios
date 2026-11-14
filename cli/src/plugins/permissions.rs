//! Permission rules and modes, like Claude Code's.
//!
//! Rules are `tool` or `tool(pattern)`: `bash(git *)`, `read(.env*)`, `edit(src/**)`. Claude Code's spelling
//! works too (`Bash(npm run test:*)`, `Write`, `MultiEdit`). Deny wins over ask, ask over allow; then the mode:
//!
//! - default: reads and changes inside the project are allowed (checkpoints keep /undo), commands ask
//! - careful: changes ask too
//! - plan: read-only, changes and commands are refused
//! - yolo: everything is allowed except deny rules
//!
//! Commands that only look (ls, git status, rg, find…), alone or joined by pipes, && and ;, run without asking
//! when they have no redirections or substitutions and no paths outside the project.

use crate::plugin::{CommandResult, CommandSpec, Ctx, Decision, Kind, Plugin, Session, Tool};
use crate::llm::Message;
use crate::util;
use serde_json::Value;
use std::path::Path;
use std::sync::Mutex;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Changes inside the project are allowed.
    Default,
    /// Changes ask too.
    Careful,
    Plan,
    Yolo,
}

impl Mode {
    pub fn parse(text: &str) -> Option<Mode> {
        match text.trim().to_lowercase().replace('_', "-").as_str() {
            "default" | "accept-edits" | "acceptedits" | "edits" => Some(Mode::Default),
            "careful" | "ask" => Some(Mode::Careful),
            "plan" | "read-only" | "readonly" => Some(Mode::Plan),
            "yolo" | "bypass" | "bypasspermissions" | "dangerously-skip-permissions" => Some(Mode::Yolo),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Mode::Default => "default",
            Mode::Careful => "careful",
            Mode::Plan => "plan",
            Mode::Yolo => "yolo",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Rule {
    tool: String,
    pattern: Option<String>,
    text: String,
}

impl Rule {
    pub fn parse(text: &str) -> Rule {
        let trimmed = text.trim();
        let (tool, pattern) = match trimmed.find('(') {
            Some(open) if trimmed.ends_with(')') => (&trimmed[..open], Some(trimmed[open + 1..trimmed.len() - 1].trim().to_string())),
            _ => (trimmed, None),
        };
        let tool = match tool.trim().to_lowercase().as_str() {
            "multiedit" | "notebookedit" => "edit".to_string(),
            other => other.to_string(),
        };
        // Claude Code writes prefixes as `npm run test:*`.
        let pattern = pattern.filter(|p| !p.is_empty() && p != "*").map(|p| match p.strip_suffix(":*") {
            Some(prefix) => format!("{prefix}*"),
            None => p,
        });
        Rule { tool, pattern, text: trimmed.to_string() }
    }

    fn matches(&self, tool: &str, kind: Kind, subject: Option<&str>, cwd: &Path) -> bool {
        // MCP tools: Claude Code's `mcp__server__tool` names match bla's `server__tool`, with * as a wildcard.
        let rule_tool = if tool.starts_with("mcp__") { self.tool.as_str() } else { self.tool.strip_prefix("mcp__").unwrap_or(&self.tool) };
        if rule_tool != "*" && rule_tool != tool && !(rule_tool.contains('*') && util::glob_match(rule_tool, tool, false)) {
            return false;
        }
        let Some(pattern) = &self.pattern else { return true };
        let Some(subject) = subject else { return false };
        if kind == Kind::Exec {
            return util::glob_match(pattern, subject.trim(), false);
        }
        // Paths: compare relative to the project when inside it, absolute otherwise.
        let path = util::resolve(cwd, subject);
        let shown = path.strip_prefix(cwd).map(|p| p.display().to_string()).unwrap_or_else(|_| path.display().to_string());
        let pattern = pattern.strip_prefix("./").unwrap_or(pattern);
        let pattern = if let Some(rest) = pattern.strip_prefix("~/") { util::home().join(rest).display().to_string() } else { pattern.to_string() };
        util::glob_match(&pattern, &shown, true)
            || util::glob_match(&pattern, &path.display().to_string(), true)
            // A bare file name matches it in any folder.
            || (!pattern.contains('/') && path.file_name().map(|n| util::glob_match(&pattern, &n.to_string_lossy(), true)).unwrap_or(false))
    }
}

const LOOKING: &[&str] = &[
    "ls", "pwd", "wc", "head", "tail", "cat", "rg", "grep", "which", "date", "echo", "stat", "du", "tree", "uname", "whoami", "find", "file",
    "sort", "uniq", "cut", "tr", "diff", "cmp", "basename", "dirname", "realpath", "nl", "column", "shasum", "sha256sum", "md5sum", "md5",
    "true", "false", "printf", "jq", "fd", "df",
];
/// find options that run programs or write files.
const FIND_RISKY: &[&str] = &["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"];
/// git subcommands that only look. They are auto-allowed only in trusted projects: a repository that arrives with
/// its own .git folder can make git run programs (core.fsmonitor, diff.external, a pager).
const GIT_LOOKING: &[&str] = &["status", "diff", "log", "show", "blame", "ls-files", "rev-parse", "describe", "shortlog"];
/// Options that run programs, write files or follow symlinks out of the project.
const RISKY_LONG: &[&str] = &["--pre", "--output", "--exec", "--follow", "--ext-diff", "--config", "--dereference", "--files-from", "--hostname-bin", "--search-zip"];
const RISKY_SHORT: &[char] = &['o', 'C', 'R', 'L', 'f', 'x', 'e'];
/// Short options that mean something risky only for one program (following symlinks, running decompressors).
fn risky_short_for(program: &str) -> &'static [char] {
    match program {
        "tree" => &['l'],
        "grep" => &['S', 'r', 'O', 'p'],
        "rg" => &['z'],
        "fd" => &['X'],
        "du" | "stat" | "ls" => &['H'],
        _ => &[],
    }
}

/// Characters that make a command more than one simple command.
const OPERATORS: &[char] = &['|', '&', ';', '>', '<', '`', '$', '\n', '(', ')', '{', '}'];

/// The simple commands in a command line, split at shell operators; rules have to hold for each of them.
pub fn simple_commands(command: &str) -> Vec<String> {
    let mut out = Vec::new();
    for part in command.split(['|', '&', ';', '\n', '(', ')', '`', '{', '}']) {
        let part = part.trim().trim_matches(['$', '<', '>']).trim();
        if part.is_empty() {
            continue;
        }
        out.push(part.to_string());
        // Also the command behind wrappers, so `sudo rm -rf /` meets a rule for `rm -rf *`.
        let mut words: Vec<&str> = part.split_whitespace().collect();
        let mut unwrapped = false;
        while let Some(first) = words.first() {
            match *first {
                "sudo" | "env" | "command" | "nice" | "time" | "nohup" | "xargs" | "exec" | "doas" => {
                    words.remove(0);
                    while let Some(w) = words.first().copied().filter(|w| w.starts_with('-') || w.contains('=')) {
                        words.remove(0);
                        // Options that take a value: sudo -u user, nice -n 5, xargs -I {}.
                        if matches!(w, "-u" | "-g" | "-C" | "-n" | "-I" | "-L" | "-P") && !words.is_empty() {
                            words.remove(0);
                        }
                    }
                    unwrapped = true;
                }
                "bash" | "sh" | "zsh" | "dash" if words.get(1) == Some(&"-c") => {
                    let script = words[2..].join(" ");
                    out.extend(simple_commands(script.trim_matches(['"', '\''])));
                    words.clear();
                }
                _ => break,
            }
        }
        if unwrapped && !words.is_empty() {
            out.push(words.join(" "));
        }
    }
    out
}

/// A command line that only looks: simple commands that only look, joined by |, &&, || or ;, with no
/// redirections or substitutions, no risky options and nothing outside `cwd`.
pub fn looks_only(command: &str, cwd: &Path, trusted: bool) -> bool {
    // Throwing output away or merging it changes nothing.
    let mut command = command.to_string();
    for harmless in ["2>/dev/null", "&>/dev/null", ">/dev/null", "2>&1", "2> /dev/null", "> /dev/null"] {
        command = command.replace(harmless, " ");
    }
    let trusted = trusted || git_config_is_plain(cwd);
    let command = command.as_str();
    if command.contains(['>', '<', '`', '$', '\n', '(', ')', '{', '}', '~', '\\']) {
        return false;
    }
    // A lone & would run something in the background.
    if command.replace("&&", "").contains('&') {
        return false;
    }
    let parts: Vec<&str> = command.split(['|', '&', ';']).map(str::trim).filter(|p| !p.is_empty()).collect();
    !parts.is_empty() && parts.iter().all(|p| simple_looks_only(p, cwd, trusted))
}

/// The repository's own git config sets nothing that makes git run a program (fsmonitor, external diff, pager,
/// textconv, ssh command, includes), so looking git commands are safe even in an untrusted project.
fn git_config_is_plain(cwd: &Path) -> bool {
    let Some(git) = cwd.ancestors().map(|d| d.join(".git")).find(|g| g.exists()) else { return true };
    // A .git file points elsewhere (worktrees, submodules): don't follow it.
    if !git.is_dir() {
        return false;
    }
    let config = std::fs::read_to_string(git.join("config")).unwrap_or_default().to_lowercase();
    const RUNS: &[&str] = &["fsmonitor", "external", "pager", "textconv", "sshcommand", "include", "hookspath", "askpass", "editor", "program", "filter", "alias", "!"];
    !RUNS.iter().any(|r| config.contains(r))
}

fn simple_looks_only(command: &str, cwd: &Path, trusted: bool) -> bool {
    let words: Vec<String> = command.split_whitespace().map(|w| w.trim_matches(['"', '\'']).to_string()).collect();
    let Some(first) = words.first().map(String::as_str) else { return false };
    let rest = if first == "git" {
        match words.get(1) {
            Some(sub) if trusted && GIT_LOOKING.contains(&sub.as_str()) => &words[2..],
            _ => return false,
        }
    } else if LOOKING.contains(&first) {
        &words[1..]
    } else {
        return false;
    };
    if first == "find" && rest.iter().any(|w| FIND_RISKY.contains(&w.as_str())) {
        return false;
    }
    rest.iter().all(|w| {
        if let Some(long) = w.strip_prefix("--") {
            return !RISKY_LONG.iter().any(|r| format!("--{long}").starts_with(r));
        }
        if first == "find" && w.starts_with('-') {
            return true;
        }
        if let Some(short) = w.strip_prefix('-') {
            return !short.chars().any(|c| RISKY_SHORT.contains(&c) || risky_short_for(first).contains(&c));
        }
        // Words are checked as paths: patterns and messages pass, anything reaching outside doesn't.
        !w.contains("..") && !Path::new(w).is_absolute() && util::inside(cwd, &cwd.join(w))
    })
}

pub struct Permissions {
    mode: Mutex<Mode>,
    trusted: bool,
    allow: Vec<Rule>,
    ask: Vec<Rule>,
    deny: Vec<Rule>,
}

impl Permissions {
    /// `trusted`: the project is trusted, so its git configuration may be relied on.
    pub fn new(mode: Mode, allow: &[String], ask: &[String], deny: &[String], trusted: bool) -> Permissions {
        let parse = |list: &[String]| list.iter().map(|r| Rule::parse(r)).collect();
        Permissions { mode: Mutex::new(mode), trusted, allow: parse(allow), ask: parse(ask), deny: parse(deny) }
    }

    pub fn mode(&self) -> Mode {
        *self.mode.lock().unwrap()
    }

    pub fn decide(&self, tool: &dyn Tool, args: &Value, cwd: &Path) -> Decision {
        let name = tool.name().to_lowercase();
        let kind = tool.kind(args);
        let subject = tool.subject(args);
        let s = subject.as_deref();
        // Commands: deny and ask rules hold for any part of `a; b && c`; an allow rule only for a single command.
        let parts = if kind == Kind::Exec { s.map(simple_commands).unwrap_or_default() } else { Vec::new() };
        let any_part = |rule: &Rule| rule.matches(&name, kind, s, cwd) || parts.iter().any(|p| rule.matches(&name, kind, Some(p), cwd));
        if let Some(rule) = self.deny.iter().find(|r| any_part(r)) {
            return Decision::Deny(format!("the rule {} forbids it", rule.text));
        }
        if let Some(rule) = self.ask.iter().find(|r| any_part(r)) {
            return Decision::Ask(format!("the rule {} asks first", rule.text));
        }
        let single = kind != Kind::Exec || !s.unwrap_or_default().contains(OPERATORS);
        if single && self.allow.iter().any(|r| r.matches(&name, kind, s, cwd)) {
            return Decision::Allow;
        }
        let in_project = |p: &str| util::inside(cwd, &util::resolve(cwd, p));
        let mode = self.mode();
        match (mode, kind) {
            (Mode::Yolo, _) | (_, Kind::Internal) => Decision::Allow,
            (_, Kind::Read) => match s {
                Some(p) if !in_project(p) && mode != Mode::Plan => Decision::Ask("it is outside the working directory".into()),
                _ => Decision::Allow,
            },
            (Mode::Plan, _) => Decision::Deny("plan mode is read-only; describe the plan, and the user can switch with /mode".into()),
            (Mode::Default, Kind::Write) => match s {
                Some(p) if in_project(p) => Decision::Allow,
                Some(_) => Decision::Ask("it is outside the working directory".into()),
                // Memory and skills reach every later prompt: the user sees those changes.
                None => Decision::Ask("it changes what bla remembers in every session".into()),
            },
            (_, Kind::Exec) => match s {
                Some(c) if looks_only(c, cwd, self.trusted) => Decision::Allow,
                _ => Decision::Ask(String::new()),
            },
            (_, Kind::Write) => match s {
                Some(p) if !in_project(p) => Decision::Ask("it is outside the working directory".into()),
                _ => Decision::Ask(String::new()),
            },
        }
    }
}

impl Plugin for Permissions {
    fn name(&self) -> &str {
        "permissions"
    }
    fn description(&self) -> &str {
        "Allow, ask and deny rules and the default, careful, plan and yolo modes"
    }
    fn commands(&self) -> Vec<CommandSpec> {
        vec![CommandSpec { name: "mode".into(), help: "show or change the permission mode: default, careful, plan, yolo".into() }]
    }
    fn system_prompt(&self, _session: &Session, sections: &mut Vec<String>) {
        if self.mode() == Mode::Plan {
            sections.push("Plan mode is on: you can only read and look. Investigate, then present a plan; don't try to change files or run commands that change things.".into());
        }
    }
    fn pre_tool(&self, session: &Session, tool: &dyn Tool, args: &mut Value) -> Decision {
        self.decide(tool, args, session.cwd)
    }
    fn command(&self, _ctx: &Ctx, name: &str, args: &str, _messages: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        if name != "mode" {
            return None;
        }
        if args.trim().is_empty() {
            return Some(Ok(CommandResult::Output(format!("Permission mode: {}", self.mode().name()))));
        }
        Some(match Mode::parse(args) {
            Some(mode) => {
                *self.mode.lock().unwrap() = mode;
                Ok(CommandResult::Output(format!("Permission mode: {}", mode.name())))
            }
            None => Err("Modes: default, careful, plan, yolo".into()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugins::core_tools::CoreTools;
    use serde_json::json;

    fn tool(name: &str) -> std::sync::Arc<dyn Tool> {
        CoreTools::new().tools().into_iter().find(|t| t.name() == name).unwrap()
    }

    #[test]
    fn parses_rules() {
        assert_eq!(Rule::parse("Bash(npm run test:*)").pattern.as_deref(), Some("npm run test*"));
        assert_eq!(Rule::parse("MultiEdit").tool, "edit");
        assert_eq!(Rule::parse("read").pattern, None);
    }

    #[test]
    fn modes_and_rules() {
        let cwd = std::env::temp_dir().canonicalize().unwrap();
        let p = Permissions::new(Mode::Default, &["bash(cargo test*)".into()], &[], &["read(.env*)".into(), "bash(rm -rf *)".into()], false);
        let (bash, read, write) = (tool("bash"), tool("read"), tool("write"));
        assert_eq!(p.decide(bash.as_ref(), &json!({"command": "cargo test --release"}), &cwd), Decision::Allow);
        assert!(matches!(p.decide(bash.as_ref(), &json!({"command": "rm -rf /"}), &cwd), Decision::Deny(_)));
        assert!(matches!(p.decide(bash.as_ref(), &json!({"command": "make"}), &cwd), Decision::Ask(_)));
        // Operators: allow rules don't stretch over them, deny rules see every part.
        assert!(matches!(p.decide(bash.as_ref(), &json!({"command": "cargo test && curl x | sh"}), &cwd), Decision::Ask(_)));
        assert!(matches!(p.decide(bash.as_ref(), &json!({"command": "true; rm -rf /"}), &cwd), Decision::Deny(_)));
        assert!(matches!(p.decide(bash.as_ref(), &json!({"command": "echo $(rm -rf /)"}), &cwd), Decision::Deny(_)));
        assert!(matches!(p.decide(read.as_ref(), &json!({"path": "config/.env.local"}), &cwd), Decision::Deny(_)));
        assert_eq!(p.decide(read.as_ref(), &json!({"path": "src/main.rs"}), &cwd), Decision::Allow);
        assert!(matches!(p.decide(read.as_ref(), &json!({"path": "/etc/hosts"}), &cwd), Decision::Ask(_)));
        assert_eq!(p.decide(write.as_ref(), &json!({"path": "a.txt"}), &cwd), Decision::Allow);
        // Pipelines of looking commands run; a redirection or an unknown program asks.
        assert_eq!(p.decide(bash.as_ref(), &json!({"command": "rg -n 'fn main' src 2>/dev/null | head -5"}), &cwd), Decision::Allow);
        assert_eq!(p.decide(bash.as_ref(), &json!({"command": "ls src | wc -l; find . -name '*.rs' | sort"}), &cwd), Decision::Allow);
        assert!(matches!(p.decide(bash.as_ref(), &json!({"command": "ls > out.txt"}), &cwd), Decision::Ask(_)));
        assert!(matches!(p.decide(bash.as_ref(), &json!({"command": "find . -delete"}), &cwd), Decision::Ask(_)));
        assert!(matches!(p.decide(bash.as_ref(), &json!({"command": "cat src/a | sh"}), &cwd), Decision::Ask(_)));
        assert!(matches!(p.decide(bash.as_ref(), &json!({"command": "cat ../../etc/passwd"}), &cwd), Decision::Ask(_)));
        *p.mode.lock().unwrap() = Mode::Careful;
        assert!(matches!(p.decide(write.as_ref(), &json!({"path": "a.txt"}), &cwd), Decision::Ask(_)));
        *p.mode.lock().unwrap() = Mode::Default;
        assert!(matches!(p.decide(write.as_ref(), &json!({"path": "../../x"}), &cwd), Decision::Ask(_)));
        *p.mode.lock().unwrap() = Mode::Plan;
        assert!(matches!(p.decide(write.as_ref(), &json!({"path": "a.txt"}), &cwd), Decision::Deny(_)));
        *p.mode.lock().unwrap() = Mode::Yolo;
        assert_eq!(p.decide(bash.as_ref(), &json!({"command": "make"}), &cwd), Decision::Allow);
        assert!(matches!(p.decide(bash.as_ref(), &json!({"command": "rm -rf build"}), &cwd), Decision::Deny(_)));
    }

    #[test]
    fn looking_commands() {
        let cwd = std::env::temp_dir().canonicalize().unwrap();
        assert!(looks_only("ls -la", &cwd, false));
        assert!(looks_only("wc -l", &cwd, false));
        assert!(looks_only("git status --short", &cwd, true));
        // Untrusted projects: git only when the repository's config can't make it run programs.
        let repo = cwd.join(format!("bla-git-{}", util::random_hex(6)));
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::write(repo.join(".git/config"), "[core]\n\tbare = false\n").unwrap();
        assert!(looks_only("git status", &repo, false));
        std::fs::write(repo.join(".git/config"), "[core]\n\tfsmonitor = ./evil\n").unwrap();
        assert!(!looks_only("git status", &repo, false));
        let _ = std::fs::remove_dir_all(&repo);
        for bad in ["ls; rm x", "cat /etc/passwd", "cat ../secret", "git push", "echo $HOME", "rg --pre ./x pattern",
                    "rg --pre=./evil x", "tree -oout.txt", "file -C -m x", "grep -R key", "rg -L key", "git branch -D main",
                    "git remote add o https://x", "du --files-from=list", "rg --hostname-bin ./evil x", "tree -l", "grep -S -r key ."] {
            assert!(!looks_only(bad, &cwd, true), "{bad}");
        }
        assert_eq!(simple_commands("a && b; c | d $(e)"), ["a", "b", "c", "d", "e"]);
        assert!(simple_commands("sudo -u x rm -rf /").contains(&"rm -rf /".to_string()));
        assert!(simple_commands("bash -c 'rm -rf /'").contains(&"rm -rf /".to_string()));
    }
}
