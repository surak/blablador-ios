//! The molecular models: ESMFold2, BioEmu2, RFdiffusion3, BindCraft and Proteina-Complexa.
//!
//! They are not chat models. A request queues work that runs for minutes to hours, and every action is a
//! `POST {endpoint}/responses` whose `input` is a JSON *string* holding the action; the answer carries a
//! `molecular_job` object. The envelope completing means the API call finished, never the computation.
//! Results come back as a chunked base64 ZIP and are deleted upstream 48 hours after a job finishes.
//!
//! Everything here is transport-agnostic: it builds request bodies and reads answers, and the caller does the
//! HTTP with its own client (reqwest in the desktop app, ureq in `bla`). Same protocol as the BioPortal web
//! frontend (github.com/surak/bioportal) and Proteins.swift.

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// One chunk of a result archive, the largest the shim sends.
pub const CHUNK: usize = 1_048_576;
/// Seconds to allow one API action; a job's own run is far longer.
pub const ACTION_TIMEOUT: u64 = 60;
/// Never poll faster than this, whatever the service asks for.
pub const MINIMUM_POLL: f64 = 10.0;
/// Results bigger than this aren't downloaded.
pub const MAX_ARTIFACT: usize = 512 * 1024 * 1024;
/// The shim's cap on the serialized parameters.
pub const MAX_PARAMETERS: usize = 12_000_000;
/// A structure file pasted or picked for a form.
pub const MAX_STRUCTURE: usize = 8_000_000;
pub const MAX_SEQUENCE: usize = 2000;
/// Results are deleted this long after a job reaches a terminal state.
pub const RETENTION: f64 = 48.0 * 3600.0;
/// The 20 amino acids plus X for unknown.
pub const AMINO_ACIDS: &str = "ACDEFGHIKLMNPQRSTVWYX";
/// What a result archive holds a structure in.
pub const STRUCTURE_SUFFIXES: [&str; 4] = [".pdb", ".cif", ".pdb.gz", ".cif.gz"];

// MARK: - failures

/// Anything that can go wrong talking to the shim.
#[derive(Clone, Debug, PartialEq)]
pub enum Failure {
    /// The computation is fine, our request wasn't.
    Transient(String),
    Gone,
    QueueFull,
    NotReady,
    Rejected(String),
    KeyRejected,
    TooLarge(usize),
    Other(String),
}

impl Failure {
    /// What the shim's status code means. A 404 is the one answer that says the job is genuinely gone.
    pub fn from_status(status: u16, body: &str) -> Failure {
        let detail: String = body.trim().chars().take(300).collect();
        match status {
            404 => Failure::Gone,
            429 => Failure::QueueFull,
            503 => Failure::NotReady,
            401 | 403 => Failure::KeyRejected,
            400 => Failure::Rejected(detail),
            status if status >= 500 => Failure::Transient(format!("HTTP {status}. {detail}")),
            status => Failure::Other(format!("HTTP {status}. {detail}")),
        }
    }

    /// A network-level failure, which is never evidence that the computation failed.
    pub fn network(detail: impl std::fmt::Display) -> Failure {
        Failure::Transient(format!("Can't reach Blablador: {detail}"))
    }

    /// Transient failures never mean the job itself failed.
    pub fn transient(&self) -> bool {
        matches!(self, Failure::Transient(_) | Failure::QueueFull | Failure::NotReady)
    }

    pub fn text(&self) -> String {
        match self {
            Failure::Transient(text) => text.clone(),
            Failure::Gone => {
                "The job or its result is no longer available. Results are deleted 48 hours after a job finishes.".into()
            }
            Failure::QueueFull => "The molecular queue is full. Try again shortly.".into(),
            Failure::NotReady => "No worker is ready for this model right now.".into(),
            Failure::Rejected(text) => format!("Rejected: {text}"),
            Failure::KeyRejected => "Blablador rejected your API key.".into(),
            Failure::TooLarge(bytes) => {
                format!("The result is {} MB, over the app's {} MB limit.", bytes / 1_048_576, MAX_ARTIFACT / 1_048_576)
            }
            Failure::Other(text) => text.clone(),
        }
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.text())
    }
}

impl std::error::Error for Failure {}

// MARK: - the protocol

/// The body of one action: `input` is a JSON *string*, not an object, and these models never stream.
pub fn request_body(model: &str, action: &Value) -> Value {
    json!({ "model": model, "stream": false, "input": action.to_string() })
}

/// Submitting is safe to repeat: the shim derives a stable job id from the request id and the model, so the
/// same request id with the same parameters returns the original job instead of starting a second computation.
pub fn submit_action(request_id: &str, parameters: &Value) -> Value {
    json!({ "action": "submit", "request_id": request_id, "parameters": parameters })
}

pub fn status_action(job_id: &str) -> Value {
    json!({ "action": "status", "job_id": job_id })
}

pub fn cancel_action(job_id: &str) -> Value {
    json!({ "action": "cancel", "job_id": job_id })
}

pub fn queue_action() -> Value {
    json!({ "action": "queue" })
}

pub fn artifact_action(job_id: &str, offset: usize) -> Value {
    json!({ "action": "artifact", "job_id": job_id, "offset": offset, "length": CHUNK })
}

/// The `molecular_job` object out of an answer, or the compatibility copy in output[0].content[0].text.
/// Anything else — an HTML gateway error, a chat completion — yields nothing.
pub fn job_from(envelope: &Value) -> Option<Value> {
    if envelope["molecular_job"].is_object() {
        return Some(envelope["molecular_job"].clone());
    }
    let text = envelope["output"][0]["content"][0]["text"].as_str()?;
    serde_json::from_str::<Value>(text).ok().filter(Value::is_object)
}

/// What a caller does with one answer: the job object, or the failure it stands for.
pub fn read_answer(status: u16, body: &str) -> Result<Value, Failure> {
    if !(200..300).contains(&status) {
        return Err(Failure::from_status(status, body));
    }
    // The router can answer with an HTML gateway error and a 200, so parse defensively.
    let envelope: Value =
        serde_json::from_str(body).map_err(|_| Failure::Transient("The router did not answer with JSON.".into()))?;
    job_from(&envelope).ok_or_else(|| Failure::Other("The answer held no molecular_job object.".into()))
}

