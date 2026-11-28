//! Swarms, after Antigravity's `/swarm`: the conversation becomes a coordinator that splits a task into pieces
//! that don't collide, briefs named workers (`@parser`, `@fix-1`…) and a `@verifier` for every two to four of
//! them, and judges what comes back. Everyone talks on one shared board, in order, with `@name`, `@group` (the
//! name without its `-n`, so `@fix` reaches `@fix-1` to `@fix-4`) and `@all`; nobody talks in private, except the
//! user with `/swarm tell`.
//!
//! The board is `~/.bla/swarms/<id>/board.jsonl`, one post per line; a post's number is its line. Each worker is a
//! thread here that sleeps on the board for nothing and, when a post mentions it, runs `bla --json` in its folder
//! with the new posts, resuming its own session so it keeps its conversation. Inside, the worker has `board_post`
//! and `board_read` (this plugin again, in member mode, chosen by `BLA_SWARM_BOARD`). A worker's final answer goes
//! to the coordinator when it posted nothing itself. A worker's child can't ask the user anything (`--json`
//! declines), so its mode is chosen when it is added, and a mode that runs commands passes the parent's permission
//! check first. There is no `@monitor` model: `swarm_wait` itself notices when every member sleeps and nothing is
//! addressed to the coordinator, and says so, which costs no tokens.
//!
//! A worker may get its own git worktree on the branch `swarm/<id>/<name>`; removing it deletes the worktree but
//! keeps the branch, and refuses while there are uncommitted changes unless told to discard them.

use crate::plugin::{CommandResult, CommandSpec, Ctx, Kind, Plugin, Session, Tool, ToolCtx, ToolOutput};
use crate::llm::Message;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const COORDINATOR: &str = "coordinator";
const ENV_BOARD: &str = "BLA_SWARM_BOARD";
const ENV_NAME: &str = "BLA_SWARM_MEMBER";
/// Members at most, verifiers included: each is a full agent, and a swarm spends quota fast.
pub const MAX_MEMBERS: usize = 8;
/// One wake-up of one worker: a run that goes on longer is stopped.
const RUN_TIMEOUT: Duration = Duration::from_secs(60 * 60);

const GUIDE: &str = "You are the coordinator of a swarm. Don't do the technical work yourself: split it, brief, judge, report.\n\
1. swarm_start with a short title.\n\
2. Split the task into pieces that don't collide (one worker per file, package or question). For each, swarm_add a worker \
with a short name (parser, api-tests, docs; a pool of similar workers as fix-1, fix-2… so @fix reaches them all) and a \
brief that says what it owns, what it must not touch, and what done means. Read-only investigators get mode plan.\n\
3. Add a verifier (name verifier, or verifier-1…) for every 2 to 4 workers: it reads the diffs, runs the tests and reports \
problems to the worker that wrote the code, which fixes them. It can run on another model.\n\
4. When several workers edit or build at once, give each worktree: true, and have them commit before you remove them; \
then merge their branches.\n\
5. swarm_wait for the board, judge what comes back, swarm_post corrections, and repeat until the work is done and verified. \
When swarm_wait says everyone is idle, the work has stalled: restart it with a post. Remove workers that are done.\n\
6. Report the outcome to the user. The user can watch with /swarm board, or every member side by side with `bla swarm` in another terminal.";

/// Blablador's models and what each is for, so every member runs on the one its job needs.
pub const MODELS: &[(&str, &str)] = &[
    ("alias-code", "writing and fixing code: the default for workers that edit or build"),
    ("alias-fast", "quick, cheap, read-only jobs: searching, listing, investigating, small mechanical edits"),
    ("alias-large", "careful reasoning and review: the default for verifiers, so they don't share the workers' blind spots"),
    ("alias-huge", "the hardest pieces only (design, subtle bugs, races): the strongest and the slowest"),
    (blablador_models::DEFAULT_MODEL, "long documents and broad reading, writing docs, and general work"),
];

/// The models a member tries in order: the one asked for (deepseek at HZDR when none is), then the aliases that
/// suit its job, so a model that is down or out of quota hands the work on instead of stopping it.
pub fn models_for(name: &str, mode: &str, asked: Option<&str>) -> Vec<String> {
    let by_role: &[&str] = if name == "verifier" || group(name) == Some("verifier") {
        &["alias-large", "alias-huge", "alias-code", "alias-fast"]
    } else if mode == "plan" {
        &["alias-fast", "alias-large", "alias-code", "alias-huge"]
    } else {
        &["alias-code", "alias-large", "alias-huge", "alias-fast"]
    };
    let mut chain = vec![asked.unwrap_or(blablador_models::DEFAULT_MODEL).to_string()];
    if asked.is_some() {
        chain.push(blablador_models::DEFAULT_MODEL.to_string());
    }
    for m in by_role {
        if !chain.iter().any(|c| c == m) {
            chain.push(m.to_string());
        }
    }
    chain.dedup();
    chain
}

fn models_guide() -> String {
    let lines: Vec<String> = MODELS.iter().map(|(m, what)| format!("- {m}: {what}")).collect();
    format!("Pick each member's model by its job (swarm_add model):\n{}\nWithout one, every member runs on deepseek-v4.1-flash-at-hzdr; when a model fails, the member falls back to the aliases for its job (verifiers alias-large, read-only members alias-fast, the others alias-code, then the rest).", lines.join("\n"))
}

