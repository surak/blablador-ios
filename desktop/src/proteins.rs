//! Proteins: the five molecular models on Blablador (ESMFold2, BioEmu2, RFdiffusion3, BindCraft,
//! Proteina-Complexa).
//!
//! They are not chat models: a request queues work that runs for minutes to hours. The protocol, the five
//! forms, their validation and the backbone check live in `blablador_models::molecular`, so `bla` and the app
//! read the same rules; what is here is the window, the jobs kept on this device, their encrypted archives
//! and the drawing. Results are deleted upstream 48 hours after a job finishes, so each one is downloaded the
//! moment its job completes and kept here afterwards.

use crate::api::Api;
use crate::storage;
use blablador_models::molecular as mol;
use chrono::{DateTime, Utc};
use eframe::egui::{self, Color32, Pos2, Vec2};
use mol::{Download, Failure, Form, Mode, Model, Progress, State, StructureCheck};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use uuid::Uuid;

const ACTION_TIMEOUT: Duration = Duration::from_secs(mol::ACTION_TIMEOUT);

const RED: Color32 = Color32::from_rgb(220, 80, 70);
const AMBER: Color32 = Color32::from_rgb(230, 170, 40);
const GREEN: Color32 = Color32::from_rgb(70, 180, 90);

// MARK: - talking to the shim

/// Posts one action and returns the `molecular_job` object. A network failure is never evidence that the
/// computation failed, so it comes back as a transient failure.
async fn post(api: &Api, model: &str, action: &Value) -> Result<Value, Failure> {
    if api.key.is_empty() {
        return Err(Failure::Other("No API key set. Add your Blablador API key in Settings.".into()));
    }
    match api.post_text("responses", &mol::request_body(model, action), ACTION_TIMEOUT).await {
        Ok((status, body)) => mol::read_answer(status, &body),
        Err(error) => Err(Failure::network(format!("{error:#}"))),
    }
}

/// Downloads the result archive chunk by chunk, retrying a transient failure at the same offset with a
/// jittered backoff. The bytes are only kept once every one of them has arrived.
async fn artifact(api: &Api, model: &str, job_id: &str, mut progress: impl FnMut(usize, usize)) -> Result<Vec<u8>, Failure> {
    let mut download = Download::default();
    let mut attempts = 0u32;
    while !download.done() {
        match post(api, model, &download.action(job_id)).await {
            Ok(chunk) => {
                attempts = 0;
                download.take(&chunk)?;
                progress(download.offset(), download.total().unwrap_or(0));
            }
            Err(error) if error.transient() && attempts < 5 => {
                attempts += 1;
                // The jitter is drawn before the wait: the generator must not be held across it.
                let jitter: f64 = rand::thread_rng().gen();
                tokio::time::sleep(Duration::from_secs_f64(Download::backoff(attempts, jitter))).await;
            }
            Err(error) => return Err(error),
        }
    }
    Ok(download.finish())
}

// MARK: - a job on this device

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResultState {
    None,
    Waiting,
    Downloading,
    Stored,
    Expired,
    Failed,
    TooLarge,
}

/// One submitted job. Kept on the device because the service has no job list of its own: this record is the
/// only link between the user and a job id.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Job {
    pub id: Uuid,
    pub model: Model,
    pub label: String,
    /// Kept so an ambiguous submission can be repeated unchanged.
    pub request_id: String,
    pub parameters: Value,
    pub remote_id: Option<String>,
    pub state: State,
    #[serde(default)]
    pub stage: String,
    #[serde(default)]
    pub message: String,
    pub queue_position: Option<u64>,
    #[serde(default)]
    pub waiting_reason: String,
    #[serde(default)]
    pub error: String,
    pub created: DateTime<Utc>,
    pub started: Option<DateTime<Utc>>,
    pub finished: Option<DateTime<Utc>>,
    /// When the result disappears upstream. Ours stays.
    pub expires: Option<DateTime<Utc>>,
    pub result: ResultState,
    pub result_bytes: Option<usize>,
    pub gpu_seconds: Option<f64>,
    /// The backbone check on the downloaded structure.
    pub check: Option<StructureCheck>,
    /// Seconds the service asked us to wait before the next poll.
    pub poll_after: f64,
    /// Whether the chat history already has the line about this job ending.
    #[serde(default)]
    pub noted: bool,
}

impl Job {
    fn new(model: Model, label: String, parameters: Value) -> Job {
        Job {
            id: Uuid::new_v4(),
            model,
            label,
            request_id: Uuid::new_v4().to_string(),
            parameters,
            remote_id: None,
            state: State::Submitting,
            stage: String::new(),
            message: String::new(),
            queue_position: None,
            waiting_reason: String::new(),
            error: String::new(),
            created: Utc::now(),
            started: None,
            finished: None,
            expires: None,
            result: ResultState::None,
            result_bytes: None,
            gpu_seconds: None,
            check: None,
            poll_after: mol::MINIMUM_POLL,
            noted: false,
        }
    }

    pub fn title(&self) -> String {
        if self.label.trim().is_empty() {
            self.model.name().to_string()
        } else {
            self.label.clone()
        }
    }

    fn file_name(&self) -> String {
        format!("{}.zip", self.id)
    }

    /// What to say about progress. There is no percentage and no ETA: the service publishes neither.
    pub fn progress_text(&self) -> String {
        mol::progress_text(self.state, &self.stage, &self.message, self.queue_position, &self.waiting_reason)
    }

    /// Reads what one answer said onto this record.
    pub fn apply(&mut self, progress: &Progress) {
        if let Some(remote) = &progress.id {
            self.remote_id = Some(remote.clone());
        }
        self.stage = progress.stage.clone();
        self.message = progress.message.clone();
        if !progress.error.is_empty() {
            self.error = progress.error.clone();
        }
        if progress.gpu_seconds.is_some() {
            self.gpu_seconds = progress.gpu_seconds;
        }
        self.poll_after = progress.poll_after;
        if let Some(state) = progress.state {
            self.state = state;
        }
        self.queue_position = progress.queue_position;
        self.waiting_reason = progress.waiting_reason.clone();
        if self.started.is_none() {
            self.started = progress.started_at.and_then(|stamp| DateTime::from_timestamp(stamp, 0));
        }
        if self.finished.is_none() {
            self.finished = progress.completed_at.and_then(|stamp| DateTime::from_timestamp(stamp, 0));
        }
        if self.state.finished() && self.finished.is_none() {
            self.finished = Some(Utc::now());
        }
        if self.state.finished() && self.expires.is_none() {
            let seconds = chrono::Duration::seconds(progress.retention_seconds as i64);
            self.expires = Some(self.finished.unwrap_or_else(Utc::now) + seconds);
        }
        // A finished job starts the race to download its result before it expires.
        if self.state == State::Completed && self.result == ResultState::None {
            self.result = ResultState::Waiting;
        }
    }
}

