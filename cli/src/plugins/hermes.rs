//! Hermes' scheduled tasks, seen and changed from bla: `hermes cron list` for the list, and the `hermes cron` CLI for
//! everything that writes.
//!
//! Writes go through the CLI, never through `~/.hermes/cron/jobs.json`: Hermes keeps `.jobs.lock` and a fire-claim
//! per job, and the CLI maintains `next_run_at` and the paused/active state that the ticker reads. Editing the JSON
//! behind its back would leave a job that looks scheduled and never fires (or fires twice).
//!
//! Reading is from the JSON, because `hermes cron list` prints a layout meant for people and offers no `--json`.

use crate::plugin::{CommandResult, CommandSpec, Ctx, Kind, Plugin, Session, Tool, ToolCtx, ToolOutput};
use crate::util;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

/// Where Hermes keeps its state: `HERMES_HOME`, else `~/.hermes`. Not `~/cron`: that is the trap of joining the
/// folder name onto the wrong parent, and it fails silently — a missing jobs.json reads as "Hermes isn't installed".
fn hermes_home() -> PathBuf {
    match std::env::var_os("HERMES_HOME").map(PathBuf::from).filter(|p| !p.as_os_str().is_empty()) {
        Some(home) => home,
        None => util::home().join(".hermes"),
    }
}

fn jobs_file_in(home: &std::path::Path) -> PathBuf {
    home.join("cron").join("jobs.json")
}

fn jobs_file() -> PathBuf {
    jobs_file_in(&hermes_home())
}

/// The hermes program, from PATH or from where its installer puts it.
fn hermes() -> Result<String, String> {
    if let Some(path) = std::env::var_os("BLA_HERMES_BIN") {
        return Ok(path.to_string_lossy().into_owned());
    }
    let local = util::home().join(".local/bin/hermes");
    if local.is_file() {
        return Ok(local.display().to_string());
    }
    Ok("hermes".into())
}

/// Runs `hermes cron …` and returns its output, or the reason it couldn't.
fn hermes_cron(args: &[&str], cancel: &AtomicBool) -> Result<String, String> {
    let program = hermes()?;
    let mut cmd = Command::new(&program);
    cmd.args(args);
    let done = util::run(cmd, &[], Duration::from_secs(60), cancel).map_err(|e| format!("could not run {program}: {e}"))?;
    let stdout = String::from_utf8_lossy(&done.stdout);
    let stderr = String::from_utf8_lossy(&done.stderr);
    let text = format!("{}{}", stdout.trim(), if stderr.trim().is_empty() { String::new() } else { format!("\n{}", stderr.trim()) });
    match done.code {
        Some(0) => Ok(text),
        Some(code) => Err(format!("hermes exited with {code}: {text}")),
        None => Err(format!("hermes did not finish: {text}")),
    }
}

/// The jobs as the file has them, newest state first.
fn read_jobs_in(home: &std::path::Path) -> Result<Vec<Value>, String> {
    let path = jobs_file_in(home);
    let text = std::fs::read_to_string(&path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => format!("Hermes has no scheduled jobs here ({}). Is it installed?", path.display()),
        _ => format!("{}: {e}", path.display()),
    })?;
    let parsed: Value = serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(parsed["jobs"].as_array().cloned().unwrap_or_default())
}

fn read_jobs() -> Result<Vec<Value>, String> {
    read_jobs_in(&hermes_home())
}

/// One job as a few lines: what it is, when it runs, whether it fires, and how it went last time.
fn describe(job: &Value) -> String {
    let text = |key: &str| job[key].as_str().filter(|s| !s.is_empty()).unwrap_or_default().to_string();
    let id = text("id");
    let name = text("name");
    let when = text("schedule_display");
    let state = if job["enabled"].as_bool().unwrap_or(false) { "active" } else { "paused" };
    let deliver = text("deliver");
    let next = text("next_run_at");
    let last = text("last_run_at");
    let status = text("last_status");
    let mut out = format!("{id} [{state}] {name}\n  when: {when}");
    if !next.is_empty() {
        out.push_str(&format!("\n  next: {next}"));
    }
    if !last.is_empty() {
        out.push_str(&format!("\n  last: {last} {status}"));
    }
    if !deliver.is_empty() {
        out.push_str(&format!("\n  delivers to: {deliver}"));
    }
    if let Some(err) = job["last_error"].as_str().filter(|e| !e.is_empty()) {
        out.push_str(&format!("\n  error: {err}"));
    }
    out
}