const MEMBER_GUIDE: &str = "You are a member of a swarm, working with other agents on one task. You talk to them only on the \
shared board: board_post with @names (@coordinator, another member, a group such as @fix for fix-1…, or @all), and \
board_read to read it. Do what your brief says and only that; don't touch what others own. When you are done, or blocked, \
post a short report to @coordinator (and to @verifier when there is one and your work needs checking): what changed, \
which files, how it was tested. Keep posts short; put details in files when they are long. If you are a verifier: read \
the diffs (git diff), run the tests, and post problems to the worker that wrote the code, and the verdict to @coordinator.";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Post {
    #[serde(skip)]
    pub n: usize,
    pub from: String,
    pub to: Vec<String>,
    pub text: String,
    pub time: u64,
    /// The user's word to one member, not shown on the board.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub private: bool,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// `fix-3` is in the group `fix`.
pub fn group(name: &str) -> Option<&str> {
    let (base, n) = name.rsplit_once('-')?;
    (!base.is_empty() && !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit())).then_some(base)
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 32
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !matches!(name, "all" | COORDINATOR | "user")
}

impl Post {
    /// Whether this post is for `name`: mentioned directly, by its group or by @all, and not its own.
    pub fn for_member(&self, name: &str) -> bool {
        self.from != name
            && self.to.iter().any(|t| {
                let t = t.trim_start_matches('@');
                t == name || t == "all" || group(name) == Some(t)
            })
    }

    fn line(&self) -> String {
        let to = self.to.iter().map(|t| format!("@{}", t.trim_start_matches('@'))).collect::<Vec<_>>().join(" ");
        format!("#{} @{} → {to}{}: {}", self.n, self.from, if self.private { " (private)" } else { "" }, self.text.trim())
    }
}

/// The board on disk. Appends are single writes to a file opened for appending, so posts from several processes
/// don't interleave, and their order is their number.
#[derive(Clone, Debug)]
pub struct Board {
    pub dir: PathBuf,
}

impl Board {
    fn file(&self) -> PathBuf {
        self.dir.join("board.jsonl")
    }

    pub fn post(&self, from: &str, to: &[String], text: &str, private: bool) -> Result<usize, String> {
        let to: Vec<String> = to.iter().map(|t| t.trim().trim_start_matches('@').to_string()).filter(|t| !t.is_empty()).collect();
        if to.is_empty() {
            return Err("Say who it is for: @name, @group or @all.".into());
        }
        let post = Post { n: 0, from: from.into(), to, text: text.into(), time: now(), private };
        let mut line = serde_json::to_string(&post).map_err(|e| e.to_string())?;
        line.push('\n');
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(self.file()).map_err(|e| e.to_string())?;
        file.write_all(line.as_bytes()).map_err(|e| e.to_string())?;
        Ok(self.posts().len())
    }

    pub fn posts(&self) -> Vec<Post> {
        let Ok(file) = std::fs::File::open(self.file()) else { return Vec::new() };
        BufReader::new(file)
            .lines()
            .map_while(Result::ok)
            .filter_map(|l| serde_json::from_str::<Post>(&l).ok())
            .enumerate()
            .map(|(i, mut p)| {
                p.n = i + 1;
                p
            })
            .collect()
    }

    /// Where a member's live events go, for `bla swarm` to show.
    pub fn log(&self, name: &str) -> PathBuf {
        self.dir.join("logs").join(format!("{name}.jsonl"))
    }

    /// A member's state for the viewer: `working|waiting|killed`, its model and what it is doing, one per line.
    pub fn set_state(&self, name: &str, state: &str, model: &str, doing: &str) {
        let dir = self.dir.join("logs");
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join(format!("{name}.state")), format!("{state}\n{model}\n{doing}\n"));
    }

    pub fn title(&self) -> String {
        std::fs::read_to_string(self.dir.join("title")).unwrap_or_default().trim().to_string()
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum State {
    Working,
    Waiting,
    Killed,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            State::Working => "working",
            State::Waiting => "waiting",
            State::Killed => "killed",
        }
    }
}

struct Member {
    name: String,
    /// The models it tries in order, and the one it is on.
    models: Vec<String>,
    on: Arc<Mutex<usize>>,
    mode: String,
    folder: PathBuf,
    worktree: bool,
    state: Arc<Mutex<State>>,
    kill: Arc<AtomicBool>,
    /// What it is doing, from its last tool call.
    doing: Arc<Mutex<String>>,
    tokens: Arc<Mutex<u64>>,
}

struct Running {
    id: String,
    board: Board,
    cwd: PathBuf,
    members: Vec<Member>,
    /// The last post the coordinator has seen.
    seen: usize,
}