/// A result archive being reassembled from base64 chunks.
#[derive(Default)]
pub struct Download {
    data: Vec<u8>,
    total: Option<usize>,
}

impl Download {
    /// The next offset to ask for: the number of *decoded* bytes held, never the length of the base64 text.
    pub fn offset(&self) -> usize {
        self.data.len()
    }

    pub fn total(&self) -> Option<usize> {
        self.total
    }

    /// Only true once every byte has arrived; a partial download is never mistaken for a result.
    pub fn done(&self) -> bool {
        self.total.is_some_and(|total| self.data.len() >= total)
    }

    pub fn finish(self) -> Vec<u8> {
        self.data
    }

    /// The next action to send. Repeat it unchanged after a transient failure, with a jittered backoff.
    pub fn action(&self, job_id: &str) -> Value {
        artifact_action(job_id, self.offset())
    }

    /// How long to wait before asking for the same offset again, in seconds.
    pub fn backoff(attempt: u32, jitter: f64) -> f64 {
        (1u64 << attempt.min(16)).min(30) as f64 * (0.5 + jitter.clamp(0.0, 1.0) * 0.5)
    }

    pub fn take(&mut self, chunk: &Value) -> Result<(), Failure> {
        if self.total.is_none() {
            let total = chunk["total_bytes"].as_u64().unwrap_or(0) as usize;
            if total == 0 {
                return Err(Failure::Other("The result is empty.".into()));
            }
            if total > MAX_ARTIFACT {
                return Err(Failure::TooLarge(total));
            }
            self.total = Some(total);
        }
        let unreadable = || Failure::Other(format!("A result chunk at {} bytes could not be read.", self.data.len()));
        let text = chunk["data_base64"].as_str().ok_or_else(unreadable)?;
        let piece = base64::engine::general_purpose::STANDARD.decode(text.trim()).map_err(|_| unreadable())?;
        if piece.is_empty() {
            return Err(unreadable());
        }
        self.data.extend_from_slice(&piece);
        Ok(())
    }
}

// MARK: - what a job is doing

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    /// Sent, but we don't know the job id yet.
    Submitting,
    Queued,
    Running,
    Cancelling,
    Completed,
    Failed,
    Cancelled,
    /// Submitting failed outright; nothing is running.
    NotSubmitted,
}

impl State {
    pub fn from_wire(text: &str) -> Option<State> {
        Some(match text {
            "pending" | "submitting" => State::Submitting,
            "queued" => State::Queued,
            "running" => State::Running,
            "cancelling" => State::Cancelling,
            "completed" => State::Completed,
            "failed" => State::Failed,
            "cancelled" => State::Cancelled,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            State::Submitting => "Submitting",
            State::Queued => "Queued",
            State::Running => "Running",
            State::Cancelling => "Cancelling",
            State::Completed => "Finished",
            State::Failed => "Failed",
            State::Cancelled => "Cancelled",
            State::NotSubmitted => "Not submitted",
        }
    }

    pub fn finished(self) -> bool {
        matches!(self, State::Completed | State::Failed | State::Cancelled | State::NotSubmitted)
    }
}

/// What one `molecular_job` object says, with nothing invented. There is no percentage and no ETA: the
/// service publishes neither, and `estimated_*` is documented as null.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Progress {
    pub id: Option<String>,
    pub state: Option<State>,
    pub stage: String,
    pub message: String,
    pub queue_position: Option<u64>,
    pub waiting_reason: String,
    pub error: String,
    pub gpu_seconds: Option<f64>,
    /// Seconds the service asked us to wait, never below `MINIMUM_POLL`.
    pub poll_after: f64,
    /// Unix seconds, as the shim sends them.
    pub started_at: Option<i64>,
    pub completed_at: Option<i64>,
    pub retention_seconds: f64,
}

impl Progress {
    pub fn parse(job: &Value) -> Progress {
        let state = job["status"].as_str().and_then(State::from_wire);
        Progress {
            id: job["id"].as_str().filter(|id| !id.is_empty()).map(String::from),
            state,
            stage: job["stage"].as_str().unwrap_or_default().into(),
            message: job["message"].as_str().unwrap_or_default().into(),
            // Queue positions are only meaningful while queued.
            queue_position: (state == Some(State::Queued))
                .then(|| job["queue_position"].as_u64().or_else(|| job["model_queue_position"].as_u64()))
                .flatten(),
            waiting_reason: if state == Some(State::Queued) { job["waiting_reason"].as_str().unwrap_or_default().into() } else { String::new() },
            error: match &job["error"] {
                Value::Null => String::new(),
                Value::String(text) => text.chars().take(4000).collect(),
                other => other.to_string().chars().take(4000).collect(),
            },
            gpu_seconds: job["usage"]["gpu_seconds"].as_f64(),
            poll_after: job["poll_after_seconds"].as_f64().unwrap_or(MINIMUM_POLL).max(MINIMUM_POLL),
            started_at: job["started_at"].as_f64().map(|stamp| stamp as i64),
            completed_at: job["completed_at"].as_f64().map(|stamp| stamp as i64),
            retention_seconds: job["retention_seconds"].as_f64().unwrap_or(RETENTION),
        }
    }
}

/// What to say about progress. No percentage, no ETA; a queue position is an order, not a start time, and
/// cancelling is a race the job can still win.
pub fn progress_text(state: State, stage: &str, message: &str, queue_position: Option<u64>, waiting_reason: &str) -> String {
    if !message.is_empty() {
        return message.to_string();
    }
    if !stage.is_empty() {
        return stage.to_string();
    }
    match state {
        State::Queued => match queue_position {
            Some(position) => format!("Queued, {position} ahead. That is the order, not a promise of a start time."),
            None if !waiting_reason.is_empty() => waiting_reason.to_string(),
            None => "Queued.".into(),
        },
        State::Running => "Running. The service gives no estimate of how long it will take.".into(),
        State::Cancelling => "Cancelling. The job may still finish: stopping is not immediate.".into(),
        state => state.name().into(),
    }
}