// MARK: - the jobs on this device

fn folder() -> PathBuf {
    storage::path("Molecular")
}

fn jobs_path() -> PathBuf {
    folder().join("molecular.json")
}

/// A line for the chat history. Every feature leaves one, so a protein job sits in the history next to the
/// questions asked around it rather than only in this window.
pub struct Note {
    pub question: Option<String>,
    pub answer: String,
}

/// The jobs, the archives they produced and what the background tasks are doing to them.
#[derive(Default)]
struct Shared {
    jobs: Vec<Job>,
    error: Option<String>,
    /// Picked up by the app and written to the chat history.
    notes: Vec<Note>,
    /// Bytes downloaded so far, per job.
    downloads: HashMap<Uuid, (usize, usize)>,
    /// Jobs a background task is already working on.
    busy: HashSet<Uuid>,
    /// Earliest time each job may be polled again.
    next: HashMap<Uuid, Instant>,
    /// What the last `queue` action reported, per model.
    queues: HashMap<Model, String>,
}

impl Shared {
    fn save(&self) {
        storage::write_json(&jobs_path(), &self.jobs);
    }

    fn with<R>(&mut self, id: Uuid, change: impl FnOnce(&mut Job) -> R) -> Option<R> {
        let job = self.jobs.iter_mut().find(|job| job.id == id)?;
        let result = change(job);
        self.save();
        Some(result)
    }

    fn job(&self, id: Uuid) -> Option<&Job> {
        self.jobs.iter().find(|job| job.id == id)
    }
}

/// Whether a job still needs the app to do something about it.
fn needs_work(job: &Job) -> bool {
    !job.state.finished() || job.result == ResultState::Waiting
}

pub struct Proteins {
    pub open: bool,
    shared: Arc<Mutex<Shared>>,
    model: Model,
    form: Form,
    /// The job whose result is on screen, and the structure read out of its archive.
    viewer: Option<Viewer>,
    complaint: Option<String>,
    yaw: f32,
    pitch: f32,
    zoom: f32,
}

impl Default for Proteins {
    fn default() -> Proteins {
        let jobs: Vec<Job> = storage::read_json(&jobs_path()).unwrap_or_default();
        Proteins {
            open: false,
            shared: Arc::new(Mutex::new(Shared { jobs, ..Default::default() })),
            model: Model::Esmfold2,
            form: Form::new(Model::Esmfold2),
            viewer: None,
            complaint: None,
            yaw: 0.0,
            pitch: 0.0,
            zoom: 1.0,
        }
    }
}

impl Proteins {
    /// Called every frame, whether the window is open or not: a result left undownloaded is a result lost.
    pub fn update(&mut self, ctx: &egui::Context, runtime: &tokio::runtime::Runtime, api: &Api) {
        if self.shared.lock().unwrap().jobs.iter().any(needs_work) {
            self.tick(runtime, ctx, api);
            ctx.request_repaint_after(Duration::from_secs(5));
        }
        self.window(ctx, runtime, api);
    }

    /// The lines waiting to go into the chat history.
    pub fn take_notes(&self) -> Vec<Note> {
        std::mem::take(&mut self.shared.lock().unwrap().notes)
    }

    /// Starts whatever each unfinished job needs next, no faster than its own poll interval.
    fn tick(&self, runtime: &tokio::runtime::Runtime, ctx: &egui::Context, api: &Api) {
        if api.key.is_empty() {
            return;
        }
        let due: Vec<Uuid> = {
            let shared = self.shared.lock().unwrap();
            shared
                .jobs
                .iter()
                .filter(|job| needs_work(job) && !shared.busy.contains(&job.id))
                .filter(|job| shared.next.get(&job.id).is_none_or(|next| *next <= Instant::now()))
                .map(|job| job.id)
                .collect()
        };
        for id in due {
            self.advance(runtime, ctx, api.clone(), id);
        }
    }

    /// Moves one job on: submit it, ask for its status, then fetch its result.
    fn advance(&self, runtime: &tokio::runtime::Runtime, ctx: &egui::Context, api: Api, id: Uuid) {
        let Some(job) = self.shared.lock().unwrap().job(id).cloned() else { return };
        if job.state.finished() && job.result != ResultState::Waiting {
            return;
        }
        self.shared.lock().unwrap().busy.insert(id);
        let (shared, ctx) = (self.shared.clone(), ctx.clone());
        runtime.spawn(async move {
            let outcome = run(&api, &shared, job).await;
            let mut state = shared.lock().unwrap();
            if let Err(error) = outcome {
                apply_failure(&mut state, id, &error);
            }
            note_finish(&mut state, id);
            let wait = state.job(id).map(|job| job.poll_after).unwrap_or(mol::MINIMUM_POLL);
            state.next.insert(id, Instant::now() + Duration::from_secs_f64(wait));
            state.busy.remove(&id);
            drop(state);
            ctx.request_repaint();
        });
    }

    fn submit(&mut self, runtime: &tokio::runtime::Runtime, ctx: &egui::Context, api: &Api) {
        let parameters = match mol::parameters(self.model, &self.form) {
            Ok(parameters) => parameters,
            Err(complaint) => {
                self.complaint = Some(complaint);
                return;
            }
        };
        self.complaint = None;
        let job = Job::new(self.model, self.form.label.trim().to_string(), parameters);
        let id = job.id;
        {
            let mut shared = self.shared.lock().unwrap();
            shared.notes.push(Note {
                question: Some(format!("{} — {}", job.title(), mol::summarise(&job.parameters))),
                answer: format!(
                    "Submitted to {}. It is a job, not a chat: it runs for minutes to hours, and the Proteins window \
                     has its state and its result. I'll add a line here when it finishes.",
                    job.model.alias()
                ),
            });
            shared.jobs.insert(0, job);
            shared.error = None;
            shared.save();
        }
        self.form = Form::new(self.model);
        self.advance(runtime, ctx, api.clone(), id);
    }