impl Running {
    fn roster(&self) -> String {
        if self.members.is_empty() {
            return "No members yet.".into();
        }
        let posts = self.board.posts();
        self.members
            .iter()
            .map(|m| {
                let state = *m.state.lock().unwrap();
                let last = posts.iter().rev().find(|p| p.from == m.name).map(|p| format!("#{}", p.n)).unwrap_or_else(|| "–".into());
                let doing = m.doing.lock().unwrap().clone();
                let tokens = *m.tokens.lock().unwrap();
                format!(
                    "@{:<14} {:<8} {}  last post {last}  {} tokens  {}{}",
                    m.name,
                    state.name(),
                    m.models[*m.on.lock().unwrap()],
                    tokens,
                    m.mode,
                    if state == State::Working && !doing.is_empty() { format!("  · {doing}") } else { String::new() }
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn idle(&self) -> bool {
        self.members.iter().all(|m| *m.state.lock().unwrap() != State::Working)
    }
}

#[derive(Default)]
struct Shared {
    running: Option<Running>,
}

pub struct Swarm {
    model: String,
    shared: Arc<Mutex<Shared>>,
    /// Set in a worker's own bla: the board and who it is.
    member: Option<(Board, String)>,
}

impl Swarm {
    pub fn new(model: &str) -> Swarm {
        let member = match (std::env::var_os(ENV_BOARD), std::env::var(ENV_NAME)) {
            (Some(dir), Ok(name)) => Some((Board { dir: PathBuf::from(dir) }, name)),
            _ => None,
        };
        Swarm { model: model.into(), shared: Arc::default(), member }
    }
}

fn text_arg<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args[key].as_str().map(str::trim).filter(|s| !s.is_empty())
}

fn to_arg(args: &Value) -> Vec<String> {
    match &args["to"] {
        Value::Array(a) => a.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
        Value::String(s) => s.split([' ', ',']).filter(|s| !s.is_empty()).map(String::from).collect(),
        _ => Vec::new(),
    }
}

fn to_schema() -> Value {
    json!({"type": "array", "items": {"type": "string"}, "description": "Names without @: a member, a group (fix for fix-1…), coordinator, or all"})
}

// ---------- The coordinator's tools ----------

struct Start(Arc<Mutex<Shared>>);

impl Tool for Start {
    fn name(&self) -> &str {
        "swarm_start"
    }
    fn description(&self) -> &str {
        "Start a swarm: a shared board for named workers. The conversation becomes its coordinator."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"title": {"type": "string", "description": "A few words naming the work"}}, "required": ["title"]})
    }
    fn kind(&self, _: &Value) -> Kind {
        Kind::Internal
    }
    fn summary(&self, args: &Value) -> String {
        text_arg(args, "title").unwrap_or_default().into()
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let title = text_arg(args, "title").unwrap_or("Swarm");
        let mut shared = self.0.lock().unwrap();
        if let Some(r) = &shared.running {
            if r.members.iter().any(|m| *m.state.lock().unwrap() != State::Killed) {
                return ToolOutput::err(format!("A swarm is running already: {}. Remove its members first.", r.board.title()));
            }
        }
        let (y, mo, d, h, mi, s) = crate::util::utc_now();
        let id = format!("{y:04}{mo:02}{d:02}-{h:02}{mi:02}{s:02}-{}", crate::util::random_hex(4));
        let dir = crate::util::bla_home().join("swarms").join(&id);
        if let Err(e) = std::fs::create_dir_all(&dir).and_then(|_| std::fs::write(dir.join("title"), title)) {
            return ToolOutput::err(format!("can't make the board: {e}"));
        }
        let board = Board { dir };
        shared.running = Some(Running { id: id.clone(), board, cwd: ctx.cwd.to_path_buf(), members: Vec::new(), seen: 0 });
        ToolOutput::ok(format!("Swarm \"{title}\" started ({id}). Add members with swarm_add (at most {MAX_MEMBERS}). The user can watch with /swarm board, or side by side with `bla swarm` in another terminal."))
    }
}

struct Add {
    shared: Arc<Mutex<Shared>>,
    model: String,
}

fn mode_of(args: &Value) -> &str {
    match args["mode"].as_str() {
        Some("plan") => "plan",
        Some("yolo") => "yolo",
        _ => "accept-edits",
    }
}

