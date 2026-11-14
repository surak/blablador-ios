//! Blablador's other models, as tools: looking at a picture with a vision model, OCR, making images, and
//! transcribing audio. The system prompt says which model does what, so the agent uses these instead of
//! installing or writing its own OCR, image or speech tools.

use crate::plugin::{Kind, Plugin, Session, Tool, ToolCtx, ToolOutput};
use base64::Engine;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use blablador_models::{OCR_MODEL, TRANSCRIPTION_MODEL};
/// Sees images: Blablador's default chat model.
const VISION_MODEL: &str = blablador_models::DEFAULT_MODEL;
const IMAGE_MODEL: &str = blablador_models::IMAGE_MODELS[0];
const MAX_INPUT: u64 = 25_000_000;

const GUIDE: &str = "Blablador's models and what to use them for (call the tools; never install OCR, image or speech software or write your own):\n\
- Pictures (photos, screenshots, diagrams, charts, scans): look_at_image, which sends the file to a vision model with your question. Use it whenever you need to see or describe an image.\n\
- The exact text of a scanned page or photo of a document: ocr_image (alias-ocr, LightOnOCR). Only when the user wants the text itself transcribed; for anything else use look_at_image.\n\
- Making a picture: generate_image (alias-flux2, FLUX.2).\n\
- Speech in an audio or video file to text: transcribe_audio (Whisper large-v3).\n\
- Text in PDFs: read them with bash (pdftotext) when it is installed; for scanned PDFs turn pages into images and use ocr_image.\n\
- blablador_models lists every model Blablador serves now with what it is for; check it before saying Blablador can't do something.";

#[derive(Clone)]
struct Api {
    endpoint: String,
    key: String,
    agent: ureq::Agent,
}

impl Api {
    fn post_json(&self, path: &str, body: &Value) -> Result<Value, String> {
        self.check()?;
        let r = self.agent.post(&format!("{}/{path}", self.endpoint)).set("Authorization", &format!("Bearer {}", self.key)).set("Content-Type", "application/json");
        answer(r.send_string(&body.to_string()))
    }