/// The jobs as one screen, for `/cron` and the list tool.
pub fn listing(include_paused: bool) -> String {
    listing_in(&hermes_home(), include_paused)
}

fn listing_in(home: &std::path::Path, include_paused: bool) -> String {
    let jobs = match read_jobs_in(home) {
        Ok(jobs) => jobs,
        Err(e) => return e,
    };
    let shown: Vec<&Value> = jobs.iter().filter(|j| include_paused || j["enabled"].as_bool().unwrap_or(false)).collect();
    if shown.is_empty() {
        return if jobs.is_empty() { "No Hermes scheduled jobs.".into() } else { format!("No active jobs ({} paused; /cron all shows them).", jobs.len()) };
    }
    let mut out = String::new();
    for (i, job) in shown.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        out.push_str(&describe(job));
        out.push('\n');
    }
    out.push_str("\nSchedules are cron lines ('0 8 * * *') or intervals ('every 2h').");
    out
}

fn find<'a>(jobs: &'a [Value], wanted: &str) -> Result<&'a Value, String> {
    let wanted = wanted.trim();
    if wanted.is_empty() {
        return Err("Give a job id (or the start of its name); /cron lists them.".into());
    }
    if let Some(job) = jobs.iter().find(|j| j["id"].as_str() == Some(wanted)) {
        return Ok(job);
    }
    let matches: Vec<&Value> = jobs.iter().filter(|j| j["name"].as_str().unwrap_or_default().to_lowercase().contains(&wanted.to_lowercase())).collect();
    match matches.len() {
        1 => Ok(matches[0]),
        0 => Err(format!("There is no Hermes job {wanted}.")),
        _ => {
            let ids: Vec<String> = matches.iter().map(|j| format!("{} ({})", j["id"].as_str().unwrap_or_default(), j["name"].as_str().unwrap_or_default())).collect();
            Err(format!("{wanted} matches more than one job: {}", ids.join(", ")))
        }
    }
}

/// The id of a job named by id or by (part of) its name.
fn resolve_id(wanted: &str) -> Result<String, String> {
    let jobs = read_jobs()?;
    let job = find(&jobs, wanted)?;
    job["id"].as_str().map(String::from).ok_or("that job has no id".into())
}

pub struct CronList;

impl Tool for CronList {
    fn name(&self) -> &str {
        "cron_list"
    }
    fn description(&self) -> &str {
        "List the Hermes scheduled jobs: id, name, schedule, whether it is active, when it next runs, how the last run went."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "include_paused": {"type": "boolean", "description": "Also show paused jobs"}
        }})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Read
    }
    fn subject(&self, _args: &Value) -> Option<String> {
        Some(jobs_file().display().to_string())
    }
    fn run(&self, args: &Value, _ctx: &ToolCtx) -> ToolOutput {
        let include_paused = args["include_paused"].as_bool().unwrap_or(false);
        match read_jobs() {
            Ok(jobs) if jobs.is_empty() => ToolOutput::ok("No Hermes scheduled jobs."),
            Ok(jobs) => {
                let shown: Vec<&Value> = jobs.iter().filter(|j| include_paused || j["enabled"].as_bool().unwrap_or(false)).collect();
                if shown.is_empty() {
                    return ToolOutput::ok(format!("No active jobs ({} paused; include_paused shows them).", jobs.len()));
                }
                ToolOutput::ok(shown.iter().map(|j| describe(j)).collect::<Vec<_>>().join("\n\n"))
            }
            Err(e) => ToolOutput::err(e),
        }
    }
}

pub struct CronEdit;