    fn cancel(&self, runtime: &tokio::runtime::Runtime, ctx: &egui::Context, api: &Api, id: Uuid) {
        let Some(job) = self.shared.lock().unwrap().job(id).cloned() else { return };
        let Some(remote) = job.remote_id.clone() else { return };
        let (shared, api, ctx) = (self.shared.clone(), api.clone(), ctx.clone());
        runtime.spawn(async move {
            // A cancelled job can still finish; the state the service sends is what we show.
            match post(&api, job.model.alias(), &mol::cancel_action(&remote)).await {
                Ok(answer) => {
                    shared.lock().unwrap().with(id, |job| job.apply(&Progress::parse(&answer)));
                }
                Err(error) => {
                    let mut state = shared.lock().unwrap();
                    apply_failure(&mut state, id, &error);
                }
            }
            ctx.request_repaint();
        });
    }

    fn ask_queue(&self, runtime: &tokio::runtime::Runtime, ctx: &egui::Context, api: &Api, model: Model) {
        let (shared, api, ctx) = (self.shared.clone(), api.clone(), ctx.clone());
        runtime.spawn(async move {
            let text = match post(&api, model.alias(), &mol::queue_action()).await {
                Ok(answer) => mol::queue_text(&answer),
                Err(error) => error.text(),
            };
            shared.lock().unwrap().queues.insert(model, text);
            ctx.request_repaint();
        });
    }

    fn delete(&mut self, id: Uuid) {
        let mut shared = self.shared.lock().unwrap();
        if let Some(job) = shared.job(id) {
            let _ = std::fs::remove_file(folder().join(job.file_name()));
        }
        shared.jobs.retain(|job| job.id != id);
        shared.save();
        drop(shared);
        if self.viewer.as_ref().is_some_and(|viewer| viewer.job == id) {
            self.viewer = None;
        }
    }

    /// Reads the structures out of a stored archive and measures the one that is shown.
    fn show_result(&mut self, id: Uuid) {
        let Some(job) = self.shared.lock().unwrap().job(id).cloned() else { return };
        let Some(archive) = storage::read(&folder().join(job.file_name())) else {
            self.shared.lock().unwrap().error = Some("The stored result could not be read.".into());
            return;
        };
        let files = structure_files(&archive);
        if files.is_empty() {
            self.shared.lock().unwrap().error = Some("No structure file in the result archive.".into());
            return;
        }
        let (name, text) = files[0].clone();
        self.viewer = Some(Viewer {
            job: id,
            names: files.iter().map(|(name, _)| name.clone()).collect(),
            files,
            check: mol::check_structure(&text),
            chains: mol::alpha_carbons(&text),
            name,
        });
        self.yaw = 0.0;
        self.pitch = 0.0;
        self.zoom = 1.0;
    }

    fn save_archive(&self, id: Uuid) {
        let Some(job) = self.shared.lock().unwrap().job(id).cloned() else { return };
        let Some(data) = storage::read(&folder().join(job.file_name())) else { return };
        let name = format!("{}-{}.zip", job.model.alias().trim_start_matches("alias-"), &job.id.to_string()[..8]);
        if let Some(path) = rfd::FileDialog::new().set_file_name(name).save_file() {
            if let Err(error) = std::fs::write(path, data) {
                self.shared.lock().unwrap().error = Some(error.to_string());
            }
        }
    }
}

/// Everything one turn of work on a job can do: submit or poll it, then fetch its result.
async fn run(api: &Api, shared: &Arc<Mutex<Shared>>, job: Job) -> Result<(), Failure> {
    let id = job.id;
    let model = job.model.alias();
    if let Some(remote) = job.remote_id.as_deref().filter(|_| !job.state.finished()) {
        let answer = post(api, model, &mol::status_action(remote)).await?;
        shared.lock().unwrap().with(id, |job| job.apply(&Progress::parse(&answer)));
    } else if job.remote_id.is_none() && matches!(job.state, State::Submitting | State::NotSubmitted) {
        // Repeating an ambiguous submission with the same request id and parameters is safe: the shim
        // returns the original job rather than starting a second computation.
        let answer = post(api, model, &mol::submit_action(&job.request_id, &job.parameters)).await?;
        shared.lock().unwrap().with(id, |job| {
            job.state = State::Queued;
            job.error.clear();
            job.apply(&Progress::parse(&answer));
        });
    }

    let waiting = shared.lock().unwrap().job(id).map(|job| job.result) == Some(ResultState::Waiting);
    if !waiting {
        return Ok(());
    }
    let Some(remote) = shared.lock().unwrap().job(id).and_then(|job| job.remote_id.clone()) else { return Ok(()) };
    {
        let mut state = shared.lock().unwrap();
        state.with(id, |job| job.result = ResultState::Downloading);
        state.downloads.insert(id, (0, 0));
    }
    let progress = {
        let shared = shared.clone();
        move |done, total| {
            shared.lock().unwrap().downloads.insert(id, (done, total));
        }
    };
    let data = match artifact(api, model, &remote, progress).await {
        Ok(data) => data,
        Err(error) => {
            let mut state = shared.lock().unwrap();
            state.downloads.remove(&id);
            state.with(id, |job| {
                job.result = match &error {
                    Failure::Gone => ResultState::Expired,
                    Failure::TooLarge(_) => ResultState::TooLarge,
                    error if error.transient() => ResultState::Waiting,
                    _ => ResultState::Failed,
                };
                if !error.transient() {
                    job.error = error.text();
                }
            });
            return Ok(());
        }
    };
    storage::write(&folder().join(format!("{id}.zip")), &data);
    // A finished job is not a sound result: measure the backbone before showing it.
    let check = check_archive(&data);
    let mut state = shared.lock().unwrap();
    state.downloads.remove(&id);
    state.with(id, |job| {
        job.result = ResultState::Stored;
        job.result_bytes = Some(data.len());
        job.check = check;
    });
    Ok(())
}

/// A failure while watching a job. A transient one is about us, not the computation.
fn apply_failure(state: &mut Shared, id: Uuid, error: &Failure) {
    let had_remote = state.job(id).and_then(|job| job.remote_id.clone()).is_some();
    state.with(id, |job| match error {
        Failure::Gone if had_remote => {
            if job.result != ResultState::Stored {
                job.result = ResultState::Expired;
            }
            if !job.state.finished() {
                job.error = error.text();
            }
        }
        error if error.transient() => {
            // The job is unaffected; say so rather than failing it.
            job.message = "Can't reach the service — your job is unaffected.".into();
        }
        error => {
            job.error = error.text();
            if job.remote_id.is_none() {
                job.state = State::NotSubmitted;
            }
            if matches!(job.result, ResultState::Waiting | ResultState::Downloading) {
                job.result = ResultState::Failed;
            }
        }
    });
}