    fn post_multipart(&self, path: &str, fields: &[(&str, &str)], file: (&str, &str, &[u8])) -> Result<Value, String> {
        self.check()?;
        let boundary = format!("bla-{}", crate::util::random_hex(16));
        let mut body = Vec::new();
        for (name, value) in fields {
            body.extend(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
        }
        let (name, filename, data) = file;
        body.extend(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n").as_bytes());
        body.extend(data);
        body.extend(format!("\r\n--{boundary}--\r\n").as_bytes());
        let r = self
            .agent
            .post(&format!("{}/{path}", self.endpoint))
            .set("Authorization", &format!("Bearer {}", self.key))
            .set("Content-Type", &format!("multipart/form-data; boundary={boundary}"));
        answer(r.send_bytes(&body))
    }

    fn get_json(&self, url: &str, auth: bool) -> Result<Value, String> {
        let mut r = self.agent.get(url).timeout(Duration::from_secs(15));
        if auth {
            self.check()?;
            r = r.set("Authorization", &format!("Bearer {}", self.key));
        }
        answer(r.call())
    }

    fn get_text(&self, url: &str) -> Result<String, String> {
        self.agent.get(url).timeout(Duration::from_secs(15)).call().map_err(|e| e.to_string())?.into_string().map_err(|e| e.to_string())
    }

    fn check(&self) -> Result<(), String> {
        if self.key.is_empty() {
            return Err("No API key. Run `bla login`.".into());
        }
        Ok(())
    }

    /// A chat completion with one image; the answer's text.
    fn ask_image(&self, model: &str, prompt: Option<&str>, image: &str) -> Result<String, String> {
        let mut content = Vec::new();
        if let Some(p) = prompt {
            content.push(json!({"type": "text", "text": p}));
        }
        content.push(json!({"type": "image_url", "image_url": {"url": image}}));
        let v = self.post_json("chat/completions", &json!({"model": model, "messages": [{"role": "user", "content": content}], "max_tokens": 4096, "temperature": 0}))?;
        Ok(v["choices"][0]["message"]["content"].as_str().unwrap_or_default().trim().to_string())
    }
}

fn answer(result: Result<ureq::Response, ureq::Error>) -> Result<Value, String> {
    match result {
        Ok(r) => r.into_json().map_err(|e| e.to_string()),
        Err(ureq::Error::Status(code, r)) => {
            let text = r.into_string().unwrap_or_default();
            let message = serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|v| v["error"]["message"].as_str().or(v["detail"].as_str()).map(String::from))
                .unwrap_or_else(|| crate::util::clip(&text, 300).to_string());
            Err(format!("HTTP {code}: {message}"))
        }
        Err(e) => Err(e.to_string()),
    }
}

fn read_input(ctx: &ToolCtx, given: &str) -> Result<(std::path::PathBuf, Vec<u8>), String> {
    let path = crate::util::resolve(ctx.cwd, given);
    let size = std::fs::metadata(&path).map_err(|e| format!("{given}: {e}"))?.len();
    if size > MAX_INPUT {
        return Err(format!("{given} is {} MB; the limit is 25 MB.", size / 1_000_000));
    }
    Ok((path.clone(), std::fs::read(&path).map_err(|e| format!("{given}: {e}"))?))
}

/// The image as a data URL, by its first bytes.
fn data_url(bytes: &[u8]) -> Result<String, String> {
    let mime = if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png"
    } else if bytes.starts_with(&[0xff, 0xd8]) {
        "image/jpeg"
    } else if bytes.starts_with(b"GIF8") {
        "image/gif"
    } else if bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        "image/webp"
    } else {
        return Err("Not a PNG, JPEG, GIF or WebP image. Convert it first (sips on the Mac, or ImageMagick).".into());
    };
    Ok(format!("data:{mime};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes)))
}

fn path_arg(args: &Value) -> Option<String> {
    args["path"].as_str().map(String::from)
}

struct LookAtImage {
    api: Api,
    model: String,
}

impl Tool for LookAtImage {
    fn name(&self) -> &str {
        "look_at_image"
    }
    fn description(&self) -> &str {
        "See a picture (PNG, JPEG, GIF, WebP): sends it to a Blablador vision model with your question and returns what it sees. \
         Use for photos, screenshots, diagrams, charts and plots."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "path": {"type": "string", "description": "The image file"},
            "question": {"type": "string", "description": "What to look for; default: describe it in detail"}
        }, "required": ["path"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Read
    }
    fn subject(&self, args: &Value) -> Option<String> {
        path_arg(args)
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(given) = path_arg(args) else { return ToolOutput::err("Give path.") };
        let question = args["question"].as_str().filter(|q| !q.trim().is_empty()).unwrap_or("Describe this image in detail, including any text in it.");
        let result = read_input(ctx, &given).and_then(|(_, bytes)| data_url(&bytes)).and_then(|url| {
            // The chat's model when it can see; otherwise Blablador's vision default.
            self.api.ask_image(&self.model, Some(question), &url).or_else(|e| if self.model != VISION_MODEL { self.api.ask_image(VISION_MODEL, Some(question), &url) } else { Err(e) })
        });
        match result {
            Ok(text) => ToolOutput::ok(text),
            Err(e) => ToolOutput::err(e),
        }
    }
}

struct OcrImage {
    api: Api,
}

impl Tool for OcrImage {
    fn name(&self) -> &str {
        "ocr_image"
    }
    fn description(&self) -> &str {
        "Transcribe the text of a scanned page or a photo of a document with Blablador's OCR model (alias-ocr); tables come back \
         as HTML. Only when the exact text is wanted; to understand a picture use look_at_image."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"path": {"type": "string", "description": "The image file"}}, "required": ["path"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Read
    }
    fn subject(&self, args: &Value) -> Option<String> {
        path_arg(args)
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(given) = path_arg(args) else { return ToolOutput::err("Give path.") };
        match read_input(ctx, &given).and_then(|(_, bytes)| data_url(&bytes)).and_then(|url| self.api.ask_image(OCR_MODEL, None, &url)) {
            Ok(text) => ToolOutput::ok(text),
            Err(e) => ToolOutput::err(e),
        }
    }
}

struct GenerateImage {
    api: Api,
}

impl Tool for GenerateImage {
    fn name(&self) -> &str {
        "generate_image"
    }
    fn description(&self) -> &str {
        "Make a picture from a description with Blablador's image model (alias-flux2, FLUX.2) and save it as a PNG file."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "prompt": {"type": "string", "description": "What the picture shows, in detail"},
            "path": {"type": "string", "description": "Where to save the PNG"},
            "size": {"type": "string", "description": "WIDTHxHEIGHT, default 1024x1024"}
        }, "required": ["prompt", "path"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Write
    }
    fn subject(&self, args: &Value) -> Option<String> {
        path_arg(args)
    }
    fn summary(&self, args: &Value) -> String {
        format!("{} ← {}", args["path"].as_str().unwrap_or_default(), crate::util::clip(args["prompt"].as_str().unwrap_or_default(), 80))
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let (Some(given), Some(prompt)) = (path_arg(args), args["prompt"].as_str()) else { return ToolOutput::err("Give prompt and path.") };
        let size = args["size"].as_str().unwrap_or("1024x1024");
        let result = self.api.post_json("images/generations", &json!({"model": IMAGE_MODEL, "prompt": prompt, "n": 1, "size": size})).and_then(|v| {
            let encoded = v["data"][0]["b64_json"].as_str().ok_or("No image in the answer.")?;
            let bytes = base64::engine::general_purpose::STANDARD.decode(encoded).map_err(|e| e.to_string())?;
            let path = crate::util::resolve(ctx.cwd, &given);
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            std::fs::write(&path, &bytes).map_err(|e| format!("{given}: {e}"))?;
            Ok(format!("Saved {given} ({} KB).", bytes.len() / 1000))
        });
        match result {
            Ok(text) => ToolOutput::ok(text),
            Err(e) => ToolOutput::err(e),
        }
    }
}

struct TranscribeAudio {
    api: Api,
}

impl Tool for TranscribeAudio {
    fn name(&self) -> &str {
        "transcribe_audio"
    }
    fn description(&self) -> &str {
        "Turn speech in an audio or video file (wav, mp3, m4a, ogg, flac, mp4…) into text with Blablador's Whisper large-v3."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "path": {"type": "string"},
            "language": {"type": "string", "description": "ISO code such as en or de; default: detected"}
        }, "required": ["path"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Read
    }
    fn subject(&self, args: &Value) -> Option<String> {
        path_arg(args)
    }
    fn run(&self, args: &Value, ctx: &ToolCtx) -> ToolOutput {
        let Some(given) = path_arg(args) else { return ToolOutput::err("Give path.") };
        let result = read_input(ctx, &given).and_then(|(path, bytes)| {
            let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "audio.wav".into());
            let mut fields = vec![("model", TRANSCRIPTION_MODEL)];
            if let Some(l) = args["language"].as_str().filter(|l| !l.is_empty()) {
                fields.push(("language", l));
            }
            let v = self.api.post_multipart("audio/transcriptions", &fields, ("file", &name, &bytes))?;
            Ok(v["text"].as_str().unwrap_or_default().trim().to_string())
        });
        match result {
            Ok(text) => ToolOutput::ok(text),
            Err(e) => ToolOutput::err(e),
        }
    }
}