/// The queue action's answer in one line, again without inventing a start time.
pub fn queue_text(answer: &Value) -> String {
    let mut parts = Vec::new();
    for (key, label) in [("queued", "queued"), ("running", "running"), ("depth", "in the queue"), ("workers", "workers")] {
        if let Some(number) = answer[key].as_u64() {
            parts.push(format!("{number} {label}"));
        }
    }
    if parts.is_empty() {
        answer.to_string().chars().take(200).collect()
    } else {
        format!("{} — that is the order, not a start time.", parts.join(", "))
    }
}

// MARK: - the five models

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Model {
    Esmfold2,
    Bioemu2,
    Rfdiffusion3,
    Bindcraft,
    ProteinaComplexa,
}

impl Model {
    pub const ALL: [Model; 5] = [Model::Esmfold2, Model::Bioemu2, Model::Rfdiffusion3, Model::Bindcraft, Model::ProteinaComplexa];

    /// The exact API model id, from `crate::MOLECULAR_MODELS`, which is also what keeps these five out of
    /// every chat model picker.
    pub fn alias(self) -> &'static str {
        match self {
            Model::Esmfold2 => crate::MOLECULAR_MODELS[0],
            Model::Bioemu2 => crate::MOLECULAR_MODELS[1],
            Model::Rfdiffusion3 => crate::MOLECULAR_MODELS[2],
            Model::Bindcraft => crate::MOLECULAR_MODELS[3],
            Model::ProteinaComplexa => crate::MOLECULAR_MODELS[4],
        }
    }

    pub fn from_alias(alias: &str) -> Option<Model> {
        Model::ALL.into_iter().find(|model| model.alias().eq_ignore_ascii_case(alias))
    }

    pub fn name(self) -> &'static str {
        match self {
            Model::Esmfold2 => "ESMFold2",
            Model::Bioemu2 => "BioEmu2",
            Model::Rfdiffusion3 => "RFdiffusion3",
            Model::Bindcraft => "BindCraft",
            Model::ProteinaComplexa => "Proteina-Complexa",
        }
    }

    pub fn blurb(self) -> &'static str {
        match self {
            Model::Esmfold2 => "Predicts a structure from one protein sequence.",
            Model::Bioemu2 => "Samples an ensemble of conformations rather than one structure.",
            Model::Rfdiffusion3 => "Designs new proteins, by length or from an RFD3 input object.",
            Model::Bindcraft => "Designs binders against a target structure and filters them.",
            Model::ProteinaComplexa => "NVIDIA Proteina-Complexa binder generation against a target.",
        }
    }

    /// Caveats from the deployment, shown before the job is sent.
    pub fn caveats(self) -> &'static [&'static str] {
        match self {
            Model::Esmfold2 => &["Produces exactly one prediction; the sequence path ignores sample count and seed."],
            Model::Bioemu2 => &[
                "The sequence shortcut creates protein chain A.",
                "Runs on one GPU; the multi-GPU path was not validated.",
            ],
            Model::Rfdiffusion3 => {
                &["Unconditional design of 40–50 residues is the validated path. Other input is passed through to RFD3 unvalidated."]
            }
            Model::Bindcraft => &[
                "The quality filters can accept fewer designs than you asked for: a finished run is not a guarantee of quality.",
                "Output is not deterministic; this build does not wire a seed into the CLI.",
            ],
            Model::ProteinaComplexa => {
                &["Single-pass binder generation with reward scoring disabled, not the full reward-guided pipeline."]
            }
        }
    }
}

// MARK: - validating what the user typed

/// Accepts FASTA or a bare sequence and returns a bare, validated one. The shim's own validator only checks
/// for uppercase A–Z, so the biological check has to happen here.
pub fn sequence(raw: &str) -> Result<String, String> {
    let joined: String =
        raw.lines().map(str::trim).filter(|line| !line.is_empty() && !line.starts_with('>')).collect::<Vec<_>>().join("");
    let sequence: String = joined.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_uppercase();
    if sequence.is_empty() {
        return Err("No sequence found.".into());
    }
    let mut bad: Vec<char> = sequence.chars().filter(|c| !AMINO_ACIDS.contains(*c)).collect();
    bad.sort_unstable();
    bad.dedup();
    if !bad.is_empty() {
        let bad: Vec<String> = bad.iter().map(|c| c.to_string()).collect();
        return Err(format!("Not a protein sequence — unexpected characters: {}", bad.join(", ")));
    }
    if sequence.chars().count() > MAX_SEQUENCE {
        return Err(format!("The sequence is {} residues; the app's limit is {MAX_SEQUENCE}.", sequence.chars().count()));
    }
    Ok(sequence)
}

/// A PDB is recognised the way the portal recognises one: by its atom records.
pub fn is_structure(text: &str) -> bool {
    text.lines().take(5000).any(|line| line.starts_with("ATOM  ") || line.starts_with("HETATM"))
}

/// A chain and residue range such as `A1-76` or `B20-140`.
pub fn is_residue_selection(text: &str) -> bool {
    let Some((head, tail)) = text.split_once('-') else { return false };
    let digits = head.chars().rev().take_while(char::is_ascii_digit).count();
    !tail.is_empty()
        && tail.chars().all(|c| c.is_ascii_digit())
        && digits > 0
        && head.chars().count() > digits
        && head.chars().all(|c| c.is_ascii_alphanumeric())
}

/// One or more chain ids, e.g. `A` or `A,B`.
pub fn is_chains(text: &str) -> bool {
    !text.is_empty() && text.split(',').all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_alphanumeric()))
}

/// Residues, e.g. `45` or `40-50`.
pub fn is_length(text: &str) -> bool {
    let (head, tail) = text.split_once('-').unwrap_or((text, "0"));
    !head.is_empty() && !tail.is_empty() && head.chars().chain(tail.chars()).all(|c| c.is_ascii_digit())
}

/// Filenames only: the adapter rejects server paths and traversal.
pub fn is_filename(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
}

// MARK: - the five forms

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Unconditional,
    Advanced,
}

/// The adapter's fallback selection for Proteina-Complexa is the ubiquitin canary. It is meaningless for any
/// other target, so the form always asks for an explicit selection.
pub const CANARY_SELECTION: &str = "A1-76";