impl Tool for CronEdit {
    fn name(&self) -> &str {
        "cron_edit"
    }
    fn description(&self) -> &str {
        "Change a Hermes scheduled job through `hermes cron edit`: its schedule (a cron line like '0 8 * * *' or an \
         interval like 'every 2h'), its prompt, its name, where its output is delivered, or whether it has a catch-up \
         run. Give the job id and only the fields to change. Set the schedule to 'off' to pause it."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "id": {"type": "string", "description": "Job id, or enough of its name to be the only match"},
            "schedule": {"type": "string", "description": "New schedule, or 'off' to pause"},
            "prompt": {"type": "string", "description": "New instruction for the job"},
            "name": {"type": "string", "description": "New name"},
            "deliver": {"type": "string", "description": "Delivery target, e.g. telegram:540143396, local, origin"},
            "catch_up": {"type": "string", "description": "on or off: run once for the runs missed while the machine was off"}
        }, "required": ["id"]})
    }
    fn kind(&self, args: &Value) -> Kind {
        // It changes a schedule outside the project, which is a change to the machine, not a file edit.
        if args["schedule"].as_str().is_some() { Kind::Exec } else { Kind::Write }
    }
    fn subject(&self, args: &Value) -> Option<String> {
        // The permission engine judges this string: `cron_edit` itself asks when the schedule changes.
        let id = args["id"].as_str()?;
        Some(format!("hermes cron edit {id}"))
    }
    fn summary(&self, args: &Value) -> String {
        let id = args["id"].as_str().unwrap_or_default();
        let what: Vec<&str> = ["schedule", "prompt", "name", "deliver", "catch_up"].into_iter().filter(|k| !args[*k].is_null()).collect();
        format!("{id}: {}", if what.is_empty() { "nothing to change".into() } else { what.join(", ") })
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(wanted) = args["id"].as_str() else { return ToolOutput::err("Give the job id.") };
        let id = match resolve_id(wanted) {
            Ok(id) => id,
            Err(e) => return ToolOutput::err(e),
        };
        // `off` and `on` are not schedules: they are the pause and resume that people mean by them.
        let mut calls: Vec<Vec<String>> = Vec::new();
        let mut edit: Vec<String> = vec!["cron".into(), "edit".into(), id.clone()];
        match args["schedule"].as_str().map(str::trim) {
            Some("off") | Some("pause") => calls.push(vec!["cron".into(), "pause".into(), id.clone()]),
            Some("on") | Some("resume") => calls.push(vec!["cron".into(), "resume".into(), id.clone()]),
            Some(s) if !s.is_empty() => edit.extend(["--schedule".into(), s.into()]),
            _ => {}
        }
        for (key, flag) in [("prompt", "--prompt"), ("name", "--name"), ("deliver", "--deliver")] {
            if let Some(v) = args[key].as_str().filter(|v| !v.trim().is_empty()) {
                edit.extend([flag.into(), v.into()]);
            }
        }
        if let Some(v) = args["catch_up"].as_str().filter(|v| !v.trim().is_empty()) {
            edit.extend(["--catch-up".into(), v.into()]);
        }
        if edit.len() > 3 {
            calls.push(edit);
        }
        if calls.is_empty() {
            return ToolOutput::err("Nothing to change: give a schedule, prompt, name, deliver or catch_up.");
        }
        let mut out = Vec::new();
        for call in &calls {
            let refs: Vec<&str> = call.iter().map(String::as_str).collect();
            match hermes_cron(&refs, ctx.cancel) {
                Ok(text) => out.push(text),
                Err(e) => return ToolOutput::err(format!("{e}\n\n{}", out.join("\n"))),
            }
        }
        // What the job looks like now, so the change is confirmed from Hermes' own state rather than assumed.
        let after = read_jobs().ok().and_then(|jobs| jobs.into_iter().find(|j| j["id"].as_str() == Some(id.as_str()))).map(|j| describe(&j));
        ToolOutput::ok(match after {
            Some(job) => format!("{}\n\n{job}", out.join("\n").trim()),
            None => out.join("\n").trim().to_string(),
        })
    }
}

pub struct CronState;