/// Adds the line about a job ending to the chat history, once, when there is nothing left to wait for.
fn note_finish(state: &mut Shared, id: Uuid) {
    let Some(job) = state.job(id) else { return };
    if job.noted || !job.state.finished() || matches!(job.result, ResultState::Waiting | ResultState::Downloading) {
        return;
    }
    let mut answer = format!("{} · {} — {}.", job.model.name(), job.title(), job.state.name().to_lowercase());
    match job.result {
        ResultState::Stored => {
            answer += &format!(" The result archive is kept in the app, {:.1} MB.", job.result_bytes.unwrap_or(0) as f64 / 1_048_576.0);
            if let Some(check) = job.check {
                answer += &format!("\n\n{}", check.text());
            }
        }
        ResultState::Expired => answer += " The result was deleted upstream before it could be downloaded.",
        ResultState::TooLarge => answer += " The result is too large to keep on this machine.",
        ResultState::Failed => answer += " Downloading the result failed.",
        _ => {}
    }
    if !job.error.is_empty() {
        answer += &format!("\n\n{}", job.error);
    }
    state.notes.push(Note { question: None, answer });
    state.with(id, |job| job.noted = true);
}

// MARK: - reading the result archive

/// Just enough ZIP reading to get the structures out of a result: stored and deflated entries, found through
/// the central directory the way a real ZIP reader finds them.
pub fn zip_entries(data: &[u8]) -> Vec<(String, Vec<u8>)> {
    let le16 = |at: usize| u16::from_le_bytes([data[at], data[at + 1]]) as usize;
    let le32 = |at: usize| u32::from_le_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]]) as usize;
    // The end-of-central-directory record is last, after a comment of at most 64 KB.
    let Some(end) = (0..data.len().saturating_sub(21)).rev().take(66_000).find(|&at| data[at..].starts_with(b"PK\x05\x06"))
    else {
        return vec![];
    };
    let count = le16(end + 10);
    let mut at = le32(end + 16);
    let mut entries = Vec::new();
    for _ in 0..count {
        if at + 46 > data.len() || !data[at..].starts_with(b"PK\x01\x02") {
            break;
        }
        let method = le16(at + 10);
        let compressed = le32(at + 20);
        let size = le32(at + 24);
        let (name_length, extra, comment) = (le16(at + 28), le16(at + 30), le16(at + 32));
        let local = le32(at + 42);
        let name = String::from_utf8_lossy(&data[at + 46..(at + 46 + name_length).min(data.len())]).to_string();
        at += 46 + name_length + extra + comment;
        // The local header repeats the name and may hold different extra fields, so the data starts there.
        if local + 30 > data.len() || !data[local..].starts_with(b"PK\x03\x04") {
            continue;
        }
        let start = local + 30 + le16(local + 26) + le16(local + 28);
        let stop = (start + compressed).min(data.len());
        if start > stop || name.ends_with('/') {
            continue;
        }
        if let Some(bytes) = inflate(&data[start..stop], method, size) {
            entries.push((name, bytes));
        }
    }
    entries
}

fn inflate(data: &[u8], method: usize, size: usize) -> Option<Vec<u8>> {
    use std::io::Read;
    match method {
        0 => Some(data.to_vec()),
        8 => {
            let mut out = Vec::with_capacity(size);
            flate2::read::DeflateDecoder::new(data).read_to_end(&mut out).ok()?;
            Some(out)
        }
        _ => None,
    }
}

/// RFdiffusion3 returns its structures gzipped inside the archive.
pub fn gunzip(data: &[u8]) -> Option<Vec<u8>> {
    use std::io::Read;
    let mut out = Vec::new();
    flate2::read::MultiGzDecoder::new(data).read_to_end(&mut out).ok()?;
    Some(out)
}

/// The structures in a result archive, largest first, decompressed and as text.
pub fn structure_files(archive: &[u8]) -> Vec<(String, String)> {
    let mut found: Vec<(String, String)> = zip_entries(archive)
        .into_iter()
        .filter(|(name, _)| mol::is_structure_file(name))
        .filter_map(|(name, bytes)| {
            let bytes = if name.to_lowercase().ends_with(".gz") { gunzip(&bytes)? } else { bytes };
            Some((name, String::from_utf8_lossy(&bytes).to_string()))
        })
        .collect();
    found.sort_by_key(|(_, text)| std::cmp::Reverse(text.len()));
    found
}

/// Measures the largest structure in a result archive.
pub fn check_archive(archive: &[u8]) -> Option<StructureCheck> {
    structure_files(archive).iter().map(|(_, text)| mol::check_structure(text)).find(|check| check.bonds > 0)
}

// MARK: - drawing

/// A structure read out of a stored archive, ready to look at.
struct Viewer {
    job: Uuid,
    name: String,
    names: Vec<String>,
    files: Vec<(String, String)>,
    check: StructureCheck,
    chains: Vec<(String, Vec<[f32; 3]>)>,
}