/// One model's inputs, with that model's defaults. Ranges and validation follow the portal's forms, so a
/// request the service would reject never leaves the building.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Form {
    pub label: String,
    pub sequence: String,
    pub num_loops: i64,
    pub steps: i64,
    pub samples: i64,
    pub use_seed: bool,
    pub seed: i64,
    pub mode: Mode,
    pub length: String,
    pub rfd3_input: String,
    /// A PDB referred to by name from the RFD3 input object.
    pub attachment: String,
    pub attachment_file: String,
    pub attachment_name: String,
    pub target_pdb: String,
    pub target_file: String,
    pub target_input: String,
    pub chains: String,
    pub binder_min: i64,
    pub binder_max: i64,
    pub hotspots: String,
    pub max_trajectories: i64,
    pub walltime_hours: i64,
}

impl Form {
    pub fn new(model: Model) -> Form {
        Form {
            label: String::new(),
            sequence: String::new(),
            num_loops: 3,
            steps: if model == Model::ProteinaComplexa { 400 } else { 50 },
            samples: 1,
            use_seed: true,
            seed: 42,
            mode: Mode::Unconditional,
            length: "40-50".into(),
            rfd3_input: String::new(),
            attachment: String::new(),
            attachment_file: String::new(),
            attachment_name: "target.pdb".into(),
            target_pdb: String::new(),
            target_file: String::new(),
            target_input: String::new(),
            chains: "A".into(),
            binder_min: 60,
            binder_max: 100,
            hotspots: String::new(),
            max_trajectories: 100,
            walltime_hours: 24,
        }
    }
}

/// Turns a filled-in form into the shim's `parameters` object, or says what is wrong with it.
pub fn parameters(model: Model, form: &Form) -> Result<Value, String> {
    let binder_lengths = |form: &Form| -> Result<Value, String> {
        if !(10..=500).contains(&form.binder_min) || !(10..=500).contains(&form.binder_max) {
            return Err("Binder lengths are 10 to 500 residues.".into());
        }
        if form.binder_min > form.binder_max {
            return Err("The longest binder must be at least as long as the shortest.".into());
        }
        Ok(json!([form.binder_min, form.binder_max]))
    };
    let samples = |form: &Form| -> Result<i64, String> {
        (1..=128).contains(&form.samples).then_some(form.samples).ok_or_else(|| "Samples are 1 to 128.".into())
    };
    let target = |form: &Form| -> Result<String, String> {
        if form.target_pdb.trim().is_empty() {
            return Err("Choose a target structure (PDB).".into());
        }
        if !is_structure(&form.target_pdb) {
            return Err("That doesn't look like a PDB file — no ATOM or HETATM records found.".into());
        }
        Ok(form.target_pdb.clone())
    };

    let params = match model {
        Model::Esmfold2 => {
            let sequence = sequence(&form.sequence)?;
            if !(1..=8).contains(&form.num_loops) {
                return Err("Loops are 1 to 8.".into());
            }
            if !(1..=1000).contains(&form.steps) {
                return Err("Steps are 1 to 1000.".into());
            }
            // Measured: 1 loop and 10 steps returned a backbone whose consecutive alpha carbons averaged 10 Å
            // apart, against the ~3.8 Å chemistry allows. The service accepts it and calls the job a success.
            if form.steps < 25 && form.num_loops < 2 {
                return Err("This combination of steps and loops has been observed to produce structures that are not physically foldable. Use at least 25 steps, or 2 loops.".into());
            }
            json!({ "sequence": sequence, "num_loops": form.num_loops, "steps": form.steps })
        }
        Model::Bioemu2 => {
            // Single-sequence mode is a deliberate scientific choice, never a silent default: no MSA is
            // searched and accuracy differs from an MSA-based run.
            let mut params = json!({ "sequence": sequence(&form.sequence)?, "samples": samples(form)?, "msa_mode": "single_sequence" });
            if form.use_seed {
                params["seed"] = json!(form.seed);
            }
            params
        }
        Model::Rfdiffusion3 => {
            let mut params = match form.mode {
                Mode::Unconditional => {
                    if !is_length(form.length.trim()) {
                        return Err("A length is required for this mode, e.g. 45 or 40-50.".into());
                    }
                    json!({ "input": { "api": { "length": form.length.trim() } } })
                }
                Mode::Advanced => {
                    let raw = form.rfd3_input.trim();
                    if raw.is_empty() {
                        return Err("An RFD3 input object is required.".into());
                    }
                    // An official RFD3 input object, not an English prompt.
                    let parsed: Value = serde_json::from_str(raw).map_err(|e| format!("Not valid JSON: {e}"))?;
                    if !parsed.is_object() {
                        return Err("The RFD3 input must be a JSON object.".into());
                    }
                    json!({ "input": parsed })
                }
            };
            params["samples"] = json!(samples(form)?);
            if !form.attachment.is_empty() {
                if !is_filename(form.attachment_name.trim()) {
                    return Err("Name the attachment so the input can refer to it: letters, digits, . _ or -.".into());
                }
                params["files"] = json!({ form.attachment_name.trim(): form.attachment });
            }
            params
        }
        Model::Bindcraft => {
            let target = target(form)?;
            if !is_chains(form.chains.trim()) {
                return Err("Target chains are chain ids, e.g. A or A,B.".into());
            }
            if !(1..=10000).contains(&form.max_trajectories) {
                return Err("Trajectories are 1 to 10000.".into());
            }
            if !(1..=24).contains(&form.walltime_hours) {
                return Err("The walltime is 1 to 24 hours.".into());
            }
            let mut params = json!({
                "target_pdb": target,
                "chains": form.chains.trim(),
                "binder_length": binder_lengths(form)?,
                "samples": samples(form)?,
                "max_trajectories": form.max_trajectories,
                "walltime_seconds": form.walltime_hours * 3600,
            });
            if !form.hotspots.trim().is_empty() {
                // BindCraft takes its own hotspot string, unlike Complexa's list.
                params["hotspots"] = json!(form.hotspots.trim());
            }
            params
        }
        Model::ProteinaComplexa => {
            let target = target(form)?;
            let selection = form.target_input.trim();
            if selection.is_empty() {
                return Err("A target selection is required; it is never defaulted.".into());
            }
            if !is_residue_selection(selection) {
                return Err("Use a chain and residue range, for example B20-140.".into());
            }
            if !(1..=1000).contains(&form.steps) {
                return Err("Steps are 1 to 1000.".into());
            }
            let mut params = json!({
                "target_pdb": target,
                "target_input": selection,
                "binder_length": binder_lengths(form)?,
                "samples": samples(form)?,
                "steps": form.steps,
            });
            if form.use_seed {
                params["seed"] = json!(form.seed);
            }
            if !form.hotspots.trim().is_empty() {
                // Complexa takes a list here, unlike BindCraft's hotspot string.
                let list: Vec<&str> = form.hotspots.split(',').map(str::trim).filter(|h| !h.is_empty()).collect();
                params["hotspots"] = json!(list);
            }
            params
        }
    };

    // The shim's 12 MB cap on serialized parameters.
    let size = params.to_string().len();
    if size > MAX_PARAMETERS {
        return Err(format!(
            "These inputs serialize to {:.1} MB; the service accepts at most {} MB.",
            size as f64 / 1e6,
            MAX_PARAMETERS / 1_000_000
        ));
    }
    Ok(params)
}