impl Tool for Add {
    fn name(&self) -> &str {
        "swarm_add"
    }
    fn description(&self) -> &str {
        "Add a named member to the swarm with its public brief, posted on the board. It starts at once with a clean context. \
         mode: plan (read-only), accept-edits (edits files; the default), yolo (also runs commands: tests, builds; verifiers need it)."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "name": {"type": "string", "description": "Lowercase, e.g. parser, api-tests, verifier, fix-1"},
            "brief": {"type": "string", "description": "What it owns, what it must not touch, what done means"},
            "mode": {"type": "string", "enum": ["plan", "accept-edits", "yolo"]},
            "model": {"type": "string", "description": "By its job: alias-code (edits code), alias-fast (quick read-only), alias-large (review, verifiers), alias-huge (hardest pieces), deepseek-v4.1-flash-at-hzdr (long reading, docs). Default by role"},
            "worktree": {"type": "boolean", "description": "Its own git worktree and branch, for members that edit or build at the same time"}
        }, "required": ["name", "brief"]})
    }
    fn kind(&self, args: &Value) -> Kind {
        match mode_of(args) {
            "plan" => Kind::Read,
            "yolo" => Kind::Exec,
            _ => Kind::Write,
        }
    }
    fn subject(&self, args: &Value) -> Option<String> {
        Some(format!("@{} ({})", args["name"].as_str().unwrap_or_default(), mode_of(args)))
    }
    fn run(&self, args: &Value, _ctx: &ToolCtx) -> ToolOutput {
        let Some(name) = text_arg(args, "name").map(|n| n.trim_start_matches('@').to_lowercase()) else { return ToolOutput::err("Give a name.") };
        let Some(brief) = text_arg(args, "brief") else { return ToolOutput::err("Give a brief.") };
        if !valid_name(&name) {
            return ToolOutput::err("Names are lowercase letters, digits and dashes, up to 32, and not all, coordinator or user.");
        }
        let mut shared = self.shared.lock().unwrap();
        let Some(r) = shared.running.as_mut() else { return ToolOutput::err("Start the swarm first with swarm_start.") };
        if r.members.iter().filter(|m| *m.state.lock().unwrap() != State::Killed).count() >= MAX_MEMBERS {
            return ToolOutput::err(format!("A swarm has at most {MAX_MEMBERS} members at a time. Remove one that is done first."));
        }
        if r.members.iter().any(|m| m.name == name) {
            return ToolOutput::err(format!("@{name} exists already (a removed member can't come back; pick another name)."));
        }
        let mode = mode_of(args).to_string();
        // On another endpoint the aliases don't exist: there the coordinator's own model is the default.
        let blablador = MODELS.iter().any(|(m, _)| *m == self.model) || self.model.starts_with("alias-");
        let asked = text_arg(args, "model");
        if let Some(m) = asked.filter(|m| !blablador_models::is_chat_capable(m)) {
            return ToolOutput::err(format!("{m} can't chat."));
        }
        let models = if blablador { models_for(&name, &mode, asked) } else { vec![asked.unwrap_or(&self.model).to_string()] };
        let worktree = args["worktree"].as_bool().unwrap_or(false);
        let folder = if worktree {
            match add_worktree(&r.cwd, &r.board.dir, &r.id, &name) {
                Ok(f) => f,
                Err(e) => return ToolOutput::err(e),
            }
        } else {
            r.cwd.clone()
        };
        if let Err(e) = r.board.post(COORDINATOR, std::slice::from_ref(&name), &format!("Brief for @{name}: {brief}"), false) {
            return ToolOutput::err(e);
        }
        let member = Member {
            name: name.clone(),
            models,
            on: Arc::default(),
            mode,
            folder: folder.clone(),
            worktree,
            state: Arc::new(Mutex::new(State::Waiting)),
            kill: Arc::new(AtomicBool::new(false)),
            doing: Arc::default(),
            tokens: Arc::default(),
        };
        spawn_worker(&member, r.board.clone());
        r.members.push(member);
        let place = if worktree { format!(" in its worktree {} (branch swarm/{}/{name})", folder.display(), r.id) } else { String::new() };
        ToolOutput::ok(format!("@{name} added and briefed{place}. It is working; swarm_wait for its posts."))
    }
}

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git").arg("-C").arg(dir).args(args).output().map_err(|e| format!("git: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!("git {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()))
    }
}

fn add_worktree(cwd: &Path, board: &Path, id: &str, name: &str) -> Result<PathBuf, String> {
    let root = PathBuf::from(git(cwd, &["rev-parse", "--show-toplevel"]).map_err(|_| "Worktrees need a git repository.".to_string())?.trim());
    let folder = board.join("worktrees").join(name);
    let branch = format!("swarm/{id}/{name}");
    git(&root, &["worktree", "add", "-b", &branch, &folder.to_string_lossy(), "HEAD"])?;
    // The same place inside the repository as the coordinator.
    Ok(cwd.strip_prefix(&root).map(|rel| folder.join(rel)).unwrap_or(folder))
}

/// The thread that sleeps on the board for one member and runs it when a post mentions it.
fn spawn_worker(m: &Member, board: Board) {
    let (name, models, on, mode, folder) = (m.name.clone(), m.models.clone(), m.on.clone(), m.mode.clone(), m.folder.clone());
    let (state, kill, doing, tokens) = (m.state.clone(), m.kill.clone(), m.doing.clone(), m.tokens.clone());
    board.set_state(&name, "waiting", &models[0], "");
    std::thread::spawn(move || {
        let mut seen = 0;
        let mut session: Option<String> = None;
        while !kill.load(Ordering::Relaxed) {
            let posts = board.posts();
            let new: Vec<&Post> = posts.iter().filter(|p| p.n > seen && p.for_member(&name)).collect();
            if new.is_empty() {
                std::thread::sleep(Duration::from_millis(500));
                continue;
            }
            seen = posts.len();
            *state.lock().unwrap() = State::Working;
            board.set_state(&name, "working", &models[*on.lock().unwrap()], "");
            let mut prompt = String::from("New posts on the board for you:\n");
            for p in &new {
                prompt.push_str(&p.line());
                prompt.push('\n');
            }
            prompt.push_str("\nDo what they ask; post to the board when you have something to report.");
            let before = posts.iter().filter(|p| p.from == name).count();
            // The model it is on, then the next ones when it fails; the session goes on with whichever answers, and
            // the member stays on that one.
            let mut result = Err(String::new());
            let mut failures = Vec::new();
            while !kill.load(Ordering::Relaxed) {
                let i = *on.lock().unwrap();
                result = run_member(&name, &models[i], &mode, &folder, &board, &mut session, &prompt, &kill, &doing, &tokens);
                match &result {
                    Err(e) if !kill.load(Ordering::Relaxed) && failures.len() + 1 < models.len() => {
                        failures.push(format!("{}: {e}", models[i]));
                        *on.lock().unwrap() = (i + 1) % models.len();
                    }
                    _ => break,
                }
            }
            if let (Ok(_), false) = (&result, failures.is_empty()) {
                let _ = board.post(&name, &[COORDINATOR.into()], &format!("Switched to {} after {}.", models[*on.lock().unwrap()], failures.join("; ")), false);
            }
            let posted = board.posts().iter().filter(|p| p.from == name).count() > before;
            match result {
                // It said something but put nothing on the board: that is its report.
                Ok(answer) if !posted && !answer.trim().is_empty() => {
                    let _ = board.post(&name, &[COORDINATOR.into()], answer.trim(), false);
                }
                Ok(_) => {}
                Err(e) if kill.load(Ordering::Relaxed) => {
                    let _ = e;
                }
                // Out of quota, the model away: say so once and wait for the next post, without trying again.
                Err(e) => {
                    let _ = board.post(&name, &[COORDINATOR.into()], &format!("I stopped: {e}. I'll go on when someone posts to me."), false);
                    seen = board.posts().len();
                }
            }
            doing.lock().unwrap().clear();
            if !kill.load(Ordering::Relaxed) {
                *state.lock().unwrap() = State::Waiting;
                board.set_state(&name, "waiting", &models[*on.lock().unwrap()], "");
            }
        }
        *state.lock().unwrap() = State::Killed;
        board.set_state(&name, "killed", &models[*on.lock().unwrap()], "");
    });
}