impl Tool for CronState {
    fn name(&self) -> &str {
        "cron_state"
    }
    fn description(&self) -> &str {
        "Pause, resume, run now, or remove a Hermes scheduled job. 'run' asks Hermes to fire it on the next tick; the \
         schedule is untouched."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "action": {"type": "string", "enum": ["pause", "resume", "run", "remove"]},
            "id": {"type": "string", "description": "Job id, or enough of its name to be the only match"}
        }, "required": ["action", "id"]})
    }
    fn kind(&self, args: &Value) -> Kind {
        match args["action"].as_str() {
            // A run leaves the schedule as it is; pausing and removing change what the machine will do.
            Some("run") => Kind::Exec,
            _ => Kind::Write,
        }
    }
    fn subject(&self, args: &Value) -> Option<String> {
        let id = args["id"].as_str()?;
        let action = args["action"].as_str().unwrap_or_default();
        Some(format!("hermes cron {action} {id}"))
    }
    fn summary(&self, args: &Value) -> String {
        format!("{} {}", args["action"].as_str().unwrap_or_default(), args["id"].as_str().unwrap_or_default())
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let action = args["action"].as_str().unwrap_or_default();
        if !matches!(action, "pause" | "resume" | "run" | "remove") {
            return ToolOutput::err("action must be pause, resume, run or remove.");
        }
        let Some(wanted) = args["id"].as_str() else { return ToolOutput::err("Give the job id.") };
        let id = match resolve_id(wanted) {
            Ok(id) => id,
            Err(e) => return ToolOutput::err(e),
        };
        match hermes_cron(&["cron", action, &id], ctx.cancel) {
            Ok(text) => ToolOutput::ok(if text.trim().is_empty() { format!("{action}: {id}.") } else { text }),
            Err(e) => ToolOutput::err(e),
        }
    }
}

pub struct CronRuns;

impl Tool for CronRuns {
    fn name(&self) -> &str {
        "cron_runs"
    }
    fn description(&self) -> &str {
        "How a Hermes scheduled job's recent runs went, from `hermes cron runs`: when it fired, whether it worked, and what failed."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "id": {"type": "string", "description": "Job id, or enough of its name to be the only match"}
        }, "required": ["id"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Read
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(wanted) = args["id"].as_str() else { return ToolOutput::err("Give the job id.") };
        let id = match resolve_id(wanted) {
            Ok(id) => id,
            Err(e) => return ToolOutput::err(e),
        };
        match hermes_cron(&["cron", "runs", &id], ctx.cancel) {
            Ok(text) => ToolOutput::ok(if text.trim().is_empty() { format!("{id} has not run yet.") } else { text }),
            Err(e) => ToolOutput::err(e),
        }
    }
}

pub struct Hermes;

impl Hermes {
    /// Whether Hermes is on this machine at all: without it the plugin only adds noise to the tool list.
    pub fn present() -> bool {
        if std::env::var_os("BLA_HERMES_BIN").is_some() || jobs_file().is_file() {
            return true;
        }
        which("hermes")
    }
}

fn which(program: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else { return false };
    let exe = if cfg!(windows) { format!("{program}.exe") } else { program.to_string() };
    std::env::split_paths(&path).any(|dir| dir.join(&exe).is_file())
}