/// What was asked for, in one line, for a job list or a chat history: never the sequence or the structure
/// itself, only its size.
pub fn summarise(parameters: &Value) -> String {
    let Some(fields) = parameters.as_object() else { return String::new() };
    let mut parts = Vec::new();
    for (key, value) in fields {
        let part = match (key.as_str(), value) {
            ("sequence", Value::String(text)) => format!("{} residues", text.chars().count()),
            ("target_pdb", Value::String(text)) => format!("a target of {} atom records", text.lines().filter(|l| l.starts_with("ATOM  ")).count()),
            ("files", Value::Object(files)) => format!("attached {}", files.keys().cloned().collect::<Vec<_>>().join(", ")),
            ("input", value) => format!("input {}", value.to_string().chars().take(120).collect::<String>()),
            (key, Value::String(text)) => format!("{key} {text}"),
            (key, value) => format!("{key} {value}"),
        };
        parts.push(part);
    }
    parts.join(", ")
}

// MARK: - is this a protein at all?

/// A cheap sanity check on a returned structure.
///
/// A job can finish, report success and hand back a well-formed PDB that is nevertheless impossible: too few
/// sampling steps produces exactly that. Covalent geometry fixes the distance between consecutive alpha
/// carbons near 3.8 Å (2.9 for cis-proline), so a chain whose neighbours sit 10 Å apart is not a folded
/// protein. Passing says the backbone is connected, not that the prediction is right.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct StructureCheck {
    pub plausible: usize,
    pub bonds: usize,
    pub average: f64,
}

/// Trans peptide bonds give ~3.80 Å, cis-proline ~2.9. Outside this window, consecutive residues are not
/// bonded to each other at all.
pub const CA_MIN: f64 = 2.7;
pub const CA_MAX: f64 = 4.2;
/// Below this share of plausible bonds, something is wrong.
pub const PLAUSIBLE_SHARE: f64 = 0.9;

impl StructureCheck {
    pub fn share(&self) -> f64 {
        if self.bonds > 0 {
            self.plausible as f64 / self.bonds as f64
        } else {
            0.0
        }
    }

    /// Nothing measured is not a pass.
    pub fn plausible_structure(&self) -> bool {
        self.bonds > 0 && self.share() >= PLAUSIBLE_SHARE
    }

    pub fn text(&self) -> String {
        if self.bonds == 0 {
            return "No structure in the result could be measured.".into();
        }
        if self.plausible_structure() {
            format!(
                "The backbone is connected: {} of {} neighbouring alpha carbons are {:.2} Å apart on average, as \
                 chemistry requires. This says the chain is sound, not that the prediction is right.",
                self.plausible, self.bonds, self.average
            )
        } else {
            format!(
                "This is not a physically plausible structure: only {} of {} neighbouring alpha carbons are bonded, \
                 averaging {:.1} Å against the 3.8 Å chemistry allows. Too few sampling steps does this; the service \
                 reports such a job as a success.",
                self.plausible, self.bonds, self.average
            )
        }
    }
}

/// Measures one structure's backbone, chain by chain. Bonds are never counted across a jump between chains.
pub fn check_structure(text: &str) -> StructureCheck {
    let mut check = StructureCheck::default();
    let mut sum = 0.0;
    for (_, points) in alpha_carbons(text) {
        for pair in points.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            let distance = (((b[0] - a[0]).powi(2) + (b[1] - a[1]).powi(2) + (b[2] - a[2]).powi(2)) as f64).sqrt();
            check.bonds += 1;
            sum += distance;
            if (CA_MIN..=CA_MAX).contains(&distance) {
                check.plausible += 1;
            }
        }
    }
    if check.bonds > 0 {
        check.average = sum / check.bonds as f64;
    }
    check
}

/// Reads alpha-carbon traces out of PDB and mmCIF text, chain by chain in the order the chains appear.
///
/// These models emit a minimal mmCIF that stricter parsers reject, and predicted structures carry no HELIX or
/// SHEET records, so anything drawing them has to draw the backbone itself.
pub fn alpha_carbons(text: &str) -> Vec<(String, Vec<[f32; 3]>)> {
    let mut chains: Vec<(String, Vec<[f32; 3]>)> = Vec::new();
    let mut push = |chain: String, point: [f32; 3]| match chains.iter_mut().find(|(name, _)| *name == chain) {
        Some((_, points)) => points.push(point),
        None => chains.push((chain, vec![point])),
    };
    if text.contains("_atom_site.") {
        read_cif(text, &mut push);
    } else {
        read_pdb(text, &mut push);
    }
    chains
}

fn read_pdb(text: &str, push: &mut impl FnMut(String, [f32; 3])) {
    for line in text.lines() {
        if !line.starts_with("ATOM  ") && !line.starts_with("HETATM") {
            continue;
        }
        let characters: Vec<char> = line.chars().collect();
        if characters.len() < 54 {
            continue;
        }
        let field = |from: usize, to: usize| characters[from..to.min(characters.len())].iter().collect::<String>().trim().to_string();
        if field(12, 16) != "CA" {
            continue;
        }
        let (Ok(x), Ok(y), Ok(z)) = (field(30, 38).parse(), field(38, 46).parse(), field(46, 54).parse()) else { continue };
        let chain = field(21, 22);
        push(if chain.is_empty() { "A".into() } else { chain }, [x, y, z]);
    }
}