#[allow(clippy::too_many_arguments)]
fn run_member(
    name: &str,
    model: &str,
    mode: &str,
    folder: &Path,
    board: &Board,
    session: &mut Option<String>,
    prompt: &str,
    kill: &AtomicBool,
    doing: &Mutex<String>,
    tokens: &Mutex<u64>,
) -> Result<String, String> {
    let me = std::env::current_exe().map_err(|_| "can't find bla's own program".to_string())?;
    let mut command = Command::new(me);
    command.args(["--json", "--quiet", "--mode", mode, "--no-plugin", "agents", "-m", model, "-s", MEMBER_GUIDE]);
    if let Some(id) = session.as_deref() {
        command.args(["-r", id]);
    }
    command
        .arg("--")
        .arg(prompt)
        .current_dir(folder)
        .env(ENV_BOARD, &board.dir)
        .env(ENV_NAME, name)
        .env("BLA_NO_UPDATE_CHECK", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|e| format!("could not start: {e}"))?;
    let stdout = child.stdout.take();
    let outcome = Arc::new(Mutex::new((super::agents::Outcome::default(), String::new(), None::<String>)));
    let shared = outcome.clone();
    let (doing_line, token_count) = (Arc::new(Mutex::new(String::new())), Arc::new(Mutex::new(0u64)));
    let (d2, t2) = (doing_line.clone(), token_count.clone());
    let mut log = std::fs::create_dir_all(board.dir.join("logs"))
        .and_then(|_| std::fs::OpenOptions::new().create(true).append(true).open(board.log(name)))
        .ok();
    if let Some(f) = log.as_mut() {
        let _ = writeln!(f, "{}", json!({"type": "wake", "model": model, "prompt": prompt}));
    }
    let reader = std::thread::spawn(move || {
        if let Some(out) = stdout {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if let Some(f) = log.as_mut() {
                    let _ = writeln!(f, "{line}");
                }
                let v: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                match v["type"].as_str() {
                    Some("session") => shared.lock().unwrap().2 = v["id"].as_str().map(String::from),
                    Some("tool_start") => *d2.lock().unwrap() = format!("{} {}", v["name"].as_str().unwrap_or(""), v["summary"].as_str().unwrap_or("")),
                    Some("usage") => *t2.lock().unwrap() += v["input"].as_u64().unwrap_or(0) + v["output"].as_u64().unwrap_or(0),
                    _ => {}
                }
                let mut g = shared.lock().unwrap();
                let (o, reply, _) = &mut *g;
                o.take(&line, reply);
            }
        }
    });
    let stderr = child.stderr.take();
    let errors = std::thread::spawn(move || {
        let mut text = String::new();
        if let Some(mut e) = stderr {
            let _ = std::io::Read::read_to_string(&mut e, &mut text);
        }
        text
    });
    let start = Instant::now();
    let base = *tokens.lock().unwrap();
    let stopped = loop {
        if let Ok(Some(_)) = child.try_wait() {
            break None;
        }
        let now_doing = doing_line.lock().unwrap().clone();
        if *doing.lock().unwrap() != now_doing {
            board.set_state(name, "working", model, &now_doing);
        }
        *doing.lock().unwrap() = now_doing;
        *tokens.lock().unwrap() = base + *token_count.lock().unwrap();
        if kill.load(Ordering::Relaxed) || start.elapsed() > RUN_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            break Some(if kill.load(Ordering::Relaxed) { "removed" } else { "stopped after an hour" });
        }
        std::thread::sleep(Duration::from_millis(100));
    };
    let _ = reader.join();
    let stderr = errors.join().unwrap_or_default();
    *tokens.lock().unwrap() = base + *token_count.lock().unwrap();
    let (mut o, reply, id) = std::mem::take(&mut *outcome.lock().unwrap());
    if id.is_some() {
        *session = id;
    }
    if !reply.trim().is_empty() {
        o.answer = reply;
    }
    match stopped {
        Some(why) => Err(why.into()),
        None if o.answer.trim().is_empty() && !o.errors.is_empty() => Err(o.errors.last().cloned().unwrap_or_default()),
        None if o.answer.trim().is_empty() && o.tools == 0 => Err(crate::util::clip(stderr.trim(), 300).to_string()),
        None => Ok(o.answer),
    }
}

