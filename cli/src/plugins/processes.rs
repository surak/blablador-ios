//! Background processes: dev servers, watchers and long builds that keep running while the agent works.
//! `bash_background` starts one (the same shell, without the API key, in its own process group), `bash_output`
//! reads what it wrote since last time, `bash_kill` stops it. Output is kept in a ring of the last 200 KB.
//! Everything still running is stopped when the session ends.

use crate::plugin::{CommandResult, CommandSpec, Ctx, Kind, Plugin, Session, Tool, ToolCtx, ToolOutput};
use crate::util;
use serde_json::{json, Value};
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Instant;

const KEEP: usize = 200_000;
/// Most returned by one bash_output call.
const SHOW: usize = 30_000;

#[derive(Default)]
struct Buffer {
    data: Vec<u8>,
    /// Bytes dropped from the front so far, so readers know what they missed.
    dropped: usize,
}

impl Buffer {
    fn push(&mut self, bytes: &[u8]) {
        self.data.extend_from_slice(bytes);
        if self.data.len() > KEEP {
            let cut = self.data.len() - KEEP;
            self.data.drain(..cut);
            self.dropped += cut;
        }
    }

    fn total(&self) -> usize {
        self.dropped + self.data.len()
    }
}

struct Job {
    id: usize,
    name: String,
    command: String,
    child: Child,
    output: Arc<Mutex<Buffer>>,
    /// Absolute position read up to.
    read: usize,
    started: Instant,
    code: Option<Option<i32>>,
}

impl Job {
    fn status(&mut self) -> String {
        if self.code.is_none() {
            if let Ok(Some(s)) = self.child.try_wait() {
                self.code = Some(s.code());
            }
        }
        match self.code {
            None => format!("running for {} s", self.started.elapsed().as_secs()),
            Some(Some(c)) => format!("exited with code {c}"),
            Some(None) => "stopped".into(),
        }
    }

    fn kill(&mut self) {
        if self.code.is_none() {
            util::kill_group(self.child.id());
            let _ = self.child.kill();
            let _ = self.child.wait();
            self.code = Some(None);
        }
    }
}

#[derive(Default)]
pub struct Jobs {
    list: Mutex<Vec<Job>>,
}