impl Proteins {
    fn window(&mut self, ctx: &egui::Context, runtime: &tokio::runtime::Runtime, api: &Api) {
        if !self.open {
            return;
        }
        let (jobs, error, downloads, queues) = {
            let shared = self.shared.lock().unwrap();
            (shared.jobs.clone(), shared.error.clone(), shared.downloads.clone(), shared.queues.clone())
        };
        let mut open = self.open;
        egui::Window::new("Proteins").open(&mut open).default_width(640.0).default_height(700.0).show(ctx, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.label(
                    "Five molecular models on Blablador. They are not chat models: a job is queued and runs for \
                     minutes to hours, and the result is an archive kept here.",
                );
                if let Some(error) = &error {
                    ui.horizontal(|ui| {
                        ui.colored_label(RED, error);
                        if ui.small_button("✕").clicked() {
                            self.shared.lock().unwrap().error = None;
                        }
                    });
                }
                ui.separator();
                self.form_ui(ui, runtime, ctx, api, &queues);
                ui.separator();
                self.jobs_ui(ui, runtime, ctx, api, &jobs, &downloads);
            });
        });
        self.open = open;
    }

    fn form_ui(
        &mut self,
        ui: &mut egui::Ui,
        runtime: &tokio::runtime::Runtime,
        ctx: &egui::Context,
        api: &Api,
        queues: &HashMap<Model, String>,
    ) {
        ui.horizontal_wrapped(|ui| {
            let before = self.model;
            for model in Model::ALL {
                ui.selectable_value(&mut self.model, model, model.name());
            }
            if self.model != before {
                // Each model has its own fields and its own defaults, so switching starts from them.
                self.form = Form::new(self.model);
                self.complaint = None;
            }
        });
        ui.weak(self.model.blurb());
        for caveat in self.model.caveats() {
            ui.colored_label(AMBER, format!("• {caveat}"));
        }

        ui.add_space(4.0);
        ui.horizontal(|ui| {
            ui.label("Name");
            ui.add(egui::TextEdit::singleline(&mut self.form.label).hint_text("Optional, to find this run again").desired_width(300.0));
        });

        match self.model {
            Model::Esmfold2 => {
                sequence_field(ui, &mut self.form.sequence);
                ui.horizontal(|ui| {
                    ui.label("Loops").on_hover_text("1–8. More loops, slower, generally better.");
                    ui.add(egui::DragValue::new(&mut self.form.num_loops).range(1..=8));
                    ui.label("Steps").on_hover_text(
                        "Sampling steps. Low values finish quickly but can return a structure that is not physically foldable.",
                    );
                    ui.add(egui::DragValue::new(&mut self.form.steps).range(1..=1000));
                });
                if self.form.steps < 25 && self.form.num_loops < 2 {
                    ui.colored_label(
                        RED,
                        "At least 25 steps, or 2 loops: this combination returns structures that are not physically foldable.",
                    );
                }
            }
            Model::Bioemu2 => {
                sequence_field(ui, &mut self.form.sequence);
                ui.horizontal(|ui| {
                    ui.label("Conformations");
                    ui.add(egui::DragValue::new(&mut self.form.samples).range(1..=128));
                    seed_field(ui, &mut self.form.use_seed, &mut self.form.seed);
                });
                ui.weak(
                    "MSA mode: single sequence. No MSA is searched and ColabFold is not contacted; accuracy differs \
                     from an MSA-based run.",
                );
            }
            Model::Rfdiffusion3 => {
                ui.horizontal(|ui| {
                    ui.selectable_value(&mut self.form.mode, Mode::Unconditional, "Unconditional (validated)");
                    ui.selectable_value(&mut self.form.mode, Mode::Advanced, "RFD3 input object");
                });
                if self.form.mode == Mode::Unconditional {
                    ui.horizontal(|ui| {
                        ui.label("Length");
                        ui.add(egui::TextEdit::singleline(&mut self.form.length).hint_text("45 or 40-50").desired_width(120.0));
                        ui.weak("Residues.");
                    });
                } else {
                    ui.label("RFD3 input object");
                    ui.weak(
                        "A JSON object in the official RFdiffusion3 input schema — not an English prompt. Refer to an \
                         attached file by its filename.",
                    );
                    ui.add(egui::TextEdit::multiline(&mut self.form.rfd3_input).desired_rows(8).desired_width(f32::INFINITY).code_editor());
                }
                ui.horizontal(|ui| {
                    ui.label("Samples");
                    ui.add(egui::DragValue::new(&mut self.form.samples).range(1..=128));
                });
                ui.horizontal(|ui| {
                    if ui.button("Attach a PDB…").clicked() {
                        self.pick_structure(false);
                    }
                    if self.form.attachment.is_empty() {
                        ui.weak("Optional, referred to by name from the input object.");
                    } else {
                        ui.label(format!("📄 {}", self.form.attachment_file));
                        if ui.small_button("✕").clicked() {
                            self.form.attachment.clear();
                            self.form.attachment_file.clear();
                        }
                        ui.label("as");
                        ui.add(egui::TextEdit::singleline(&mut self.form.attachment_name).desired_width(140.0));
                    }
                });
            }
            Model::Bindcraft => {
                self.target_field(ui);
                ui.horizontal(|ui| {
                    ui.label("Target chains");
                    ui.add(egui::TextEdit::singleline(&mut self.form.chains).desired_width(100.0))
                        .on_hover_text("One or more chain ids, e.g. A or A,B.");
                    binder_fields(ui, &mut self.form);
                });
                ui.horizontal(|ui| {
                    ui.label("Hotspots");
                    ui.add(
                        egui::TextEdit::singleline(&mut self.form.hotspots)
                            .hint_text("Native BindCraft hotspot string, optional")
                            .desired_width(300.0),
                    );
                });
                ui.horizontal(|ui| {
                    ui.label("Final designs wanted");
                    ui.add(egui::DragValue::new(&mut self.form.samples).range(1..=128));
                    ui.label("Trajectories");
                    ui.add(egui::DragValue::new(&mut self.form.max_trajectories).range(1..=10000));
                    ui.label("Walltime");
                    ui.add(egui::DragValue::new(&mut self.form.walltime_hours).range(1..=24).suffix(" h"));
                });
            }
            Model::ProteinaComplexa => {
                self.target_field(ui);
                ui.horizontal(|ui| {
                    ui.label("Target selection");
                    ui.add(egui::TextEdit::singleline(&mut self.form.target_input).hint_text("B20-140").desired_width(120.0));
                    ui.weak("The chain and residue range to design against. Required.");
                });
                if self.form.target_input.trim().eq_ignore_ascii_case(mol::CANARY_SELECTION) {
                    ui.colored_label(
                        AMBER,
                        "A1-76 is the adapter's ubiquitin canary. It is meaningless for any other target — give your own selection.",
                    );
                }
                ui.horizontal(|ui| {
                    binder_fields(ui, &mut self.form);
                    ui.label("Samples");
                    ui.add(egui::DragValue::new(&mut self.form.samples).range(1..=128));
                });
                ui.horizontal(|ui| {
                    ui.label("Steps");
                    ui.add(egui::DragValue::new(&mut self.form.steps).range(1..=1000));
                    seed_field(ui, &mut self.form.use_seed, &mut self.form.seed);
                });
                ui.horizontal(|ui| {
                    ui.label("Hotspots");
                    ui.add(
                        egui::TextEdit::singleline(&mut self.form.hotspots)
                            .hint_text("Comma-separated, e.g. A30,A33")
                            .desired_width(300.0),
                    );
                });
            }
        }

        if let Some(complaint) = &self.complaint {
            ui.colored_label(RED, complaint);
        }
        ui.horizontal(|ui| {
            if ui.add_enabled(!api.key.is_empty(), egui::Button::new("Submit")).clicked() {
                self.submit(runtime, ctx, api);
            }
            if ui.button("Check the queue").clicked() {
                self.ask_queue(runtime, ctx, api, self.model);
            }
            if let Some(text) = queues.get(&self.model) {
                ui.weak(text);
            }
        });
    }

    fn target_field(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label("Target structure");
            if ui.button("Choose a PDB…").clicked() {
                self.pick_structure(true);
            }
            if self.form.target_pdb.is_empty() {
                ui.weak("Required.");
            } else {
                ui.label(format!("📄 {}", self.form.target_file));
                if ui.small_button("✕").clicked() {
                    self.form.target_pdb.clear();
                    self.form.target_file.clear();
                }
            }
        });
    }

    /// Reads a PDB from disk into the form, rejecting anything without atom records.
    fn pick_structure(&mut self, target: bool) {
        let Some(path) = rfd::FileDialog::new().add_filter("Structures", &["pdb", "ent", "txt"]).pick_file() else { return };
        let name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
        match std::fs::read(&path) {
            Ok(bytes) if bytes.len() > mol::MAX_STRUCTURE => self.complaint = Some("That structure file is too large.".into()),
            Ok(bytes) => match String::from_utf8(bytes) {
                Ok(text) if mol::is_structure(&text) => {
                    self.complaint = None;
                    if target {
                        self.form.target_pdb = text;
                        self.form.target_file = name;
                    } else {
                        self.form.attachment = text;
                        self.form.attachment_file = name.clone();
                        if mol::is_filename(&name) {
                            self.form.attachment_name = name;
                        }
                    }
                }
                Ok(_) => self.complaint = Some("That doesn't look like a PDB file — no ATOM or HETATM records found.".into()),
                Err(_) => self.complaint = Some("That file isn't text. Choose a PDB file, not a compressed archive.".into()),
            },
            Err(error) => self.complaint = Some(error.to_string()),
        }
    }

    fn jobs_ui(
        &mut self,
        ui: &mut egui::Ui,
        runtime: &tokio::runtime::Runtime,
        ctx: &egui::Context,
        api: &Api,
        jobs: &[Job],
        downloads: &HashMap<Uuid, (usize, usize)>,
    ) {
        ui.heading("Jobs");
        if jobs.is_empty() {
            ui.weak("Nothing submitted yet. Jobs are kept here because the service has no list of its own.");
            return;
        }
        let (mut delete, mut show, mut save, mut stop, mut retry) = (None, None, None, None, None);
        for job in jobs {
            let header = format!("{} · {} · {}", job.title(), job.model.name(), job.state.name());
            egui::CollapsingHeader::new(header).id_salt(job.id).default_open(!job.state.finished()).show(ui, |ui| {
                ui.label(job.progress_text());
                if !job.waiting_reason.is_empty() && job.state == State::Queued {
                    ui.weak(&job.waiting_reason);
                }
                let submitted = job.created.with_timezone(&chrono::Local).format("%d %b %H:%M");
                match &job.remote_id {
                    Some(remote) => ui.weak(format!("Job id {remote} · submitted {submitted}")),
                    None => ui.weak(format!("Submitted {submitted}")),
                };
                if let Some(seconds) = job.gpu_seconds {
                    ui.weak(format!("{seconds:.0} GPU seconds"));
                }
                if !job.error.is_empty() {
                    ui.colored_label(RED, &job.error);
                }
                match job.result {
                    ResultState::Downloading => {
                        let (done, total) = downloads.get(&job.id).copied().unwrap_or((0, 0));
                        ui.horizontal(|ui| {
                            ui.spinner();
                            ui.label(format!("Downloading the result: {} of {} MB", done / 1_048_576, total / 1_048_576));
                        });
                    }
                    ResultState::Waiting => {
                        ui.weak("Fetching the result; it is deleted upstream 48 hours after the job finishes.");
                    }
                    ResultState::Expired => {
                        ui.colored_label(AMBER, "The result was deleted upstream before it could be downloaded. Results live 48 hours.");
                    }
                    ResultState::TooLarge => {
                        ui.colored_label(AMBER, "The result is too large to keep here. It stays upstream for 48 hours.");
                    }
                    ResultState::Failed => {
                        ui.colored_label(RED, "Downloading the result failed.");
                    }
                    ResultState::Stored => {
                        let size = job.result_bytes.unwrap_or(0) as f64 / 1_048_576.0;
                        ui.label(format!("Result stored here · {size:.1} MB"));
                        if let Some(check) = job.check {
                            // A finished job is not a sound result; this is the one thing worth saying loudly.
                            ui.colored_label(if check.plausible_structure() { GREEN } else { RED }, check.text());
                        }
                    }
                    ResultState::None => {}
                }
                if let Some(expires) = job.expires.filter(|_| job.result != ResultState::Stored) {
                    ui.weak(format!("The upstream copy goes at {}.", expires.with_timezone(&chrono::Local).format("%d %b %H:%M")));
                }
                ui.horizontal_wrapped(|ui| {
                    if !job.state.finished() && job.remote_id.is_some() && ui.button("Cancel").clicked() {
                        stop = Some(job.id);
                    }
                    if job.result == ResultState::Stored {
                        if ui.button("Show the structure").clicked() {
                            show = Some(job.id);
                        }
                        if ui.button("Save the archive…").clicked() {
                            save = Some(job.id);
                        }
                    }
                    if matches!(job.result, ResultState::Failed | ResultState::Expired) && ui.button("Try the download again").clicked() {
                        retry = Some(job.id);
                    }
                    if ui.button("Delete").clicked() {
                        delete = Some(job.id);
                    }
                });
                egui::CollapsingHeader::new("What was sent").id_salt((job.id, "parameters")).show(ui, |ui| {
                    let text = serde_json::to_string_pretty(&job.parameters).unwrap_or_default();
                    ui.add(egui::Label::new(egui::RichText::new(text.chars().take(4000).collect::<String>()).monospace().small()).wrap());
                });
            });
        }
        if let Some(id) = stop {
            self.cancel(runtime, ctx, api, id);
        }
        if let Some(id) = retry {
            self.shared.lock().unwrap().with(id, |job| job.result = ResultState::Waiting);
            self.advance(runtime, ctx, api.clone(), id);
        }
        if let Some(id) = show {
            self.show_result(id);
        }
        if let Some(id) = save {
            self.save_archive(id);
        }
        if let Some(id) = delete {
            self.delete(id);
        }
        if self.viewer.is_some() {
            ui.separator();
            self.viewer_ui(ui);
        }
    }

    fn viewer_ui(&mut self, ui: &mut egui::Ui) {
        if self.viewer.is_none() {
            return;
        }
        ui.horizontal(|ui| {
            ui.heading("Structure");
            if ui.small_button("Close").clicked() {
                self.viewer = None;
            }
        });
        let Some(viewer) = &self.viewer else { return };
        let (check, mut chosen) = (viewer.check, viewer.name.clone());
        ui.colored_label(if check.plausible_structure() { GREEN } else { RED }, check.text());
        if viewer.names.len() > 1 {
            egui::ComboBox::from_id_salt("structure-file").selected_text(&chosen).width(360.0).show_ui(ui, |ui| {
                for name in &viewer.names {
                    ui.selectable_value(&mut chosen, name.clone(), name);
                }
            });
        }
        if chosen != viewer.name {
            if let Some((name, text)) = viewer.files.iter().find(|(name, _)| *name == chosen).cloned() {
                let viewer = self.viewer.as_mut().unwrap();
                viewer.check = mol::check_structure(&text);
                viewer.chains = mol::alpha_carbons(&text);
                viewer.name = name;
            }
        }
        let Some(viewer) = &self.viewer else { return };
        let residues: usize = viewer.chains.iter().map(|(_, points)| points.len()).sum();
        ui.weak(format!(
            "{} · {} chain(s), {residues} alpha carbons. Backbone only: predicted structures carry no \
             secondary-structure records.",
            viewer.name,
            viewer.chains.len()
        ));

        let width = ui.available_width();
        let (rect, response) = ui.allocate_exact_size(Vec2::new(width, (width * 0.65).min(420.0)), egui::Sense::drag());
        if response.dragged() {
            let delta = response.drag_delta();
            self.yaw += delta.x * 0.01;
            self.pitch = (self.pitch + delta.y * 0.01).clamp(-1.5, 1.5);
        }
        if response.hovered() {
            let scroll = ui.input(|i| i.smooth_scroll_delta.y);
            if scroll != 0.0 {
                self.zoom = (self.zoom * (scroll * 0.003).exp()).clamp(0.2, 20.0);
            }
        }
        let viewer = self.viewer.as_ref().unwrap();
        let painter = ui.painter_at(rect);
        painter.rect_filled(rect, 4.0, Color32::from_gray(20));
        // Centre and scale on the whole trace, then draw each chain's backbone as a polyline.
        let points: Vec<[f32; 3]> = viewer.chains.iter().flat_map(|(_, points)| points.iter().copied()).collect();
        if points.is_empty() {
            return;
        }
        let mut low = [f32::MAX; 3];
        let mut high = [f32::MIN; 3];
        for point in &points {
            for axis in 0..3 {
                low[axis] = low[axis].min(point[axis]);
                high[axis] = high[axis].max(point[axis]);
            }
        }
        let centre = [(low[0] + high[0]) / 2.0, (low[1] + high[1]) / 2.0, (low[2] + high[2]) / 2.0];
        let radius = (0..3).map(|axis| high[axis] - low[axis]).fold(0.0f32, f32::max).max(1.0) / 2.0;
        let scale = rect.width().min(rect.height()) * 0.45 * self.zoom / radius;
        let (sy, cy, sp, cp) = (self.yaw.sin(), self.yaw.cos(), self.pitch.sin(), self.pitch.cos());
        let project = |point: &[f32; 3]| {
            let (x, y, z) = (point[0] - centre[0], point[1] - centre[1], point[2] - centre[2]);
            let (x, z) = (x * cy - z * sy, x * sy + z * cy);
            let (y, _) = (y * cp - z * sp, y * sp + z * cp);
            Pos2::new(rect.center().x + x * scale, rect.center().y - y * scale)
        };
        let colors = [Color32::from_rgb(120, 170, 255), GREEN, AMBER, Color32::from_rgb(220, 140, 220), Color32::from_rgb(230, 120, 110)];
        for (index, (_, chain)) in viewer.chains.iter().enumerate() {
            // A broken bond is drawn as it is; the verdict above says whether that is normal.
            let stroke = egui::Stroke::new(1.5, colors[index % colors.len()]);
            painter.add(egui::Shape::line(chain.iter().map(project).collect(), stroke));
        }
        ui.horizontal(|ui| {
            ui.weak("Drag to turn, scroll to zoom.");
            if ui.button("Save as PDB…").clicked() {
                self.save_structure();
            }
        });
    }

    fn save_structure(&self) {
        let Some(viewer) = &self.viewer else { return };
        let Some((_, text)) = viewer.files.iter().find(|(name, _)| *name == viewer.name) else { return };
        let name = viewer.name.rsplit('/').next().unwrap_or(&viewer.name).trim_end_matches(".gz").to_string();
        if let Some(path) = rfd::FileDialog::new().set_file_name(name).save_file() {
            if let Err(error) = std::fs::write(path, text) {
                self.shared.lock().unwrap().error = Some(error.to_string());
            }
        }
    }
}