/// What bla knows without looking anything up.
const KNOWN: &[(&str, &str)] = &[
    ("alias-ocr", "OCR (LightOnOCR): the text of a scanned page or document photo; use ocr_image"),
    ("alias-flux2", "image generation (FLUX.2-dev); use generate_image"),
    ("alias-image", "image generation and editing (Qwen-Image 2.1)"),
    ("faster-whisper-large-v3", "transcription of speech (Whisper large-v3); use transcribe_audio"),
    ("alias-voice-drama3", "speech synthesis and voice cloning (Drama 3), /audio/speech; not chat"),
    ("alias-video", "video with sound from text or a first frame (MiniMax-H3), /videos/sync; not chat"),
    ("alias-visual-geometry", "3D reconstruction of rooms from photos (VGGT-Omega); commands, not chat"),
    ("vggt-omega-1b", "3D reconstruction of rooms from photos (VGGT-Omega); commands, not chat"),
    ("alias-clef", "decision model (Clef), /systemone; not chat"),
    ("alias-qwen3-4b-embeddings", "embeddings for search (Qwen3 4B)"),
    ("alias-qwen3-4b-reranker", "reranker for search results (Qwen3 4B)"),
    ("alias-esmfold2", "protein structure prediction job queue (ESMFold 2) via /responses actions; not chat"),
    ("alias-bioemu2", "protein conformation sampling job queue (BioEmu 2) via /responses actions; not chat"),
    ("alias-rfdiffusion3", "protein design job queue (RFdiffusion 3) via /responses actions; not chat"),
    ("alias-bindcraft", "protein binder design job queue (BindCraft) via /responses actions; not chat"),
    ("alias-proteina-complexa", "protein complex design job queue (Proteina) via /responses actions; not chat"),
    ("deepseek-v4.1-flash-at-hzdr", "vision chat, bla's default (DeepSeek-V4.1-Flash)"),
];
/// New models described per check, so a start never waits long.
const LOOKUPS_PER_CHECK: usize = 12;
const SEARCH: &str = "https://search.blablador.fz-juelich.de/search";