impl Jobs {
    fn start(&self, command: &str, name: Option<&str>, cwd: &std::path::Path) -> Result<usize, String> {
        let (shell, flag) = util::shell();
        let mut cmd = Command::new(shell);
        cmd.arg(flag).arg(command).current_dir(cwd).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        for name in util::SECRET_ENV {
            cmd.env_remove(name);
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            cmd.process_group(0);
        }
        let mut child = cmd.spawn().map_err(|e| format!("could not start the shell: {e}"))?;
        let output = Arc::new(Mutex::new(Buffer::default()));
        for pipe in [child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>), child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>)].into_iter().flatten() {
            let out = output.clone();
            std::thread::spawn(move || {
                let mut pipe = pipe;
                let mut chunk = [0u8; 8192];
                while let Ok(n) = pipe.read(&mut chunk) {
                    if n == 0 {
                        break;
                    }
                    out.lock().unwrap().push(&chunk[..n]);
                }
            });
        }
        let mut list = self.list.lock().unwrap();
        let id = list.iter().map(|j| j.id).max().unwrap_or(0) + 1;
        let name = name.filter(|n| !n.trim().is_empty()).map(String::from).unwrap_or_else(|| util::clip(command, 40).to_string());
        list.push(Job { id, name, command: command.to_string(), child, output, read: 0, started: Instant::now(), code: None });
        Ok(id)
    }

    fn output(&self, id: usize, since_last: bool) -> Result<String, String> {
        let mut list = self.list.lock().unwrap();
        let job = list.iter_mut().find(|j| j.id == id).ok_or(format!("There is no background job {id}; /jobs lists them."))?;
        let status = job.status();
        let buffer = job.output.lock().unwrap();
        let from = if since_last { job.read.max(buffer.dropped) } else { buffer.dropped };
        let missed = if since_last && job.read < buffer.dropped { buffer.dropped - job.read } else { 0 };
        let mut text = String::from_utf8_lossy(&buffer.data[from - buffer.dropped..]).to_string();
        let total = buffer.total();
        drop(buffer);
        job.read = total;
        let mut cut = String::new();
        if text.len() > SHOW {
            let mut start = text.len() - SHOW;
            while !text.is_char_boundary(start) {
                start += 1;
            }
            text = text[start..].to_string();
            cut = "[earlier output cut]\n".into();
        }
        if missed > 0 {
            cut = format!("[{missed} bytes were dropped before you read them]\n{cut}");
        }
        let body = if text.trim().is_empty() { "(no new output)".to_string() } else { text.trim_end().to_string() };
        Ok(format!("Job {id} ({}) {status}.\n{cut}{body}", job.name))
    }

    fn kill(&self, id: usize) -> Result<String, String> {
        let mut list = self.list.lock().unwrap();
        let job = list.iter_mut().find(|j| j.id == id).ok_or(format!("There is no background job {id}."))?;
        job.kill();
        Ok(format!("Stopped job {id} ({}).", job.name))
    }

    fn kill_all(&self) {
        for job in self.list.lock().unwrap().iter_mut() {
            job.kill();
        }
    }

    fn listing(&self) -> String {
        let mut list = self.list.lock().unwrap();
        if list.is_empty() {
            return "No background jobs.".into();
        }
        list.iter_mut()
            .map(|j| {
                let status = j.status();
                format!("{}  {}  {status}  ({})", j.id, j.name, util::clip(&j.command, 100))
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

impl Drop for Jobs {
    fn drop(&mut self) {
        self.kill_all();
    }
}

fn id_arg(args: &Value) -> Option<usize> {
    args["id"].as_u64().map(|i| i as usize).or_else(|| args["id"].as_str().and_then(|s| s.trim().parse().ok()))
}

struct Start(Arc<Jobs>);
struct Output(Arc<Jobs>);
struct Kill(Arc<Jobs>);

impl Tool for Start {
    fn name(&self) -> &str {
        "bash_background"
    }
    fn description(&self) -> &str {
        "Start a long-running shell command in the background (a dev server, a watcher, a long build or test run) and get its job id \
         at once. Read what it prints with bash_output, stop it with bash_kill. For commands that finish quickly, use bash."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "command": {"type": "string"},
            "name": {"type": "string", "description": "A short name for /jobs"}
        }, "required": ["command"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Exec
    }
    fn subject(&self, args: &Value) -> Option<String> {
        args["command"].as_str().map(String::from)
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(command) = args["command"].as_str().filter(|c| !c.trim().is_empty()) else { return ToolOutput::err("Give a command.") };
        match self.0.start(command, args["name"].as_str(), ctx.cwd) {
            Ok(id) => ToolOutput::ok(format!("Started job {id}. Read its output with bash_output (id {id}).")),
            Err(e) => ToolOutput::err(e),
        }
    }
}

impl Tool for Output {
    fn name(&self) -> &str {
        "bash_output"
    }
    fn description(&self) -> &str {
        "Read a background job's output: by default only what is new since the last read; with since_last false, the last 200 KB. Also says whether it is still running."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "id": {"type": "integer"},
            "since_last": {"type": "boolean"}
        }, "required": ["id"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Read
    }
    fn run(&self, args: &Value, _ctx: &ToolCtx) -> ToolOutput {
        let Some(id) = id_arg(args) else { return ToolOutput::err("Give the job's id.") };
        match self.0.output(id, args["since_last"].as_bool().unwrap_or(true)) {
            Ok(t) => ToolOutput::ok(t),
            Err(e) => ToolOutput::err(e),
        }
    }
}

impl Tool for Kill {
    fn name(&self) -> &str {
        "bash_kill"
    }
    fn description(&self) -> &str {
        "Stop a background job and everything it started."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Exec
    }
    fn subject(&self, args: &Value) -> Option<String> {
        id_arg(args).map(|id| format!("kill job {id}"))
    }
    fn run(&self, args: &Value, _ctx: &ToolCtx) -> ToolOutput {
        let Some(id) = id_arg(args) else { return ToolOutput::err("Give the job's id.") };
        match self.0.kill(id) {
            Ok(t) => ToolOutput::ok(t),
            Err(e) => ToolOutput::err(e),
        }
    }
}

pub struct Processes {
    jobs: Arc<Jobs>,
}

impl Processes {
    pub fn new() -> Processes {
        Processes { jobs: Arc::new(Jobs::default()) }
    }
}

impl Plugin for Processes {
    fn name(&self) -> &str {
        "processes"
    }
    fn description(&self) -> &str {
        "Background shell jobs: bash_background, bash_output, bash_kill; /jobs"
    }
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        vec![Arc::new(Start(self.jobs.clone())), Arc::new(Output(self.jobs.clone())), Arc::new(Kill(self.jobs.clone()))]
    }
    fn commands(&self) -> Vec<CommandSpec> {
        vec![CommandSpec { name: "jobs".into(), help: "background jobs and their state".into() }]
    }
    fn command(&self, _ctx: &Ctx, name: &str, _args: &str, _messages: &mut Vec<crate::llm::Message>) -> Option<Result<CommandResult, String>> {
        (name == "jobs").then(|| Ok(CommandResult::Output(self.jobs.listing())))
    }
    fn session_end(&self, _session: &Session) {
        self.jobs.kill_all();
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn starts_reads_and_kills() {
        let jobs = Jobs::default();
        let dir = std::env::temp_dir();
        let id = jobs.start("echo hello; sleep 30", Some("sleeper"), &dir).unwrap();
        let mut text = String::new();
        for _ in 0..100 {
            text = jobs.output(id, true).unwrap();
            if text.contains("hello") {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(text.contains("hello") && text.contains("running"), "{text}");
        assert!(jobs.output(id, true).unwrap().contains("(no new output)"));
        assert!(jobs.output(id, false).unwrap().contains("hello"));
        assert!(jobs.listing().contains("sleeper"));
        jobs.kill(id).unwrap();
        assert!(jobs.output(id, true).unwrap().contains("stopped"));
        let done = jobs.start("exit 3", None, &dir).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        assert!(jobs.output(done, true).unwrap().contains("exited with code 3"));
        assert!(jobs.output(99, true).is_err());
    }

    #[test]
    fn ring_keeps_the_end() {
        let mut b = Buffer::default();
        b.push(&vec![b'a'; KEEP]);
        b.push(b"tail");
        assert_eq!(b.data.len(), KEEP);
        assert_eq!(b.dropped, 4);
        assert!(b.data.ends_with(b"tail"));
    }
}