fn sequence_field(ui: &mut egui::Ui, text: &mut String) {
    ui.label("Protein sequence");
    ui.weak("FASTA or a bare one-letter sequence.");
    ui.add(egui::TextEdit::multiline(text).desired_rows(4).desired_width(f32::INFINITY).code_editor());
}

fn seed_field(ui: &mut egui::Ui, use_seed: &mut bool, seed: &mut i64) {
    ui.checkbox(use_seed, "Seed").on_hover_text("Off means the service picks one.");
    ui.add_enabled(*use_seed, egui::DragValue::new(seed).range(0..=i64::MAX));
}

fn binder_fields(ui: &mut egui::Ui, form: &mut Form) {
    ui.label("Binder length");
    ui.add(egui::DragValue::new(&mut form.binder_min).range(10..=500));
    ui.label("to");
    ui.add(egui::DragValue::new(&mut form.binder_max).range(10..=500));
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn applies_what_the_shim_sends() {
        let mut job = Job::new(Model::Esmfold2, "run".into(), json!({}));
        job.apply(&Progress::parse(&json!({ "id": "abc123", "status": "queued", "queue_position": 3,
                                            "waiting_reason": "gpu", "poll_after_seconds": 2 })));
        assert_eq!(job.remote_id.as_deref(), Some("abc123"));
        assert_eq!(job.queue_position, Some(3));
        // Never faster than the floor, whatever the service asks for.
        assert_eq!(job.poll_after, mol::MINIMUM_POLL);
        assert!(job.progress_text().contains("order, not a promise"));

        job.apply(&Progress::parse(&json!({ "id": "abc123", "status": "running", "poll_after_seconds": 45 })));
        // Queue position is only meaningful while queued.
        assert_eq!(job.queue_position, None);
        assert_eq!(job.poll_after, 45.0);

        job.apply(&Progress::parse(&json!({ "id": "abc123", "status": "completed", "usage": { "gpu_seconds": 12.5 } })));
        assert!(job.state.finished());
        // A finished job starts the race to download its result before it expires.
        assert_eq!(job.result, ResultState::Waiting);
        assert_eq!(job.gpu_seconds, Some(12.5));
        assert!(job.expires.is_some() && job.finished.is_some());
    }

    #[test]
    fn a_transient_failure_never_fails_a_job() {
        let mut shared = Shared::default();
        let mut job = Job::new(Model::Esmfold2, String::new(), json!({}));
        job.remote_id = Some("abc".into());
        job.state = State::Running;
        let id = job.id;
        shared.jobs.push(job);
        apply_failure(&mut shared, id, &Failure::network("down"));
        let job = shared.job(id).unwrap();
        assert_eq!(job.state, State::Running);
        assert!(job.error.is_empty() && job.message.contains("your job is unaffected"));
        // 404 is the one answer that means the result is genuinely gone.
        apply_failure(&mut shared, id, &Failure::Gone);
        assert_eq!(shared.job(id).unwrap().result, ResultState::Expired);
        // A submission that never landed is marked as such, not as a failed computation.
        let mut pending = Job::new(Model::Esmfold2, String::new(), json!({}));
        let pending_id = pending.id;
        pending.state = State::Submitting;
        shared.jobs.push(pending);
        apply_failure(&mut shared, pending_id, &Failure::Rejected("bad sequence".into()));
        assert_eq!(shared.job(pending_id).unwrap().state, State::NotSubmitted);
    }

    #[test]
    fn a_finished_job_leaves_one_line_in_the_history() {
        let mut shared = Shared::default();
        let mut job = Job::new(Model::Esmfold2, "ubiquitin".into(), json!({}));
        let id = job.id;
        job.state = State::Completed;
        job.result = ResultState::Waiting;
        shared.jobs.push(job);
        // Nothing is said while the result is still coming.
        note_finish(&mut shared, id);
        assert!(shared.notes.is_empty());
        shared.with(id, |job| {
            job.result = ResultState::Stored;
            job.result_bytes = Some(2_097_152);
            job.check = Some(StructureCheck { plausible: 1, bonds: 10, average: 10.0 });
        });
        note_finish(&mut shared, id);
        note_finish(&mut shared, id);
        assert_eq!(shared.notes.len(), 1);
        let answer = &shared.notes[0].answer;
        assert!(answer.contains("ubiquitin") && answer.contains("2.0 MB"));
        // The verdict travels with it: a finished job is not a sound result.
        assert!(answer.contains("not a physically plausible structure"));
    }

    /// A ZIP with stored and deflated entries, built by hand.
    fn zip(files: &[(&str, &[u8], bool)]) -> Vec<u8> {
        use std::io::Write;
        let (mut out, mut directory) = (Vec::new(), Vec::new());
        for (name, body, deflate) in files {
            let stored: Vec<u8> = if *deflate {
                let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
                encoder.write_all(body).unwrap();
                encoder.finish().unwrap()
            } else {
                body.to_vec()
            };
            let offset = out.len() as u32;
            let method: u16 = if *deflate { 8 } else { 0 };
            out.extend(b"PK\x03\x04");
            out.extend([20, 0, 0, 0]);
            out.extend(method.to_le_bytes());
            out.extend([0u8; 4]); // time and date
            out.extend(0u32.to_le_bytes()); // crc, unchecked here
            out.extend((stored.len() as u32).to_le_bytes());
            out.extend((body.len() as u32).to_le_bytes());
            out.extend((name.len() as u16).to_le_bytes());
            out.extend(0u16.to_le_bytes());
            out.extend(name.as_bytes());
            out.extend(&stored);

            directory.extend(b"PK\x01\x02");
            directory.extend([20, 0, 20, 0, 0, 0]);
            directory.extend(method.to_le_bytes());
            directory.extend([0u8; 4]);
            directory.extend(0u32.to_le_bytes());
            directory.extend((stored.len() as u32).to_le_bytes());
            directory.extend((body.len() as u32).to_le_bytes());
            directory.extend((name.len() as u16).to_le_bytes());
            directory.extend([0u8; 8]); // extra, comment, disk start, internal attributes
            directory.extend([0u8; 4]); // external attributes
            directory.extend(offset.to_le_bytes());
            directory.extend(name.as_bytes());
        }
        let start = out.len() as u32;
        let count = files.len() as u16;
        out.extend(&directory);
        out.extend(b"PK\x05\x06");
        out.extend([0u8; 4]);
        out.extend(count.to_le_bytes());
        out.extend(count.to_le_bytes());
        out.extend((directory.len() as u32).to_le_bytes());
        out.extend(start.to_le_bytes());
        out.extend(0u16.to_le_bytes());
        out
    }

    /// A straight chain of alpha carbons `spacing` Å apart.
    fn pdb(spacing: f64, count: usize) -> String {
        (0..count)
            .map(|i| {
                format!(
                    "ATOM  {:5}  CA  ALA A{:4}    {:8.3}{:8.3}{:8.3}  1.00  0.00           C",
                    i + 1,
                    i + 1,
                    spacing * i as f64,
                    0.0,
                    0.0
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn reads_structures_out_of_an_archive() {
        use std::io::Write;
        let small = pdb(3.8, 3);
        let large = pdb(10.0, 40);
        // RFdiffusion3 returns gzipped mmCIF, so the reader has to gunzip as well as inflate.
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        gz.write_all(large.as_bytes()).unwrap();
        let gz = gz.finish().unwrap();
        let archive = zip(&[("notes.txt", b"nothing to see", false), ("small.pdb", small.as_bytes(), true), ("design.cif.gz", &gz, false)]);
        let files = structure_files(&archive);
        // Largest first, and the .txt is not a structure.
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].0, "design.cif.gz");
        assert_eq!(files[1].0, "small.pdb");
        assert_eq!(files[1].1, small);
        // The archive's verdict comes from the largest structure in it, which this one fails.
        assert!(!check_archive(&archive).unwrap().plausible_structure());
        assert!(check_archive(b"not a zip").is_none());
        assert!(zip_entries(b"").is_empty());
    }
}