struct PostTool {
    shared: Arc<Mutex<Shared>>,
}

impl Tool for PostTool {
    fn name(&self) -> &str {
        "swarm_post"
    }
    fn description(&self) -> &str {
        "Post to the swarm's board, mentioning who it is for. Mentioned members wake up and act on it."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"to": to_schema(), "text": {"type": "string"}}, "required": ["to", "text"]})
    }
    fn kind(&self, _: &Value) -> Kind {
        Kind::Internal
    }
    fn summary(&self, args: &Value) -> String {
        format!("→ {}", to_arg(args).join(" "))
    }
    fn run(&self, args: &Value, _: &ToolCtx) -> ToolOutput {
        let shared = self.shared.lock().unwrap();
        let Some(r) = shared.running.as_ref() else { return ToolOutput::err("No swarm. Start one with swarm_start.") };
        let Some(text) = text_arg(args, "text") else { return ToolOutput::err("Write something.") };
        match r.board.post(COORDINATOR, &to_arg(args), text, false) {
            Ok(n) => ToolOutput::ok(format!("Posted #{n}.")),
            Err(e) => ToolOutput::err(e),
        }
    }
}

struct Wait {
    shared: Arc<Mutex<Shared>>,
}

impl Tool for Wait {
    fn name(&self) -> &str {
        "swarm_wait"
    }
    fn description(&self) -> &str {
        "Wait for posts to the coordinator (or @all) and return them with the roster. Also returns when every member is \
         idle and nothing new is for you (the work has stalled), or after timeout_seconds."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"timeout_seconds": {"type": "integer", "description": "Default 900"}}})
    }
    fn kind(&self, _: &Value) -> Kind {
        Kind::Read
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let timeout = Duration::from_secs(args["timeout_seconds"].as_u64().unwrap_or(900).clamp(5, 3 * 3600));
        let start = Instant::now();
        // A member that has just been posted to needs a moment to wake before "everyone is idle" means anything.
        let grace = Duration::from_secs(3);
        loop {
            {
                let mut shared = self.shared.lock().unwrap();
                let Some(r) = shared.running.as_mut() else { return ToolOutput::err("No swarm.") };
                let posts = r.board.posts();
                let new: Vec<&Post> = posts.iter().filter(|p| p.n > r.seen && p.for_member(COORDINATOR)).collect();
                let idle = start.elapsed() > grace && r.idle();
                if !new.is_empty() || idle || start.elapsed() > timeout || ctx.cancel.load(Ordering::Relaxed) {
                    // Everything since last time, so it also sees what members told each other.
                    let since: Vec<String> = posts.iter().filter(|p| p.n > r.seen && !p.private).map(|p| p.line()).collect();
                    r.seen = posts.len();
                    let why = if !new.is_empty() {
                        "New posts for you."
                    } else if idle {
                        "Every member is idle and nothing new is for you: if the work isn't done, it has stalled. Post to restart it, or finish."
                    } else if ctx.cancel.load(Ordering::Relaxed) {
                        "Stopped by the user."
                    } else {
                        "Nothing for you yet (timed out); members are still working."
                    };
                    let body = if since.is_empty() { "(no new posts)".to_string() } else { since.join("\n") };
                    return ToolOutput::ok(format!("{why}\n\n{body}\n\nRoster:\n{}", r.roster()));
                }
            }
            std::thread::sleep(Duration::from_millis(500));
        }
    }
}

struct Status {
    shared: Arc<Mutex<Shared>>,
}

impl Tool for Status {
    fn name(&self) -> &str {
        "swarm_status"
    }
    fn description(&self) -> &str {
        "The swarm's roster (who is working, waiting or killed, and on what) and its latest posts, without waiting."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {}})
    }
    fn kind(&self, _: &Value) -> Kind {
        Kind::Read
    }
    fn run(&self, _: &Value, _: &ToolCtx) -> ToolOutput {
        let shared = self.shared.lock().unwrap();
        match shared.running.as_ref() {
            Some(r) => ToolOutput::ok(board_text(r, 20)),
            None => ToolOutput::err("No swarm."),
        }
    }
}

struct Remove {
    shared: Arc<Mutex<Shared>>,
}

impl Tool for Remove {
    fn name(&self) -> &str {
        "swarm_remove"
    }
    fn description(&self) -> &str {
        "Remove a member for good (it can't be revived). A member with a worktree must have committed its work first; its \
         branch is kept, its worktree deleted. discard: true throws uncommitted changes away."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"name": {"type": "string"}, "discard": {"type": "boolean"}}, "required": ["name"]})
    }
    fn kind(&self, _: &Value) -> Kind {
        Kind::Internal
    }
    fn summary(&self, args: &Value) -> String {
        format!("@{}", args["name"].as_str().unwrap_or_default())
    }
    fn run(&self, args: &Value, _: &ToolCtx) -> ToolOutput {
        let name = args["name"].as_str().unwrap_or_default().trim_start_matches('@');
        let shared = self.shared.lock().unwrap();
        let Some(r) = shared.running.as_ref() else { return ToolOutput::err("No swarm.") };
        let Some(m) = r.members.iter().find(|m| m.name == name) else { return ToolOutput::err(format!("No member @{name}.")) };
        remove(m, args["discard"].as_bool().unwrap_or(false), &r.id).map(ToolOutput::ok).unwrap_or_else(ToolOutput::err)
    }
}