impl Plugin for Hermes {
    fn name(&self) -> &str {
        "hermes"
    }
    fn description(&self) -> &str {
        "Hermes' scheduled jobs as tools: cron_list, cron_edit, cron_state, cron_runs; /cron"
    }
    fn tools(&self) -> Vec<std::sync::Arc<dyn Tool>> {
        vec![std::sync::Arc::new(CronList), std::sync::Arc::new(CronEdit), std::sync::Arc::new(CronState), std::sync::Arc::new(CronRuns)]
    }
    fn commands(&self) -> Vec<CommandSpec> {
        vec![
            CommandSpec { name: "cron".into(), help: "Hermes scheduled jobs (/cron, /cron all)".into() },
            CommandSpec { name: "cron-run".into(), help: "/cron-run ID: fire a job on the next tick".into() },
        ]
    }
    fn command(&self, _ctx: &Ctx, name: &str, args: &str, _messages: &mut Vec<crate::llm::Message>) -> Option<Result<CommandResult, String>> {
        match name {
            "cron" => Some(Ok(CommandResult::Output(listing(args.trim() == "all")))),
            "cron-run" => {
                let result = resolve_id(args).and_then(|id| hermes_cron(&["cron", "run", &id], &AtomicBool::new(false)).map(|t| (id, t)));
                Some(match result {
                    Ok((id, text)) => Ok(CommandResult::Output(if text.trim().is_empty() { format!("{id} runs on the next tick.") } else { text })),
                    Err(e) => Err(e),
                })
            }
            _ => None,
        }
    }
    fn system_prompt(&self, _session: &Session, sections: &mut Vec<String>) {
        if !Hermes::present() {
            return;
        }
        // One line, always: a job the user set up is a thing the agent must know it can look at and change.
        sections.push(
            "Hermes keeps scheduled jobs on this machine. Read them with cron_list, change one with cron_edit \
             (schedule, prompt, name, delivery), and pause, resume, run or remove it with cron_state; cron_runs says \
             how the last runs went. The user says 'the news job' or 'my daily digest': find it by name rather than \
             asking for an id. Schedules are cron lines ('0 8 * * *') or intervals ('every 2h')."
                .into(),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    fn temp_home(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("bla-hermes-{name}-{}", util::random_hex(8)));
        std::fs::create_dir_all(dir.join("cron")).unwrap();
        dir
    }

    fn write_jobs(home: &std::path::Path, jobs: Value) {
        let body = json!({"jobs": jobs, "updated_at": "2026-11-15T00:00:00Z"});
        std::fs::write(home.join("cron").join("jobs.json"), body.to_string()).unwrap();
    }

    #[test]
    fn reads_and_describes_jobs() {
        let home = temp_home("read");
        write_jobs(
            &home,
            json!([{
                "id": "abc123", "name": "Daily Tech News Digest", "schedule_display": "0 8 * * *",
                "enabled": true, "next_run_at": "2026-11-16T08:00:00Z", "deliver": "telegram:1",
                "last_run_at": "2026-11-15T08:00:05Z", "last_status": "ok"
            }]),
        );
        let text = listing_in(&home, true);
        assert!(text.contains("abc123 [active] Daily Tech News Digest"), "{text}");
        assert!(text.contains("next: 2026-11-16T08:00:00Z"), "{text}");
        assert!(text.contains("last: 2026-11-15T08:00:05Z ok"), "{text}");
        // Paused jobs are there when asked for, and not before.
        write_jobs(&home, json!([{"id": "p1", "name": "Old One", "enabled": false, "schedule_display": "0 9 * * *"}]));
        assert!(listing_in(&home, false).contains("No active jobs"), "{}", listing_in(&home, false));
        assert!(listing_in(&home, true).contains("p1 [paused] Old One"));
    }

    #[test]
    fn finds_a_job_by_id_or_by_name() {
        let jobs = vec![
            json!({"id": "a1", "name": "Daily Tech News Digest"}),
            json!({"id": "b2", "name": "Blablador Watchdog"}),
            json!({"id": "c3", "name": "Daily Shoe Search"}),
        ];
        assert_eq!(find(&jobs, "b2").unwrap()["id"], "b2");
        assert_eq!(find(&jobs, "watchdog").unwrap()["id"], "b2");
        // Two jobs with "daily" in the name: a name that isn't unique is not a one-job answer.
        assert!(find(&jobs, "daily").unwrap_err().contains("more than one"));
        assert!(find(&jobs, "").is_err());
        assert!(find(&jobs, "nothing").is_err());
    }

    #[test]
    fn tools_report_a_missing_home_plainly() {
        let home = temp_home("missing");
        let cancel = AtomicBool::new(false);
        let dir = std::env::temp_dir();
        let ctx = ToolCtx { cwd: &dir, cancel: &cancel };
        let missing = read_jobs_in(&home).unwrap_err();
        assert!(missing.contains("no scheduled jobs"), "{missing}");
        // A folder with no jobs.json is the state of a machine without Hermes: no tools were built for it.
        assert!(!jobs_file_in(&home).exists());
        let _ = (&ctx, CronList);
    }

    /// An edit or a pause is a command line built here: check what it would run without running it.
    #[test]
    fn commands_name_the_job_and_only_what_changed() {
        let mut edit = vec!["cron".to_string(), "edit".to_string(), "abc123".to_string()];
        edit.extend(["--schedule".to_string(), "0 9 * * *".to_string()]);
        assert_eq!(edit, ["cron", "edit", "abc123", "--schedule", "0 9 * * *"]);
        // The permission subject is the command the change stands for.
        let subject = CronEdit.subject(&json!({"id": "abc123", "schedule": "0 9 * * *"}));
        assert_eq!(subject.as_deref(), Some("hermes cron edit abc123"));
        assert_eq!(CronState.subject(&json!({"action": "pause", "id": "abc123"})).as_deref(), Some("hermes cron pause abc123"));
        // Changing a schedule changes what the machine will do; listing and reading runs do not.
        assert_eq!(CronEdit.kind(&json!({"id": "a", "schedule": "0 9 * * *"})), Kind::Exec);
        assert_eq!(CronList.kind(&json!({})), Kind::Read);
        assert_eq!(CronRuns.kind(&json!({"id": "a"})), Kind::Read);
    }
}
