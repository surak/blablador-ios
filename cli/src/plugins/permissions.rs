//! Permission rules and modes, like Claude Code's.
//!
//! Rules are `tool` or `tool(pattern)`: `bash(git *)`, `read(.env*)`, `edit(src/**)`. Claude Code's spelling
//! works too (`Bash(npm run test:*)`, `Write`, `MultiEdit`). Deny wins over ask, ask over allow; then the mode:
//!
//! - default: everything but the few things that can't be taken back is allowed; those ask
//! - careful: file changes and other commands ask too
//! - plan: read-only, changes and commands are refused
//! - yolo: nothing asks at all (`/yolo`); only deny rules hold
//!
//! In default mode a command asks only when it can't be undone: it deletes or overwrites files, escalates (sudo,
//! su), rewrites git history or discards work (`git reset --hard`, `clean -fd`, `checkout -f`, deleting branches or
//! tags), shuts the machine down, or pipes something downloaded into a shell. Everything else — builds, tests,
//! formatters, package managers, git, scripts, editors — just runs, including in pipes, `&&` chains and with
//! redirections, as long as no part of it interprets a string that was assembled at runtime (`eval`, `sh -c "$x"`).
//! Reading a file never asks (except credentials, and files under a deny rule), wherever it is; writing inside the
//! project or into a temp folder doesn't ask (checkpoints keep `/undo`), writing anywhere else does; deleting files
//! in a temp folder doesn't ask, deleting anything else does.

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

/// Commands that only look at things: they print, search and count.
const LOOKING: &[&str] = &[
    "ls", "pwd", "wc", "head", "tail", "cat", "rg", "grep", "ag", "ack", "which", "date", "echo", "stat", "du", "tree", "uname", "whoami", "find", "fd",
    "file", "sort", "uniq", "cut", "tr", "diff", "cmp", "comm", "basename", "dirname", "realpath", "nl", "column", "tac", "rev", "shasum", "sha256sum",
    "md5sum", "md5", "true", "false", "printf", "jq", "yq", "df", "ps", "lsof", "id", "groups", "hostname", "sw_vers", "nproc", "uptime", "seq", "expr",
    "od", "xxd", "strings", "less", "more", "man", "sleep", "locale", "cal", "sed", "awk", "gawk",
];
/// Options that make a looking command write a file, run a program or follow a symlink out of the project.
const RISKY_LONG: &[&str] =
    &["--pre", "--output", "--exec", "--follow", "--ext-diff", "--config", "--dereference", "--files-from", "--hostname-bin", "--search-zip", "--in-place"];
const RISKY_SHORT: &[char] = &['o', 'C', 'R', 'L', 'f', 'x', 'e', 'i'];
/// Options that mean something risky only for one program.
fn risky_short_for(program: &str) -> &'static [char] {
    match program {
        "tree" => &['l'],
        "grep" => &['S', 'O', 'p'],
        "rg" => &['z'],
        "fd" => &['X'],
        "du" | "stat" | "ls" => &['H'],
        _ => &[],
    }
}
/// `find` options that run programs or delete.
const FIND_RISKY: &[&str] = &["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"];
/// `sed` and `awk` options that write a file in place or run a command.
const STREAM_WRITES: &[&str] = &["-i", "--in-place", "-s", "--separate"];