/// Minimal mmCIF reader: only the `_atom_site` loop, only CA rows.
fn read_cif(text: &str, push: &mut impl FnMut(String, [f32; 3])) {
    let mut columns: Vec<String> = Vec::new();
    let mut in_loop = false;
    for raw in text.lines() {
        let line = raw.trim();
        if let Some(name) = line.strip_prefix("_atom_site.") {
            columns.push(name.split_whitespace().next().unwrap_or_default().to_string());
            in_loop = true;
            continue;
        }
        if !in_loop {
            continue;
        }
        if line.is_empty() || line.starts_with('#') || line.starts_with("loop_") || line.starts_with('_') {
            if !columns.is_empty() {
                break;
            }
            continue;
        }
        let fields: Vec<&str> = line.split_whitespace().collect();
        let value = |names: &[&str]| -> Option<String> {
            names
                .iter()
                .find_map(|name| columns.iter().position(|column| column == name).and_then(|index| fields.get(index)))
                .map(|field| field.trim_matches('"').to_string())
        };
        if value(&["label_atom_id", "auth_atom_id"]).as_deref() != Some("CA") {
            continue;
        }
        let (Some(Ok(x)), Some(Ok(y)), Some(Ok(z))) = (
            value(&["Cartn_x"]).map(|v| v.parse()),
            value(&["Cartn_y"]).map(|v| v.parse()),
            value(&["Cartn_z"]).map(|v| v.parse()),
        ) else {
            continue;
        };
        push(value(&["auth_asym_id", "label_asym_id"]).unwrap_or_else(|| "A".into()), [x, y, z]);
    }
}

/// Whether a name in a result archive is a structure file.
pub fn is_structure_file(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    STRUCTURE_SUFFIXES.iter().any(|suffix| lower.ends_with(suffix))
}

#[cfg(test)]
mod tests {
    use super::*;

    // MARK: protocol

    #[test]
    fn input_is_a_json_string() {
        let action = submit_action("r1", &json!({ "sequence": "MKV" }));
        let body = request_body(Model::Esmfold2.alias(), &action);
        assert_eq!(body["model"], "alias-esmfold2");
        assert_eq!(body["stream"], false);
        // `input` is a string holding the action, never the action object itself.
        let input = body["input"].as_str().expect("input must be a JSON string");
        assert_eq!(serde_json::from_str::<Value>(input).unwrap(), action);
        assert_eq!(status_action("j")["action"], "status");
        assert_eq!(cancel_action("j")["action"], "cancel");
        assert_eq!(queue_action(), json!({ "action": "queue" }));
        assert_eq!(artifact_action("j", 2048), json!({ "action": "artifact", "job_id": "j", "offset": 2048, "length": CHUNK }));
    }

    #[test]
    fn reads_the_job_from_both_places() {
        let job = json!({ "id": "abc", "status": "queued" });
        assert_eq!(job_from(&json!({ "molecular_job": job.clone() })), Some(job.clone()));
        // The compatibility copy in output[0].content[0].text.
        let envelope = json!({ "output": [{ "content": [{ "text": job.to_string() }] }] });
        assert_eq!(job_from(&envelope), Some(job.clone()));
        assert_eq!(job_from(&json!({ "output": [{ "content": [{ "text": "not json" }] }] })), None);
        assert_eq!(job_from(&json!({ "status": "completed" })), None);
        assert_eq!(read_answer(200, &json!({ "molecular_job": job.clone() }).to_string()), Ok(job));
        // An HTML gateway error with a 200 is our problem, not the job's.
        assert!(read_answer(200, "<html>502</html>").unwrap_err().transient());
        assert_eq!(read_answer(200, "{}"), Err(Failure::Other("The answer held no molecular_job object.".into())));
    }

    #[test]
    fn maps_the_errors() {
        assert_eq!(Failure::from_status(404, "gone"), Failure::Gone);
        assert_eq!(Failure::from_status(429, ""), Failure::QueueFull);
        assert_eq!(Failure::from_status(503, ""), Failure::NotReady);
        assert_eq!(Failure::from_status(401, ""), Failure::KeyRejected);
        assert_eq!(Failure::from_status(403, ""), Failure::KeyRejected);
        assert_eq!(Failure::from_status(400, " nope "), Failure::Rejected("nope".into()));
        assert!(Failure::from_status(500, "").transient() && Failure::from_status(502, "").transient());
        assert!(Failure::from_status(429, "").transient() && Failure::from_status(503, "").transient());
        assert!(!Failure::from_status(418, "").transient());
        assert!(!Failure::from_status(404, "").transient() && !Failure::from_status(400, "").transient());
        // A network failure is never evidence that the computation failed.
        assert!(Failure::network("connection reset").transient());
    }

    // MARK: artifacts

    fn chunk(total: usize, bytes: &[u8]) -> Value {
        json!({ "total_bytes": total, "data_base64": base64::engine::general_purpose::STANDARD.encode(bytes) })
    }

    #[test]
    fn reassembles_by_decoded_bytes() {
        let whole: Vec<u8> = (0..300u32).map(|i| (i % 251) as u8).collect();
        let mut download = Download::default();
        assert_eq!(download.offset(), 0);
        assert!(!download.done());
        for piece in whole.chunks(100) {
            assert_eq!(download.action("j")["offset"], download.offset());
            download.take(&chunk(whole.len(), piece)).unwrap();
        }
        // The offset moved by decoded bytes, not by the length of the base64 text.
        assert_eq!(download.offset(), whole.len());
        assert!(download.done());
        assert_eq!(download.finish(), whole);
    }

    #[test]
    fn a_partial_download_is_never_complete() {
        let mut download = Download::default();
        download.take(&chunk(500, &[7u8; 100])).unwrap();
        assert_eq!(download.offset(), 100);
        assert!(!download.done());
        // An empty or unreadable chunk is a failure, not an end.
        assert!(download.take(&chunk(500, &[])).is_err());
        assert!(download.take(&json!({ "total_bytes": 500 })).is_err());
        assert!(download.take(&json!({ "data_base64": "!!!" })).is_err());
        assert!(!download.done());
        assert_eq!(download.offset(), 100);
        // Retries wait, but never longer than half a minute.
        assert!((1..=30.0 as u64).contains(&(Download::backoff(1, 0.0) as u64 + 1)));
        assert!(Download::backoff(10, 1.0) <= 30.0);
    }