/// Every model Blablador serves, with a line on what it is for, kept in `~/.bla/models.json`. Models that
/// appear are looked up (Hugging Face, else a web search) and described by the helper model.
pub struct Catalog {
    api: Api,
    file: PathBuf,
    entries: Mutex<BTreeMap<String, Value>>,
}

fn encode(text: &str) -> String {
    text.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

impl Catalog {
    fn new(api: Api, file: PathBuf) -> Catalog {
        let entries = std::fs::read(&file).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        Catalog { api, file, entries: Mutex::new(entries) }
    }

    fn save(&self) {
        let text = serde_json::to_string_pretty(&*self.entries.lock().unwrap()).unwrap_or_default();
        if let Some(dir) = self.file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(&self.file, text);
    }

    /// Lists the models, marks gone ones, and describes up to `limit` new ones.
    pub fn refresh(&self, limit: usize) -> Result<(), String> {
        let v = self.api.get_json(&format!("{}/models", self.api.endpoint), true)?;
        let served: Vec<(String, String)> = v["data"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|m| Some((m["id"].as_str()?.to_string(), m["root"].as_str().unwrap_or_default().to_string())))
            .collect();
        {
            let mut entries = self.entries.lock().unwrap();
            for (id, e) in entries.iter_mut() {
                e["served"] = Value::from(served.iter().any(|(s, _)| s == id));
            }
        }
        let mut looked = 0;
        for (id, root) in &served {
            let known = self.entries.lock().unwrap().get(id).is_some_and(|e| e["about"].as_str().is_some_and(|a| !a.is_empty()));
            if known {
                continue;
            }
            // Names served from the same weights share a description.
            let sibling = (!root.is_empty())
                .then(|| self.entries.lock().unwrap().values().find(|e| e["root"].as_str() == Some(root.as_str())).and_then(|e| e["about"].as_str().map(String::from)))
                .flatten();
            let about = match KNOWN.iter().find(|(k, _)| k == id) {
                Some((_, about)) => about.to_string(),
                None if sibling.is_some() => sibling.unwrap_or_default(),
                None if looked < limit => {
                    looked += 1;
                    match self.describe(id, root) {
                        Ok(a) => a,
                        Err(_) => continue,
                    }
                }
                None => continue,
            };
            self.entries.lock().unwrap().insert(id.clone(), json!({"root": root, "about": about, "served": true, "seen": crate::util::today()}));
            self.save();
        }
        self.save();
        Ok(())
    }

    /// What a model is, from its Hugging Face card or a web search, in one line by the helper model.
    fn describe(&self, id: &str, root: &str) -> Result<String, String> {
        let mut notes = format!("Model id on Blablador: {id}\nServed from: {root}\n");
        let repo = root.trim_matches('/');
        if root.contains('/') && !root.starts_with('/') && repo.split('/').count() == 2 {
            if let Ok(info) = self.api.get_json(&format!("https://huggingface.co/api/models/{repo}"), false) {
                notes.push_str(&format!("Hugging Face task: {}\nTags: {}\n", info["pipeline_tag"].as_str().unwrap_or("?"), info["tags"].as_array().map(|t| t.iter().take(20).filter_map(|x| x.as_str()).collect::<Vec<_>>().join(", ")).unwrap_or_default()));
            }
            if let Ok(card) = self.api.get_text(&format!("https://huggingface.co/{repo}/raw/main/README.md")) {
                notes.push_str(&format!("Model card:\n{}\n", crate::util::clip(&card, 2500)));
            }
        }
        if !notes.contains("Model card") {
            let name = id.trim_start_matches(|c: char| c.is_ascii_digit() || c == ' ' || c == '-').trim_start_matches("alias-");
            let query = format!("{} AI model", crate::util::clip(name, 80));
            if let Ok(found) = self.api.get_json(&format!("{SEARCH}?q={}&format=json", encode(&query)), false) {
                for r in found["results"].as_array().into_iter().flatten().take(4) {
                    notes.push_str(&format!("- {}: {}\n", r["title"].as_str().unwrap_or_default(), crate::util::clip(r["content"].as_str().unwrap_or_default(), 300)));
                }
            }
        }
        let prompt = "From these notes, say in one line (at most 25 words) what this model is and what to use it for. Start with its kind: chat, vision chat, code, reasoning, embeddings, reranker, image generation, speech, transcription, OCR, video, job API (not chat) or other. Say \"not chat\" when it can't hold a conversation. No preamble.";
        let v = self.api.post_json("chat/completions", &json!({"model": "alias-fast", "messages": [{"role": "system", "content": prompt}, {"role": "user", "content": notes}], "max_tokens": 2000, "reasoning_effort": "low", "temperature": 0}))?;
        let line = v["choices"][0]["message"]["content"].as_str().unwrap_or_default().trim().lines().next().unwrap_or_default().trim().to_string();
        if line.is_empty() {
            return Err("no answer".into());
        }
        Ok(line)
    }

    /// The served models, those with the same weights on one line.
    pub fn listing(&self) -> String {
        let entries = self.entries.lock().unwrap();
        let mut by_about: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let mut unknown = Vec::new();
        for (id, e) in entries.iter().filter(|(_, e)| e["served"].as_bool() != Some(false)) {
            match e["about"].as_str().filter(|a| !a.is_empty()) {
                Some(about) => {
                    let key = format!("{}\u{0}{about}", e["root"].as_str().filter(|r| !r.is_empty() && !r.starts_with('/')).unwrap_or(id));
                    by_about.entry(key).or_default().push(id.clone());
                }
                None => unknown.push(id.clone()),
            }
        }
        let mut lines: Vec<String> = by_about.into_iter().map(|(k, ids)| format!("- {}: {}", ids.join(", "), k.split('\u{0}').nth(1).unwrap_or_default())).collect();
        if !unknown.is_empty() {
            lines.push(format!("- not described yet: {}", unknown.join(", ")));
        }
        lines.join("\n")
    }
}

struct ModelsTool {
    catalog: Arc<Catalog>,
}

impl Tool for ModelsTool {
    fn name(&self) -> &str {
        "blablador_models"
    }
    fn description(&self) -> &str {
        "List every model Blablador serves now and what each is for (new ones are looked up first)."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {}})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Read
    }
    fn run(&self, _args: &Value, _ctx: &ToolCtx) -> ToolOutput {
        let note = self.catalog.refresh(6).err().map(|e| format!("(Couldn't check the list now: {e}; this is the last one known.)\n")).unwrap_or_default();
        ToolOutput::ok(format!("{note}{}", self.catalog.listing()))
    }
}