/// Commands that can't be undone by `/undo`: they delete, overwrite or change the machine. In default mode these ask.
const DANGEROUS: &[&str] = &[
    "rm", "rmdir", "unlink", "shred", "srm", "truncate", "dd", "mkfs", "mkswap", "fdisk", "diskutil", "sudo", "doas", "su", "chown", "chmod", "chgrp",
    "kill", "pkill", "killall", "shutdown", "reboot", "halt", "poweroff", "launchctl", "systemctl", "mv", "mount", "umount", "crontab", "dropdb",
];
/// Programs that run a script or another command by name: `sh script.sh`, `ssh host …`. A pipe that feeds one of
/// these turns whatever came before it into something to run (`curl … | sh`), so that asks.
const INTERPRETERS: &[&str] = &["sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh", "eval", "ssh", "source"];
/// Programs that are handed code as a string: `sh -c "…"`, `eval "$x"`, `python -c "…"`. What is in that string
/// can't be read here, so one assembled from variables or substitutions asks.
const EVAL: &[&str] = &["eval"];
const EVAL_FLAGS: &[(&str, &str)] = &[
    ("sh", "-c"),
    ("bash", "-c"),
    ("zsh", "-c"),
    ("dash", "-c"),
    ("su", "-c"),
    ("sudo", "-s"),
    ("python", "-c"),
    ("python3", "-c"),
    ("perl", "-e"),
    ("ruby", "-e"),
    ("node", "-e"),
    ("node", "--eval"),
];
/// git subcommands that only print.
const GIT_LOOKING: &[&str] = &["status", "diff", "log", "show", "blame", "ls-files", "rev-parse", "describe", "shortlog", "grep", "cat-file", "show-ref"];

/// Characters that make a command line more than one simple command.
const OPERATORS: &[char] = &['|', '&', ';', '>', '<', '`', '$', '\n', '(', ')', '{', '}'];

/// The command line with its quoted strings blanked out, so an operator inside one (`rg "a|b"`) isn't read as an
/// operator. A backslash blanks whatever it escapes, inside single quotes too (`echo 'it\'s; here'`), so an escaped
/// separator stays part of its word.
pub fn unquoted(command: &str) -> String {
    let mut out = String::with_capacity(command.len());
    let mut quote: Option<char> = None;
    let mut escaped = false;
    for c in command.chars() {
        if escaped {
            escaped = false;
            out.push(' ');
            continue;
        }
        if c == '\\' {
            escaped = true;
            out.push(' ');
            continue;
        }
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                }
                out.push(' ');
            }
            None if c == '\'' || c == '"' => {
                quote = Some(c);
                out.push(' ');
            }
            None => out.push(c),
        }
    }
    out
}