    #[test]
    fn refuses_an_empty_or_huge_result() {
        assert!(Download::default().take(&chunk(0, b"x")).is_err());
        assert_eq!(
            Download::default().take(&json!({ "total_bytes": MAX_ARTIFACT + 1, "data_base64": "eA==" })),
            Err(Failure::TooLarge(MAX_ARTIFACT + 1))
        );
    }

    // MARK: progress

    #[test]
    fn reads_what_the_shim_says_and_nothing_more() {
        let queued = Progress::parse(&json!({ "id": "abc123", "status": "queued", "queue_position": 3,
                                              "waiting_reason": "gpu", "poll_after_seconds": 2 }));
        assert_eq!(queued.id.as_deref(), Some("abc123"));
        assert_eq!(queued.state, Some(State::Queued));
        assert_eq!(queued.queue_position, Some(3));
        // Never faster than the floor, whatever the service asks for.
        assert_eq!(queued.poll_after, MINIMUM_POLL);

        let running = Progress::parse(&json!({ "status": "running", "poll_after_seconds": 45, "usage": { "gpu_seconds": 12.5 } }));
        // Queue positions are only meaningful while queued.
        assert_eq!(running.queue_position, None);
        assert_eq!(running.waiting_reason, "");
        assert_eq!(running.poll_after, 45.0);
        assert_eq!(running.gpu_seconds, Some(12.5));
        assert!(Progress::parse(&json!({ "status": "nonsense" })).state.is_none());
        assert_eq!(Progress::parse(&json!({ "error": { "code": 7 } })).error, "{\"code\":7}");
    }

    #[test]
    fn says_nothing_about_percentages_or_etas() {
        for state in [State::Queued, State::Running, State::Cancelling, State::Completed, State::Failed, State::Cancelled] {
            let text = progress_text(state, "", "", None, "");
            assert!(!text.contains('%') && !text.to_lowercase().contains("eta"), "{text}");
        }
        // A queue position is an order, and cancelling is a race.
        assert!(progress_text(State::Queued, "", "", Some(4), "").contains("order, not a promise"));
        assert!(progress_text(State::Cancelling, "", "", None, "").contains("may still finish"));
        assert!(progress_text(State::Running, "", "", None, "").contains("no estimate"));
        assert_eq!(progress_text(State::Running, "folding", "", None, ""), "folding");
        assert!(queue_text(&json!({ "queued": 2, "running": 1 })).contains("not a start time"));
        assert!(State::Completed.finished() && !State::Running.finished());
    }

    // MARK: validation

    #[test]
    fn validates_sequences() {
        assert_eq!(sequence(">sp|P0|test\nmkv wat\nGGG\n").unwrap(), "MKVWATGGG");
        assert_eq!(sequence("  ").unwrap_err(), "No sequence found.");
        assert!(sequence("MKVZ1").unwrap_err().contains("1, Z"));
        assert!(sequence(&"A".repeat(MAX_SEQUENCE + 1)).unwrap_err().contains("residues"));
        assert_eq!(sequence(&"A".repeat(MAX_SEQUENCE)).unwrap().len(), MAX_SEQUENCE);
    }

    #[test]
    fn validates_the_small_fields() {
        assert!(is_structure("HEADER x\nATOM      1  N   MET A   1      1.0   2.0   3.0"));
        assert!(!is_structure("HEADER x\nnothing here"));
        assert!(is_residue_selection("A1-76") && is_residue_selection("B20-140"));
        assert!(!is_residue_selection("A") && !is_residue_selection("1-76") && !is_residue_selection("A1-"));
        assert!(is_chains("A") && is_chains("A,B"));
        assert!(!is_chains("") && !is_chains("A,") && !is_chains("A B"));
        assert!(is_length("45") && is_length("40-50") && !is_length("forty") && !is_length("40-"));
        assert!(is_filename("target.pdb") && !is_filename("../etc/passwd") && !is_filename(""));
        assert!(is_structure_file("out/design.cif.gz") && !is_structure_file("report.txt"));
    }

    #[test]
    fn esmfold2_refuses_too_few_steps_with_too_few_loops() {
        let mut form = Form::new(Model::Esmfold2);
        form.sequence = "MKVLY".into();
        assert_eq!(parameters(Model::Esmfold2, &form).unwrap(), json!({ "sequence": "MKVLY", "num_loops": 3, "steps": 50 }));
        form.steps = 10;
        form.num_loops = 1;
        assert!(parameters(Model::Esmfold2, &form).unwrap_err().contains("not physically foldable"));
        // Either side of the pair is enough.
        form.num_loops = 2;
        assert!(parameters(Model::Esmfold2, &form).is_ok());
        form.num_loops = 1;
        form.steps = 25;
        assert!(parameters(Model::Esmfold2, &form).is_ok());
        form.steps = 1001;
        assert!(parameters(Model::Esmfold2, &form).is_err());
    }

    #[test]
    fn bioemu2_says_its_msa_mode_and_seed() {
        let mut form = Form::new(Model::Bioemu2);
        form.sequence = "MKVLY".into();
        let params = parameters(Model::Bioemu2, &form).unwrap();
        assert_eq!(params["msa_mode"], "single_sequence");
        assert_eq!(params["seed"], 42);
        form.use_seed = false;
        assert!(parameters(Model::Bioemu2, &form).unwrap().get("seed").is_none());
        form.samples = 129;
        assert!(parameters(Model::Bioemu2, &form).is_err());
    }