fn remove(m: &Member, discard: bool, id: &str) -> Result<String, String> {
    if m.worktree {
        let dirty = git(&m.folder, &["status", "--porcelain"]).map(|s| !s.trim().is_empty()).unwrap_or(false);
        if dirty && !discard {
            return Err(format!("@{} has uncommitted changes in {}. Have it commit, or pass discard: true.", m.name, m.folder.display()));
        }
    }
    m.kill.store(true, Ordering::Relaxed);
    let deadline = Instant::now() + Duration::from_secs(5);
    while *m.state.lock().unwrap() != State::Killed && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    let mut note = String::new();
    if m.worktree {
        let root = git(&m.folder, &["rev-parse", "--show-toplevel"]).map(|s| s.trim().to_string()).unwrap_or_default();
        let common = git(&m.folder, &["rev-parse", "--git-common-dir"]).map(|s| s.trim().to_string()).unwrap_or_default();
        let main = Path::new(&common).parent().map(Path::to_path_buf).unwrap_or_default();
        match git(&main, &["worktree", "remove", "--force", &root]) {
            Ok(_) => note = format!(" Its worktree is gone; its work is on the branch swarm/{id}/{}.", m.name),
            Err(e) => note = format!(" Its worktree stays: {e}"),
        }
    }
    Ok(format!("@{} removed.{note}", m.name))
}

fn board_text(r: &Running, last: usize) -> String {
    let posts: Vec<Post> = r.board.posts().into_iter().filter(|p| !p.private).collect();
    let skip = posts.len().saturating_sub(last);
    let lines: Vec<String> = posts[skip..].iter().map(|p| crate::util::clip(&p.line(), 600).to_string()).collect();
    format!(
        "Swarm: {} ({} posts) · {}\n\nRoster:\n{}\n\n{}{}",
        r.board.title(),
        posts.len(),
        r.board.dir.display(),
        r.roster(),
        if skip > 0 { format!("… {skip} earlier posts\n") } else { String::new() },
        if lines.is_empty() { "No posts yet.".into() } else { lines.join("\n") }
    )
}

// ---------- A member's tools ----------

struct MemberPost {
    board: Board,
    name: String,
}

impl Tool for MemberPost {
    fn name(&self) -> &str {
        "board_post"
    }
    fn description(&self) -> &str {
        "Post to the swarm's shared board, mentioning who it is for: coordinator, another member, a group, or all."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"to": to_schema(), "text": {"type": "string"}}, "required": ["to", "text"]})
    }
    fn kind(&self, _: &Value) -> Kind {
        Kind::Internal
    }
    fn summary(&self, args: &Value) -> String {
        format!("→ {}", to_arg(args).join(" "))
    }
    fn run(&self, args: &Value, _: &ToolCtx) -> ToolOutput {
        let Some(text) = text_arg(args, "text") else { return ToolOutput::err("Write something.") };
        match self.board.post(&self.name, &to_arg(args), text, false) {
            Ok(n) => ToolOutput::ok(format!("Posted #{n}.")),
            Err(e) => ToolOutput::err(e),
        }
    }
}

struct MemberRead {
    board: Board,
    name: String,
}

impl Tool for MemberRead {
    fn name(&self) -> &str {
        "board_read"
    }
    fn description(&self) -> &str {
        "Read the swarm's board: the latest posts, everyone's, or only those since a post number."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"since": {"type": "integer"}, "mine": {"type": "boolean", "description": "Only posts for me"}}})
    }
    fn kind(&self, _: &Value) -> Kind {
        Kind::Read
    }
    fn run(&self, args: &Value, _: &ToolCtx) -> ToolOutput {
        let since = args["since"].as_u64().unwrap_or(0) as usize;
        let mine = args["mine"].as_bool().unwrap_or(false);
        let posts: Vec<String> = self
            .board
            .posts()
            .into_iter()
            .filter(|p| p.n > since && (!p.private || p.to.contains(&self.name)) && (!mine || p.for_member(&self.name)))
            .map(|p| p.line())
            .collect();
        let skip = posts.len().saturating_sub(60);
        ToolOutput::ok(if posts.is_empty() { "No posts.".into() } else { posts[skip..].join("\n") })
    }
}