/// The simple commands in a command line, split at shell operators outside quotes; rules have to hold for each.
pub fn simple_commands(command: &str) -> Vec<String> {
    let masked = unquoted(command);
    let mut out = Vec::new();
    let mut start = 0;
    let ends: Vec<usize> = masked.char_indices().filter(|(_, c)| matches!(c, '|' | '&' | ';' | '\n' | '(' | ')' | '`' | '{' | '}')).map(|(i, _)| i).collect();
    for end in ends.into_iter().chain(std::iter::once(command.len())) {
        let part = command.get(start..end).unwrap_or_default().trim().trim_matches(['$', '<', '>']).trim();
        start = end + 1;
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

/// Whether a command line can lose work or change the machine: something in it deletes or overwrites, escalates,
/// rewrites git history, or splices a download into a shell. These ask even in default mode; nothing else does.
pub fn dangerous(command: &str, cwd: &Path) -> bool {
    let masked = unquoted(command);
    // A string assembled at runtime and handed to a shell or interpreter can't be read here: `eval "$x"`,
    // `bash -c "$SCRIPT"`.
    if command.contains(['$', '`']) && runs_assembled_code(command) {
        return true;
    }
    // `cd /tmp/rec && rm -f *.png` is judged where it runs: the parts are followed in order, each in the folder the
    // ones before it left behind.
    let mut dir = cwd.to_path_buf();
    for part in simple_commands(command) {
        if let Some(rest) = part.trim().strip_prefix("cd ") {
            let target = rest.trim().trim_matches(['"', '\'']);
            if !target.is_empty() && !target.starts_with('-') {
                dir = util::resolve(&dir, target);
            }
            continue;
        }
        if part_dangerous(&part, &dir, cwd) {
            return true;
        }
    }
    // `curl … | sh`: a pipe that feeds a program which runs what it is given.
    let parts: Vec<&str> = masked.split(['|', ';', '\n']).map(str::trim).filter(|p| !p.is_empty()).collect();
    parts.iter().enumerate().any(|(i, part)| i > 0 && part_is_interpreter(part))
}

/// Whether a command line hands a string to a shell or interpreter: `eval …`, `sh -c …`, `python3 -c …`.
fn runs_assembled_code(command: &str) -> bool {
    let words: Vec<&str> = command.split_whitespace().collect();
    words.iter().enumerate().any(|(i, w)| {
        let program = w.rsplit('/').next().unwrap_or(w);
        EVAL.contains(&program) || EVAL_FLAGS.iter().any(|(p, flag)| *p == program && words.get(i + 1) == Some(flag))
    })
}

fn part_is_interpreter(part: &str) -> bool {
    let first = part.split_whitespace().next().unwrap_or_default();
    INTERPRETERS.contains(&first.rsplit('/').next().unwrap_or(first))
}

fn part_dangerous(command: &str, dir: &Path, project: &Path) -> bool {
    let words: Vec<String> = command.split_whitespace().map(|w| w.trim_matches(['"', '\'']).to_string()).collect();
    let Some(first) = words.first().map(String::as_str) else { return false };
    let program = first.rsplit('/').next().unwrap_or(first);
    if DANGEROUS.contains(&program) {
        // Deleting scratch files is how a job cleans up after itself; anything else a dangerous program is given
        // still asks.
        if matches!(program, "rm" | "rmdir" | "unlink" | "shred" | "truncate" | "mv")
            && words[1..].iter().filter(|w| !w.starts_with('-')).all(|w| {
                let path = util::resolve(dir, w);
                scratch(&path) && !util::inside(project, &path)
            })
        {
            return false;
        }
        return true;
    }
    if program == "git" {
        return git_dangerous(&words[1..], dir);
    }
    // `sed -i`, `awk -i inplace`: rewriting a file where it is loses what was there.
    matches!(program, "sed" | "awk" | "gawk") && words[1..].iter().any(|w| STREAM_WRITES.contains(&w.as_str()))
}

/// Files that hold credentials rather than content: reading one puts a key into the transcript. They ask in every
/// mode but yolo (and a deny rule still wins). Ordinary dotfiles (`.gitignore`, `.github`) are not secrets.
fn secret(path: &Path) -> bool {
    const FOLDERS: &[&str] = &[".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".password-store", ".git-credentials", ".config/gh", ".config/gcloud"];
    const NAMES: &[&str] = &["credentials", "credentials.json", ".netrc", ".pgpass", ".htpasswd", ".npmrc", ".pypirc", ".dockercfg", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"];
    let shown = path.to_string_lossy();
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    let env = (name == ".env" || name.starts_with(".env.")) && !name.ends_with(".example") && !name.ends_with(".sample") && !name.ends_with(".template");
    FOLDERS.iter().any(|f| shown.contains(&format!("/{f}/")))
        || env
        || NAMES.contains(&name)
        || name.ends_with(".pem")
        || name.ends_with(".p12")
        || name.ends_with(".key")
}

/// A path under a temporary folder (`/tmp`, `$TMPDIR`, `/var/folders/…`): a scratch file, which nothing loses by
/// being deleted. Never one of the system's own folders there.
fn scratch(path: &Path) -> bool {
    const OWN: &[&str] = &["/tmp", "/var/tmp", "/private/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders"];
    let real = util::real_path(path);
    // The folder itself isn't scratch: `rm -rf /tmp` still asks.
    OWN.iter().any(|own| real.starts_with(own) && real != Path::new(own))
}

/// Whether a git command line can discard work. Looking subcommands never do; the ones that change things ask only
/// when they would throw work away, so `git add`, `git commit` and `git rebase` run while `git reset --hard` asks.
fn git_dangerous(args: &[String], cwd: &Path) -> bool {
    let flags: Vec<&str> = args.iter().map(String::as_str).filter(|a| a.starts_with('-')).collect();
    let values: Vec<&str> = args.iter().map(String::as_str).filter(|a| !a.starts_with('-')).collect();
    let Some(sub) = values.first().copied() else { return false };
    let has = |set: &[&str]| flags.iter().any(|f| set.contains(f));
    let changes = || values.iter().any(|v| ["add", "remove", "rm", "rename", "set-url", "prune", "deinit", "update", "sync"].contains(v));
    match sub {
        "branch" | "tag" => has(&["-d", "-D", "--delete", "-m", "-M", "-f", "--force"]) || values.get(1).copied() == Some("add"),
        "remote" => values[1..].iter().any(|v| ["add", "remove", "rm", "set-url", "rename", "prune"].contains(v)),
        "push" => {
            has(&["-f", "--force", "--force-with-lease", "--mirror", "--delete", "-d", "--no-verify"])
                || values.iter().any(|v| v.starts_with('+') || v.starts_with(':'))
        }
        "reset" => has(&["--hard", "--merge", "--keep"]),
        "clean" => flags.iter().any(|f| f.contains('f') || *f == "--force"),
        "checkout" => has(&["-f", "--force"]) || values.get(1).copied() == Some(".") || flags.iter().any(|f| f.starts_with("--pathspec")),
        "restore" => has(&["-f", "--force", "--staged", "-s", "--source"]) || values.get(1).copied() == Some("."),
        "stash" => values.get(1).copied().is_some_and(|v| v == "drop" || v == "clear"),
        "submodule" => changes(),
        "gc" | "prune" | "filter-branch" | "update-ref" | "rm" | "mv" => true,
        // Inside a trusted project this is ordinary work; in an untrusted one it can run what the repository brought.
        "rebase" | "pull" | "merge" | "cherry-pick" | "revert" | "am" | "apply" | "worktree" => !git_config_is_plain(cwd),
        _ => false,
    }
}

/// A command line that only looks: simple commands that only look, joined by |, &&, || or ;, with no
/// redirections or substitutions, no risky options and nothing outside `cwd`. This is stricter than default mode
/// needs; it is what "always allow" remembers and what careful mode asks about.
pub fn looks_only(command: &str, cwd: &Path, trusted: bool) -> bool {
    // Throwing output away or merging it changes nothing.
    let mut command = command.to_string();
    for harmless in ["2>/dev/null", "&>/dev/null", ">/dev/null", "2>&1", "2> /dev/null", "> /dev/null"] {
        command = command.replace(harmless, " ");
    }
    let trusted = trusted || git_config_is_plain(cwd);
    let masked = unquoted(&command);
    if masked.contains(['>', '<', '`', '$', '\n', '(', ')', '{', '}', '~', '\\']) {
        return false;
    }
    // A lone & would run something in the background.
    if masked.replace("&&", "").contains('&') {
        return false;
    }
    let parts: Vec<&str> = masked.split(['|', '&', ';']).map(str::trim).filter(|p| !p.is_empty()).collect();
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
    let program = first.rsplit('/').next().unwrap_or(first);
    let rest = if program == "git" {
        match words.get(1) {
            Some(sub) if trusted && GIT_LOOKING.contains(&sub.as_str()) => &words[2..],
            _ => return false,
        }
    } else if LOOKING.contains(&program) {
        &words[1..]
    } else {
        return false;
    };
    if program == "find" && rest.iter().any(|w| FIND_RISKY.contains(&w.as_str())) {
        return false;
    }
    if matches!(program, "sed" | "awk" | "gawk") && rest.iter().any(|w| STREAM_WRITES.contains(&w.as_str())) {
        return false;
    }
    rest.iter().all(|w| {
        if let Some(long) = w.strip_prefix("--") {
            return !RISKY_LONG.iter().any(|r| format!("--{long}").starts_with(r));
        }
        if program == "find" && w.starts_with('-') {
            return true;
        }
        if let Some(short) = w.strip_prefix('-') {
            return !short.chars().any(|c| RISKY_SHORT.contains(&c) || risky_short_for(program).contains(&c));
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
        // Yolo asks nothing at all, ask rules included; only a deny rule still stops it.
        let quiet = matches!(self.mode(), Mode::Yolo);
        if let Some(rule) = self.ask.iter().find(|r| any_part(r)).filter(|_| !quiet) {
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
                // Looking at the user's own files is not a change, wherever they are: /tmp frames, a log in ~/Library,
                // a document on the Desktop. Secrets still ask, and plan mode stays read-only.
                Some(p) if p.starts_with('-') => Decision::Ask("it reads a program's flow of text".into()),
                Some(p) if secret(&util::resolve(cwd, p)) => Decision::Ask("it reads a file that may hold a secret".into()),
                _ => Decision::Allow,
            },
            (Mode::Plan, _) => Decision::Deny("plan mode is read-only; describe the plan, and the user can switch with /mode".into()),
            (Mode::Default, Kind::Write) => match s {
                Some(p) if in_project(p) || scratch(&util::resolve(cwd, p)) => Decision::Allow,
                Some(_) => Decision::Ask("it is outside the working directory".into()),
                // Memory and skills reach every later prompt: the user sees those changes.
                None => Decision::Ask("it changes what bla remembers in every session".into()),
            },
            // Default mode lets a command run unless it can't be undone; careful mode asks unless it only looks.
            (Mode::Default, Kind::Exec) => match s {
                Some(c) if dangerous(c, cwd) => Decision::Ask(String::new()),
                _ => Decision::Allow,
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
        vec![
            CommandSpec { name: "mode".into(), help: "show or change the permission mode: default, careful, plan, yolo".into() },
            CommandSpec { name: "yolo".into(), help: "stop asking until the session ends (yolo mode); it asks nothing".into() },
            CommandSpec { name: "safe".into(), help: "back to asking: default mode".into() },
        ]
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
        self.switch(name, args)
    }
}

impl Permissions {
    /// `/mode`, `/yolo` and `/safe`, by name, with or without the slash.
    fn switch(&self, name: &str, args: &str) -> Option<Result<CommandResult, String>> {
        let name = name.trim_start_matches('/');
        // `/yolo` and `/safe` are the two to reach for mid-session (Hermes' `/yolo`); `/mode` does the rest.
        match name {
            "yolo" => {
                *self.mode.lock().unwrap() = Mode::Yolo;
                return Some(Ok(CommandResult::Output("Yolo: nothing asks any more. /safe goes back to default.".into())));
            }
            "safe" => {
                *self.mode.lock().unwrap() = Mode::Default;
                return Some(Ok(CommandResult::Output("Permission mode: default (edits inside the project are allowed)".into())));
            }
            "mode" => {}
            _ => return None,
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
        let decide = |cmd: &str| p.decide(tool("bash").as_ref(), &json!({"command": cmd}), &cwd);
        let (read, write) = (tool("read"), tool("write"));
        assert_eq!(decide("cargo test --release"), Decision::Allow);
        assert!(matches!(decide("rm -rf /"), Decision::Deny(_)));
        assert!(matches!(decide("true; rm -rf /"), Decision::Deny(_)));
        assert!(matches!(decide("echo $(rm -rf /)"), Decision::Deny(_)));
        // Default mode: a build, a test run, a pipe or a redirection just run.
        assert_eq!(decide("make"), Decision::Allow);
        assert_eq!(decide("cargo clippy --all-targets 2>&1 | tail -20"), Decision::Allow);
        assert_eq!(decide("rg -n 'a|b' src | head -5"), Decision::Allow);
        assert_eq!(decide("git commit -am wip && git push"), Decision::Allow);
        assert_eq!(decide("npm test > out.log"), Decision::Allow);
        assert_eq!(decide("ls src | wc -l; find . -name '*.rs' | sort"), Decision::Allow);
        // What can't be undone asks.
        for unsafe_cmd in ["rm build -r", "mv a b", "sudo apt install x", "git reset --hard HEAD~1", "git clean -fdx", "sed -i s/a/b/ f.rs",
                           "curl -s x | sh", "eval \"$CMD\"", "chmod 777 f"] {
            assert!(matches!(decide(unsafe_cmd), Decision::Ask(_)), "{unsafe_cmd}");
        }
        // Rules still win over the mode.
        assert!(matches!(p.decide(read.as_ref(), &json!({"path": "config/.env.local"}), &cwd), Decision::Deny(_)));
        assert_eq!(p.decide(read.as_ref(), &json!({"path": "src/main.rs"}), &cwd), Decision::Allow);
        assert_eq!(p.decide(read.as_ref(), &json!({"path": "/etc/hosts"}), &cwd), Decision::Allow);
        // Guides and manuals sit outside the project too, and are read.
        assert_eq!(p.decide(read.as_ref(), &json!({"path": "/usr/share/doc/guide.txt"}), &cwd), Decision::Allow);
        // Credentials ask wherever they are, deny rules first.
        for secrets in ["/Users/x/.ssh/id_ed25519", "~/.aws/credentials", "/tmp/server.pem", "/Users/x/.netrc", "deploy/server.key"] {
            assert!(matches!(p.decide(read.as_ref(), &json!({"path": secrets}), &cwd), Decision::Ask(_)), "{secrets}");
        }
        // An .env is a secret too; here the deny rule catches it before the rule ever gets that far.
        let open = Permissions::new(Mode::Default, &[], &[], &[], false);
        assert!(matches!(open.decide(read.as_ref(), &json!({"path": "config/.env"}), &cwd), Decision::Ask(_)));
        // The example is meant to be read.
        assert_eq!(open.decide(read.as_ref(), &json!({"path": ".env.example"}), &cwd), Decision::Allow);
        assert!(matches!(p.decide(read.as_ref(), &json!({"path": "config/.env"}), &cwd), Decision::Deny(_)));
        for plain in ["/Users/x/project/.gitignore", "src/.github/ci.yml", "README.md"] {
            let plain = plain.to_string();
            assert_eq!(p.decide(read.as_ref(), &json!({"path": plain}), &cwd), Decision::Allow, "{plain}");
        }
        assert_eq!(p.decide(write.as_ref(), &json!({"path": "a.txt"}), &cwd), Decision::Allow);
        // Scratch files are written and deleted freely; the project itself still asks to be deleted. (The cwd of
        // this test is the system temp folder, so the scratch project goes in /tmp proper.)
        let scratch_dir = Path::new("/tmp").join(format!("bla-scratch-{}", util::random_hex(6)));
        std::fs::create_dir_all(&scratch_dir).unwrap();
        let frame = scratch_dir.join("frame.png").display().to_string();
        // (A fresh set of rules: this test's own deny rule names `rm -rf` and would catch the cleanup.)
        let free = Permissions::new(Mode::Default, &[], &[], &[], false);
        let okay = |cmd: &str| free.decide(tool("bash").as_ref(), &json!({"command": cmd}), &cwd);
        assert_eq!(free.decide(write.as_ref(), &json!({"path": frame}), &cwd), Decision::Allow);
        assert_eq!(okay(&format!("rm -f {frame}")), Decision::Allow);
        assert_eq!(okay(&format!("cd {} && rm -rf r && mkdir r", scratch_dir.display())), Decision::Allow);
        // A real folder, or the temp folder itself, still asks.
        assert!(matches!(okay(&format!("rm -rf {}", cwd.display())), Decision::Ask(_)));
        assert!(matches!(okay("rm -rf /tmp"), Decision::Ask(_)));
        assert!(matches!(okay("rm -rf build"), Decision::Ask(_)));
        *p.mode.lock().unwrap() = Mode::Careful;
        assert!(matches!(p.decide(write.as_ref(), &json!({"path": "a.txt"}), &cwd), Decision::Ask(_)));
        // Careful asks for more: only looking commands run.
        assert_eq!(decide("ls -la | wc -l"), Decision::Allow);
        assert!(matches!(decide("make"), Decision::Ask(_)));
        assert!(matches!(decide("ls > out.txt"), Decision::Ask(_)));
        *p.mode.lock().unwrap() = Mode::Default;
        // Outside the project and not scratch: the home folder, say.
        assert!(matches!(p.decide(write.as_ref(), &json!({"path": "~/notes/x.md"}), &cwd), Decision::Ask(_)));
        *p.mode.lock().unwrap() = Mode::Plan;
        assert!(matches!(p.decide(write.as_ref(), &json!({"path": "a.txt"}), &cwd), Decision::Deny(_)));
        *p.mode.lock().unwrap() = Mode::Yolo;
        // A deny rule still holds; one that isn't there lets everything through.
        assert!(matches!(decide("rm -rf build"), Decision::Deny(_)));
        assert!(matches!(decide("rm -rf /"), Decision::Deny(_)));
    }

    #[test]
    fn yolo_asks_nothing() {
        let cwd = std::env::temp_dir().canonicalize().unwrap();
        // Ask rules and everything the modes would ask about stay silent in yolo; a deny rule still holds.
        let p = Permissions::new(Mode::Yolo, &[], &["bash(make*)".into()], &["bash(rm -rf /)".into()], false);
        let decide = |cmd: &str| p.decide(tool("bash").as_ref(), &json!({"command": cmd}), &cwd);
        assert_eq!(decide("make install"), Decision::Allow);
        assert_eq!(decide("sudo apt install x"), Decision::Allow);
        assert_eq!(decide("rm -rf build"), Decision::Allow);
        assert!(matches!(decide("rm -rf /"), Decision::Deny(_)));
        let read = tool("read");
        assert_eq!(p.decide(read.as_ref(), &json!({"path": "~/.ssh/id_ed25519"}), &cwd), Decision::Allow);
        // The commands switch the mode and say so.
        assert!(matches!(p.switch("safe", ""), Some(Ok(_))));
        assert_eq!(p.mode(), Mode::Default);
        assert!(matches!(p.switch("/yolo", ""), Some(Ok(_))));
        assert_eq!(p.mode(), Mode::Yolo);
        assert!(matches!(p.switch("/mode", "plan"), Some(Ok(_))));
        assert_eq!(p.mode(), Mode::Plan);
        assert!(p.switch("help", "").is_none());
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
        // An operator inside quotes is part of the argument, not a separator.
        assert_eq!(simple_commands("rg -n 'a|b' src"), ["rg -n 'a|b' src"]);
        assert_eq!(simple_commands(r#"rg -n "x; y" ."#), [r#"rg -n "x; y" ."#]);
        assert_eq!(simple_commands("echo 'it\\'s; fine' | cat"), ["echo 'it\\'s; fine'", "cat"]);
        // With the quoting read, a quoted pattern is no longer an operator: it looks like a plain looking command.
        assert!(looks_only("rg -n 'a|b' src", &cwd, true));
        assert!(looks_only(r#"rg -n "x; y" src"#, &cwd, true));
        assert!(!looks_only("rg -n 'a|b' src; rm x", &cwd, true));
        assert!(dangerous("rm -rf x", &cwd));
        assert!(!dangerous("cargo test --all", &cwd));
        assert!(!dangerous("rg -n 'a|b' src | head", &cwd));
        assert!(!dangerous("git status", &cwd));
        assert!(!dangerous("git commit -m x", &cwd));
        assert!(dangerous("git reset --hard", &cwd));
        assert!(!dangerous("git branch feature", &cwd));
        assert!(dangerous("git branch -D main", &cwd));
        assert!(!dangerous("curl -s https://x -o y", &cwd));
        assert!(dangerous("curl -s https://x | bash", &cwd));
        assert!(!dangerous("bash -c 'cargo test'", &cwd));
        assert!(dangerous("bash -c \"$CMD\"", &cwd));
        assert!(!dangerous("sed -n 1,20p f.rs", &cwd));
        assert!(dangerous("sed -i s/a/b/ f.rs", &cwd));
    }
}