    #[test]
    fn rfdiffusion3_has_two_modes() {
        let mut form = Form::new(Model::Rfdiffusion3);
        assert_eq!(parameters(Model::Rfdiffusion3, &form).unwrap()["input"]["api"]["length"], "40-50");
        form.length = "prompt".into();
        assert!(parameters(Model::Rfdiffusion3, &form).is_err());
        form.mode = Mode::Advanced;
        form.rfd3_input = "design me a protein".into();
        assert!(parameters(Model::Rfdiffusion3, &form).unwrap_err().contains("Not valid JSON"));
        form.rfd3_input = "[1, 2]".into();
        assert!(parameters(Model::Rfdiffusion3, &form).unwrap_err().contains("JSON object"));
        form.rfd3_input = r#"{"api": {"length": "60"}}"#.into();
        let params = parameters(Model::Rfdiffusion3, &form).unwrap();
        assert_eq!(params["input"]["api"]["length"], "60");
        assert!(params.get("files").is_none());
        // An attachment is a filename, never a path.
        form.attachment = "ATOM  ".into();
        form.attachment_name = "../target.pdb".into();
        assert!(parameters(Model::Rfdiffusion3, &form).is_err());
        form.attachment_name = "target.pdb".into();
        assert_eq!(parameters(Model::Rfdiffusion3, &form).unwrap()["files"]["target.pdb"], "ATOM  ");
    }

    #[test]
    fn the_two_binder_models_differ() {
        let pdb = "ATOM      1  CA  MET A   1       0.000   0.000   0.000\n";
        let mut bind = Form::new(Model::Bindcraft);
        bind.target_pdb = pdb.into();
        bind.hotspots = "A30,A33".into();
        let params = parameters(Model::Bindcraft, &bind).unwrap();
        // BindCraft takes its own hotspot string; Complexa takes a list.
        assert_eq!(params["hotspots"], "A30,A33");
        assert_eq!(params["binder_length"], json!([60, 100]));
        assert_eq!(params["walltime_seconds"], 24 * 3600);
        assert!(params.get("target_input").is_none());
        bind.binder_min = 200;
        assert!(parameters(Model::Bindcraft, &bind).is_err());

        let mut complexa = Form::new(Model::ProteinaComplexa);
        complexa.target_pdb = pdb.into();
        complexa.hotspots = "A30, A33".into();
        // The target selection is required and never defaulted to the ubiquitin canary.
        assert!(parameters(Model::ProteinaComplexa, &complexa).unwrap_err().contains("required"));
        complexa.target_input = "B20-140".into();
        let params = parameters(Model::ProteinaComplexa, &complexa).unwrap();
        assert_eq!(params["hotspots"], json!(["A30", "A33"]));
        assert_eq!(params["target_input"], "B20-140");
        assert_eq!(params["steps"], 400);
        assert_eq!(params["seed"], 42);
        complexa.target_input = "nonsense".into();
        assert!(parameters(Model::ProteinaComplexa, &complexa).is_err());
    }

    #[test]
    fn a_target_must_look_like_a_pdb() {
        let mut form = Form::new(Model::Bindcraft);
        assert!(parameters(Model::Bindcraft, &form).unwrap_err().contains("Choose a target"));
        form.target_pdb = "hello".into();
        assert!(parameters(Model::Bindcraft, &form).unwrap_err().contains("ATOM"));
    }

    #[test]
    fn a_summary_never_repeats_the_sequence() {
        let summary = summarise(&json!({ "sequence": "MKVLY", "steps": 50, "num_loops": 3 }));
        assert!(!summary.contains("MKVLY"));
        assert!(summary.contains("5 residues") && summary.contains("steps 50"));
    }

    // MARK: structures

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
    fn measures_the_backbone() {
        let good = check_structure(&pdb(3.8, 10));
        assert_eq!((good.bonds, good.plausible), (9, 9));
        assert!(good.plausible_structure() && (good.average - 3.8).abs() < 1e-3);
        // Too few sampling steps gives exactly this: a well-formed file that is not a folded protein.
        let bad = check_structure(&pdb(10.0, 10));
        assert_eq!((bad.bonds, bad.plausible), (9, 0));
        assert!(!bad.plausible_structure());
        assert!(bad.text().contains("not a physically plausible structure"));
        // Nothing to measure is not a pass.
        let empty = check_structure("HEADER nothing");
        assert!(!empty.plausible_structure() && empty.bonds == 0);
        assert!(empty.text().contains("No structure in the result could be measured"));
        // The edges of the window chemistry allows.
        assert!(check_structure(&pdb(CA_MIN, 3)).plausible_structure());
        assert!(check_structure(&pdb(CA_MAX, 3)).plausible_structure());
        assert!(!check_structure(&pdb(CA_MAX + 0.1, 3)).plausible_structure());
    }

    #[test]
    fn reads_chains_and_minimal_mmcif() {
        let two = format!("{}\n{}", pdb(3.8, 3), pdb(3.8, 3).replace(" A", " B"));
        let chains = alpha_carbons(&two);
        assert_eq!(chains.len(), 2);
        assert_eq!(chains[0].0, "A");
        assert_eq!(chains[0].1.len(), 3);
        // Bonds are counted within a chain, never across the jump between two.
        assert_eq!(check_structure(&two).bonds, 4);

        let cif = "data_x\nloop_\n_atom_site.group_PDB\n_atom_site.label_atom_id\n_atom_site.label_comp_id\n\
                   _atom_site.Cartn_x\n_atom_site.Cartn_y\n_atom_site.Cartn_z\n_atom_site.auth_asym_id\n\
                   ATOM CA ALA 0.000 0.000 0.000 C\nATOM N ALA 1.000 0.000 0.000 C\nATOM CA ALA 3.800 0.000 0.000 C\n#\n";
        let chains = alpha_carbons(cif);
        assert_eq!(chains, vec![("C".to_string(), vec![[0.0, 0.0, 0.0], [3.8, 0.0, 0.0]])]);
        assert!(check_structure(cif).plausible_structure());
    }

    #[test]
    fn the_aliases_match_the_model_table() {
        let aliases: Vec<&str> = Model::ALL.iter().map(|model| model.alias()).collect();
        assert_eq!(aliases, crate::MOLECULAR_MODELS.to_vec());
        for model in Model::ALL {
            // None of the five may ever be offered as a chat model, in the app or in bla.
            assert!(!crate::is_chat_capable(model.alias()), "{}", model.alias());
            assert_eq!(Model::from_alias(model.alias()), Some(model));
            assert!(!model.name().is_empty() && !model.blurb().is_empty() && !model.caveats().is_empty());
        }
        assert_eq!(Model::from_alias("alias-fast"), None);
    }
}