pub struct Blablador {
    tools: Vec<Arc<dyn Tool>>,
    catalog: Arc<Catalog>,
}

impl Blablador {
    pub fn new(endpoint: &str, key: String, model: &str) -> Blablador {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(20))
            .timeout_read(Duration::from_secs(600))
            .user_agent(concat!("bla/", env!("CARGO_PKG_VERSION")))
            .build();
        let api = Api { endpoint: endpoint.trim_end_matches('/').to_string(), key, agent };
        let catalog = Arc::new(Catalog::new(api.clone(), crate::util::bla_home().join("models.json")));
        Blablador {
            catalog: catalog.clone(),
            tools: vec![
                Arc::new(ModelsTool { catalog }),
                Arc::new(LookAtImage { api: api.clone(), model: model.to_string() }),
                Arc::new(OcrImage { api: api.clone() }),
                Arc::new(GenerateImage { api: api.clone() }),
                Arc::new(TranscribeAudio { api }),
            ],
        }
    }
}

impl Plugin for Blablador {
    fn name(&self) -> &str {
        "blablador"
    }
    fn description(&self) -> &str {
        "Blablador's other models as tools: vision, OCR, image generation, transcription"
    }
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        self.tools.clone()
    }
    /// Checks the model list in the background; what it learns is in the next session's prompt and in blablador_models.
    fn session_start(&self, _session: &Session) {
        let catalog = self.catalog.clone();
        std::thread::spawn(move || {
            let _ = catalog.refresh(LOOKUPS_PER_CHECK);
        });
    }
    fn system_prompt(&self, _session: &Session, sections: &mut Vec<String>) {
        let listing = self.catalog.listing();
        if listing.is_empty() {
            sections.push(GUIDE.to_string());
        } else {
            sections.push(format!("{GUIDE}\n\nModels on Blablador (from the last check):\n{listing}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_images() {
        assert!(data_url(&[0x89, b'P', b'N', b'G', 0, 0]).unwrap().starts_with("data:image/png;base64,"));
        assert!(data_url(&[0xff, 0xd8, 0xff]).unwrap().starts_with("data:image/jpeg"));
        assert!(data_url(b"%PDF-1.4").is_err());
    }
}