impl Plugin for Swarm {
    fn name(&self) -> &str {
        "swarm"
    }
    fn description(&self) -> &str {
        "/swarm TASK: named workers and a verifier split a task and talk on one shared board; /swarm board"
    }
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        if let Some((board, name)) = &self.member {
            return vec![
                Arc::new(MemberPost { board: board.clone(), name: name.clone() }),
                Arc::new(MemberRead { board: board.clone(), name: name.clone() }),
            ];
        }
        let s = &self.shared;
        vec![
            Arc::new(Start(s.clone())),
            Arc::new(Add { shared: s.clone(), model: self.model.clone() }),
            Arc::new(PostTool { shared: s.clone() }),
            Arc::new(Wait { shared: s.clone() }),
            Arc::new(Status { shared: s.clone() }),
            Arc::new(Remove { shared: s.clone() }),
        ]
    }
    fn commands(&self) -> Vec<CommandSpec> {
        if self.member.is_some() {
            return Vec::new();
        }
        vec![CommandSpec {
            name: "swarm".into(),
            help: "TASK: a team of named workers on one board; /swarm board, /swarm tell NAME TEXT, /swarm stop".into(),
        }]
    }
    fn system_prompt(&self, _: &Session, sections: &mut Vec<String>) {
        match &self.member {
            Some((_, name)) => sections.push(format!("{MEMBER_GUIDE}\nYour name on the board is @{name}.")),
            None => sections.push(
                "When the user starts a swarm (/swarm), you coordinate named workers on a shared board with the swarm_* tools."
                    .into(),
            ),
        }
    }
    fn command(&self, _: &Ctx, name: &str, args: &str, _: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        if name != "swarm" || self.member.is_some() {
            return None;
        }
        let shared = self.shared.lock().unwrap();
        let (word, rest) = args.split_once(' ').map(|(a, b)| (a, b.trim())).unwrap_or((args, ""));
        Some(match word {
            "" => Err("/swarm TASK starts one; /swarm board shows the board.".into()),
            "board" | "status" => match shared.running.as_ref() {
                Some(r) => Ok(CommandResult::Output(board_text(r, 40))),
                None => Ok(CommandResult::Output("No swarm in this conversation.".into())),
            },
            "tell" => {
                let (who, text) = rest.split_once(' ').unwrap_or((rest, ""));
                let who = who.trim_start_matches('@');
                match shared.running.as_ref() {
                    None => Err("No swarm.".into()),
                    Some(r) if !r.members.iter().any(|m| m.name == who) => Err(format!("No member @{who}.")),
                    Some(_) if text.trim().is_empty() => Err("/swarm tell NAME TEXT".into()),
                    Some(r) => r
                        .board
                        .post("user", &[who.to_string()], text.trim(), true)
                        .map(|_| CommandResult::Output(format!("Told @{who} (privately)."))),
                }
            }
            "stop" => match shared.running.as_ref() {
                None => Err("No swarm.".into()),
                Some(r) => {
                    r.members.iter().for_each(|m| m.kill.store(true, Ordering::Relaxed));
                    Ok(CommandResult::Output("Every member is stopping. Their worktrees and branches stay.".into()))
                }
            },
            _ => Ok(CommandResult::Prompt(format!("{GUIDE}\n\n{}\n\nThe task: {args}", models_guide()))),
        })
    }
    fn session_end(&self, _: &Session) {
        if let Some(r) = self.shared.lock().unwrap().running.as_ref() {
            r.members.iter().for_each(|m| m.kill.store(true, Ordering::Relaxed));
            let deadline = Instant::now() + Duration::from_secs(3);
            while r.members.iter().any(|m| *m.state.lock().unwrap() != State::Killed) && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mentions_reach_names_groups_and_all() {
        let p = |from: &str, to: &[&str]| Post { n: 1, from: from.into(), to: to.iter().map(|s| s.to_string()).collect(), text: String::new(), time: 0, private: false };
        assert!(p(COORDINATOR, &["parser"]).for_member("parser"));
        assert!(p(COORDINATOR, &["@fix"]).for_member("fix-2"));
        assert!(!p(COORDINATOR, &["fix"]).for_member("fixer"));
        assert!(p("verifier", &["all"]).for_member(COORDINATOR));
        assert!(!p("parser", &["all"]).for_member("parser"), "not its own post");
        assert_eq!(group("api-tests"), None);
        assert_eq!(group("verifier-1"), Some("verifier"));
        let d = blablador_models::DEFAULT_MODEL;
        assert_eq!(models_for("verifier-2", "yolo", None), [d, "alias-large", "alias-huge", "alias-code", "alias-fast"]);
        assert_eq!(models_for("scout", "plan", None)[..2], [d, "alias-fast"]);
        assert_eq!(models_for("parser", "accept-edits", Some("alias-huge")), ["alias-huge", d, "alias-code", "alias-large", "alias-fast"]);
        assert!(!valid_name("All") && !valid_name("coordinator") && valid_name("fix-1"));
    }

    #[test]
    fn the_board_numbers_posts_in_order() {
        let dir = std::env::temp_dir().join(format!("bla-swarm-{}", crate::util::random_hex(6)));
        std::fs::create_dir_all(&dir).unwrap();
        let board = Board { dir: dir.clone() };
        assert_eq!(board.post(COORDINATOR, &["@parser".into()], "Brief", false), Ok(1));
        assert_eq!(board.post("parser", &["coordinator".into(), "verifier".into()], "Done", false), Ok(2));
        assert!(board.post("parser", &[], "nobody", false).is_err());
        let posts = board.posts();
        assert_eq!(posts[1].n, 2);
        assert_eq!(posts[1].line(), "#2 @parser → @coordinator @verifier: Done");
        assert!(posts[1].for_member("verifier") && !posts[0].for_member(COORDINATOR));
        let _ = std::fs::remove_dir_all(dir);
    }
}
