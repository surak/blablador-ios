//! Talking with bla: the microphone, Whisper, Drama 3, and the guards that keep the agent from
//! answering its own voice.
//!
//! The same shape as the apps' `VoiceConversation`: one thread listens and decides where a turn
//! ends from loudness alone, another speaks the reply sentence by sentence while it still streams.
//! The terminal has no echo cancellation, so the microphone hears the loudspeaker: a turn that
//! arrives less than `AFTER_SPEAKING` after we stopped, or whose words are mostly words we just
//! said, is our own voice coming back and is dropped. Interrupting on purpose takes a stop word or
//! three words we did not say, which is why even barge-in goes through Whisper first.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use serde_json::json;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// What Whisper wants, and what we resample the microphone to.
const WHISPER_RATE: u32 = 16_000;
/// Silence that ends a turn.
const SILENCE: Duration = Duration::from_millis(800);
/// Anything shorter is a cough, a key press or a door.
const MIN_SPEECH: Duration = Duration::from_millis(300);
/// A turn is sent at this length even if the speaker hasn't paused.
const MAX_SPEECH: Duration = Duration::from_secs(30);
/// Kept before the moment speech was noticed, so a turn doesn't lose its first syllable.
const PREROLL: Duration = Duration::from_millis(300);
/// After we stop speaking the room still rings; ignore what the microphone hears until then.
const AFTER_SPEAKING: Duration = Duration::from_millis(1200);
/// A turn whose words are at least this share words we just said is the loudspeaker, not a person.
const ECHO_SHARE: f32 = 0.6;
/// Words we did not say that it takes to cut the reply off.
const BARGE_WORDS: usize = 3;
/// How much of what we said is kept for the echo test.
const SPOKEN_MEMORY: usize = 400;
/// One frame of sound for the loudness test.
const FRAME: usize = (WHISPER_RATE as usize) / 50;
/// Never ask Drama 3 for more than this at once.
const MAX_SPOKEN: usize = 1000;

/// Said alone, these stop the reply and nothing else. The apps' list, in the languages bla is used in.
const STOP_WORDS: &[&str] = &[
    "stop", "halt", "quiet", "shush", "enough", "cancel", "para", "pare", "chega", "basta", "alto", "ruhe", "schluss", "aufhören", "arrête", "stopp",
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// Waiting for the user to start.
    Listening,
    /// They are talking now.
    Hearing,
    /// Whisper has the turn.
    Transcribing,
    /// Drama 3 is talking.
    Speaking,
}

impl Mode {
    pub fn label(self) -> &'static str {
        match self {
            Mode::Listening => "listening",
            Mode::Hearing => "hearing you",
            Mode::Transcribing => "writing it down",
            Mode::Speaking => "speaking",
        }
    }
}

#[derive(Clone)]
pub struct Status {
    pub mode: Mode,
    /// 0 to 1, for the meter.
    pub level: f32,
}

struct Shared {
    mode: Mode,
    level: f32,
    trouble: Option<String>,
    /// The microphone is ignored until then: the tail of our own speech.
    quiet_until: Instant,
    /// Lowercase words we said lately, for the echo test.
    spoken: VecDeque<String>,
    /// Drama 3 is playing right now.
    speaking: bool,
    /// Stop speaking and throw away what is queued.
    hush: bool,
    /// The user cut this reply off, so the rest of it is not said either.
    silenced: bool,
    /// Voice mode is over.
    stop: bool,
}

impl Shared {
    fn set(&mut self, mode: Mode) {
        // Nothing overrides speaking but the end of it.
        if self.speaking && mode != Mode::Speaking && mode != Mode::Listening {
            return;
        }
        self.mode = mode;
    }

    fn remember(&mut self, text: &str) {
        for w in words(text) {
            self.spoken.push_back(w);
        }
        while self.spoken.len() > SPOKEN_MEMORY {
            self.spoken.pop_front();
        }
    }
}

/// Voice mode: two threads, one listening and one speaking, and the handle the chat holds.
pub struct Voice {
    shared: Arc<Mutex<Shared>>,
    sentences: Option<Sender<String>>,
    cutter: Cutter,
    threads: Vec<std::thread::JoinHandle<()>>,
}

impl Voice {
    /// Opens the microphone and the loudspeaker. `sink` is where a heard turn goes: the same
    /// channel the keyboard writes to, so a spoken question is a typed one by the time the chat
    /// sees it. `cancel` is the agent's stop flag, set when the user talks over the answer.
    pub fn start(
        endpoint: &str,
        key: String,
        language: Option<String>,
        voice: Option<String>,
        sink: Sender<Option<String>>,
        cancel: Arc<AtomicBool>,
    ) -> Result<Voice, String> {
        if key.is_empty() {
            return Err("No API key. Run `bla login`.".into());
        }
        // Ask for the microphone here, where the answer can be given back to the user: once the
        // listening thread is running, all a missing device does is make voice mode never hear
        // anything.
        let host = cpal::default_host();
        let device = host.default_input_device().ok_or("No microphone.")?;
        device.default_input_config().map_err(|e| format!("microphone: {e}"))?;
        let api = Api::new(endpoint, key);
        let shared = Arc::new(Mutex::new(Shared {
            mode: Mode::Listening,
            level: 0.0,
            trouble: None,
            quiet_until: Instant::now(),
            spoken: VecDeque::new(),
            speaking: false,
            hush: false,
            silenced: false,
            stop: false,
        }));
        let (sentences, queue) = channel();
        let mut threads = Vec::new();
        {
            let shared = shared.clone();
            let api = api.clone();
            threads.push(
                std::thread::Builder::new()
                    .name("bla-listen".into())
                    .spawn(move || listen(shared, api, language, sink, cancel))
                    .map_err(|e| format!("voice: {e}"))?,
            );
        }
        {
            let shared = shared.clone();
            threads.push(
                std::thread::Builder::new()
                    .name("bla-speak".into())
                    .spawn(move || speak(shared, api, voice, queue))
                    .map_err(|e| format!("voice: {e}"))?,
            );
        }
        Ok(Voice { shared, sentences: Some(sentences), cutter: Cutter::default(), threads })
    }

    /// A handle the drawing and keyboard threads can hold: what to show, and Esc.
    pub fn watch(&self) -> Watch {
        Watch(self.shared.clone())
    }

    /// A piece of the answer as it streams; whole sentences are handed to Drama 3 at once.
    pub fn feed(&mut self, text: &str) {
        {
            let mut s = self.shared.lock().unwrap_or_else(|e| e.into_inner());
            s.silenced = false;
        }
        for sentence in self.cutter.feed(text) {
            self.send(sentence);
        }
    }

    /// The answer ended: say what is left over, unless the user cut it off.
    pub fn end_reply(&mut self) {
        if self.shared.lock().unwrap_or_else(|e| e.into_inner()).silenced {
            self.cutter.clear();
            return;
        }
        if let Some(rest) = self.cutter.flush() {
            self.send(rest);
        }
    }

    fn send(&mut self, sentence: String) {
        if let Some(tx) = &self.sentences {
            let _ = tx.send(sentence);
        }
    }

    /// Closes the microphone and the loudspeaker.
    pub fn stop(mut self) {
        self.shut();
    }

    fn shut(&mut self) {
        {
            let mut s = self.shared.lock().unwrap_or_else(|e| e.into_inner());
            s.stop = true;
            s.hush = true;
        }
        self.sentences = None;
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

impl Drop for Voice {
    fn drop(&mut self) {
        if !self.threads.is_empty() {
            self.shut();
        }
    }
}

/// The threads that draw the screen and read the keyboard hold this: it shows what voice mode is
/// doing and lets Esc stop it, without either of them owning the microphone.
#[derive(Clone)]
pub struct Watch(Arc<Mutex<Shared>>);

impl Watch {
    pub fn status(&self) -> Status {
        let s = self.0.lock().unwrap_or_else(|e| e.into_inner());
        Status { mode: s.mode, level: s.level }
    }

    pub fn hush(&self) {
        let mut s = self.0.lock().unwrap_or_else(|e| e.into_inner());
        s.hush = true;
        s.silenced = true;
    }

    /// What went wrong, once: the chat shows it and it is forgotten.
    pub fn take_trouble(&self) -> Option<String> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).trouble.take()
    }

    /// Whether the microphone thread gave up (no microphone, or it stopped working).
    pub fn ended(&self) -> bool {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).stop
    }
}

/// Cuts a streaming answer into things worth saying out loud.
#[derive(Default)]
pub struct Cutter {
    buf: String,
    /// Inside a ``` fence, which is not read aloud.
    fenced: bool,
}

impl Cutter {
    pub fn feed(&mut self, text: &str) -> Vec<String> {
        self.buf.push_str(text);
        let mut out = Vec::new();
        while let Some(end) = self.cut() {
            let piece: String = self.buf.drain(..end).collect();
            if let Some(s) = self.speakable(&piece) {
                out.push(s);
            }
        }
        out
    }

    /// What is left when the answer ends.
    pub fn flush(&mut self) -> Option<String> {
        let rest = std::mem::take(&mut self.buf);
        self.fenced = false;
        self.speakable(&rest)
    }

    pub fn clear(&mut self) {
        self.buf.clear();
        self.fenced = false;
    }

    /// Where the first complete sentence in the buffer ends, if there is one.
    fn cut(&self) -> Option<usize> {
        let bytes: Vec<char> = self.buf.chars().collect();
        let mut at = 0;
        for (i, c) in bytes.iter().enumerate() {
            at += c.len_utf8();
            let ends = match c {
                '\n' => true,
                // A full stop only counts with a space after it: not 3.8 Å, not alias-fast.
                '.' | '!' | '?' | ':' | ';' => bytes.get(i + 1).map_or(true, |n| n.is_whitespace()),
                _ => false,
            };
            if ends && at >= 2 {
                return Some(at);
            }
        }
        // A very long line with no punctuation is said anyway rather than waiting for the end.
        if self.buf.len() > MAX_SPOKEN {
            return Some(self.buf.len());
        }
        None
    }

    /// Markdown as speech: no fences, no bullets, no decoration. None when there is nothing to say.
    fn speakable(&mut self, piece: &str) -> Option<String> {
        let trimmed = piece.trim();
        if trimmed.starts_with("```") {
            self.fenced = !self.fenced;
            return Some("Code, on the screen.".into()).filter(|_| self.fenced);
        }
        if self.fenced {
            return None;
        }
        let mut text = String::new();
        let mut chars = trimmed.chars().peekable();
        while let Some(c) = chars.next() {
            match c {
                '*' | '_' | '`' | '#' | '>' | '|' => {}
                '\\' => {
                    chars.next();
                }
                _ => text.push(c),
            }
        }
        let text = text.trim().trim_start_matches(['-', '+']).trim().to_string();
        if text.chars().all(|c| !c.is_alphanumeric()) {
            return None;
        }
        Some(crate::util::clip(&text, MAX_SPOKEN).to_string())
    }
}

/// The words of a piece of text, lowercase, for the echo test.
fn words(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric()).filter(|w| w.len() > 1).map(|w| w.to_lowercase()).collect()
}

/// Whether what was heard is the loudspeaker: most of its words are words we just said.
pub fn is_echo(heard: &[String], spoken: &VecDeque<String>) -> bool {
    if heard.is_empty() {
        return true;
    }
    let known = heard.iter().filter(|w| spoken.contains(w)).count();
    known as f32 / heard.len() as f32 >= ECHO_SHARE
}

/// Said by itself while bla is talking, this means be quiet and nothing else.
pub fn is_stop_word(heard: &[String]) -> bool {
    heard.len() == 1 && STOP_WORDS.contains(&heard[0].as_str())
}

// ── the microphone ───────────────────────────────────────────────────────────

fn listen(shared: Arc<Mutex<Shared>>, api: Api, language: Option<String>, sink: Sender<Option<String>>, cancel: Arc<AtomicBool>) {
    let heard: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
    let stream = match input_stream(heard.clone()) {
        Ok(s) => s,
        Err(e) => {
            let mut s = shared.lock().unwrap_or_else(|e| e.into_inner());
            s.trouble = Some(e);
            s.stop = true;
            return;
        }
    };
    if let Err(e) = stream.play() {
        let mut s = shared.lock().unwrap_or_else(|e| e.into_inner());
        s.trouble = Some(format!("microphone: {e}"));
        s.stop = true;
        return;
    }

    let mut pending: Vec<f32> = Vec::new();
    let mut speech: Vec<f32> = Vec::new();
    let mut preroll: VecDeque<f32> = VecDeque::new();
    let preroll_max = (PREROLL.as_secs_f32() * WHISPER_RATE as f32) as usize;
    let mut floor = 0.01f32;
    let mut last_voiced = Instant::now();
    let mut started: Option<Instant> = None;

    loop {
        if shared.lock().unwrap_or_else(|e| e.into_inner()).stop {
            break;
        }
        {
            let mut buf = heard.lock().unwrap_or_else(|e| e.into_inner());
            pending.append(&mut buf);
        }
        while pending.len() >= FRAME {
            let frame: Vec<f32> = pending.drain(..FRAME).collect();
            let rms = (frame.iter().map(|x| x * x).sum::<f32>() / frame.len() as f32).sqrt();
            // The floor follows the quiet of the room, never the talking.
            if started.is_none() && rms < floor * 2.0 {
                floor = floor * 0.95 + rms * 0.05;
            }
            let threshold = (floor * 4.0).max(0.008);
            {
                let mut s = shared.lock().unwrap_or_else(|e| e.into_inner());
                s.level = (rms / threshold.max(1e-6) / 3.0).clamp(0.0, 1.0);
            }
            if rms > threshold {
                if started.is_none() {
                    started = Some(Instant::now());
                    speech.extend(preroll.iter().copied());
                    shared.lock().unwrap_or_else(|e| e.into_inner()).set(Mode::Hearing);
                }
                last_voiced = Instant::now();
            }
            match started {
                Some(begin) => {
                    speech.extend_from_slice(&frame);
                    let long = begin.elapsed() > MAX_SPEECH;
                    if long || last_voiced.elapsed() > SILENCE {
                        let turn = std::mem::take(&mut speech);
                        started = None;
                        preroll.clear();
                        let seconds = turn.len() as f32 / WHISPER_RATE as f32;
                        if Duration::from_secs_f32(seconds) >= MIN_SPEECH {
                            turn_heard(&shared, &api, language.as_deref(), &sink, &cancel, turn);
                        } else {
                            shared.lock().unwrap_or_else(|e| e.into_inner()).set(Mode::Listening);
                        }
                    }
                }
                None => {
                    preroll.extend(frame.iter().copied());
                    while preroll.len() > preroll_max {
                        preroll.pop_front();
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = stream.pause();
}

/// One turn: Whisper, then the guards, then the chat.
fn turn_heard(shared: &Arc<Mutex<Shared>>, api: &Api, language: Option<&str>, sink: &Sender<Option<String>>, cancel: &AtomicBool, turn: Vec<f32>) {
    // The tail of our own speech still in the room.
    let (quiet_until, speaking) = {
        let s = shared.lock().unwrap_or_else(|e| e.into_inner());
        (s.quiet_until, s.speaking)
    };
    if Instant::now() < quiet_until {
        shared.lock().unwrap_or_else(|e| e.into_inner()).set(Mode::Listening);
        return;
    }
    shared.lock().unwrap_or_else(|e| e.into_inner()).set(Mode::Transcribing);
    let wav = wav16(&turn, WHISPER_RATE);
    let text = match api.transcribe(&wav, language) {
        Ok(t) => t,
        Err(e) => {
            let mut s = shared.lock().unwrap_or_else(|e| e.into_inner());
            s.trouble = Some(e);
            s.set(Mode::Listening);
            return;
        }
    };
    let heard = words(&text);
    let mut s = shared.lock().unwrap_or_else(|e| e.into_inner());
    s.set(Mode::Listening);
    if text.trim().is_empty() || is_echo(&heard, &s.spoken) {
        return;
    }
    if speaking {
        // Talking over the answer: be sure it is a person before throwing the answer away.
        if is_stop_word(&heard) {
            s.hush = true;
            return;
        }
        let new = heard.iter().filter(|w| !s.spoken.contains(w)).count();
        if new < BARGE_WORDS {
            return;
        }
        s.hush = true;
        drop(s);
        cancel.store(true, Ordering::Relaxed);
        let _ = sink.send(Some(text));
        return;
    }
    drop(s);
    let _ = sink.send(Some(text));
}

/// The default microphone, downmixed to mono and resampled to what Whisper wants.
fn input_stream(into: Arc<Mutex<Vec<f32>>>) -> Result<cpal::Stream, String> {
    let host = cpal::default_host();
    let device = host.default_input_device().ok_or("No microphone.")?;
    let config = device.default_input_config().map_err(|e| format!("microphone: {e}"))?;
    let rate = config.sample_rate().0;
    let channels = config.channels() as usize;
    let format = config.sample_format();
    let config: cpal::StreamConfig = config.into();
    let trouble = |e: cpal::StreamError| eprintln!("microphone: {e}");
    let mut carry = 0.0f32;
    let step = rate as f32 / WHISPER_RATE as f32;
    let mut take = move |samples: &[f32]| {
        let mono: Vec<f32> = samples.chunks(channels).map(|f| f.iter().sum::<f32>() / channels as f32).collect();
        let mut out = Vec::with_capacity(mono.len());
        let mut at = carry;
        while (at as usize) < mono.len() {
            out.push(mono[at as usize]);
            at += step;
        }
        carry = at - mono.len() as f32;
        let mut buf = into.lock().unwrap_or_else(|e| e.into_inner());
        buf.extend(out);
    };
    let stream = match format {
        cpal::SampleFormat::F32 => device.build_input_stream(&config, move |d: &[f32], _: &_| take(d), trouble, None),
        cpal::SampleFormat::I16 => device.build_input_stream(
            &config,
            move |d: &[i16], _: &_| take(&d.iter().map(|s| *s as f32 / i16::MAX as f32).collect::<Vec<_>>()),
            trouble,
            None,
        ),
        cpal::SampleFormat::U16 => device.build_input_stream(
            &config,
            move |d: &[u16], _: &_| take(&d.iter().map(|s| (*s as f32 - 32768.0) / 32768.0).collect::<Vec<_>>()),
            trouble,
            None,
        ),
        other => return Err(format!("The microphone speaks {other}, which bla can't read.")),
    };
    stream.map_err(|e| format!("microphone: {e}"))
}

// ── the loudspeaker ──────────────────────────────────────────────────────────

fn speak(shared: Arc<Mutex<Shared>>, api: Api, voice: Option<String>, queue: Receiver<String>) {
    let play: Arc<Mutex<VecDeque<f32>>> = Arc::new(Mutex::new(VecDeque::new()));
    let (stream, rate, channels) = match output_stream(play.clone()) {
        Ok(s) => s,
        Err(e) => {
            // Without a loudspeaker bla still listens; it just can't answer out loud.
            shared.lock().unwrap_or_else(|e| e.into_inner()).trouble = Some(e);
            return;
        }
    };
    let _ = stream.play();
    while let Ok(sentence) = queue.recv() {
        if shared.lock().unwrap_or_else(|e| e.into_inner()).stop {
            break;
        }
        if drain(&shared, &queue, &play) {
            continue;
        }
        let audio = match api.speech(&sentence, voice.as_deref()) {
            Ok(bytes) => match decode(&bytes) {
                Ok(a) => a,
                Err(e) => {
                    shared.lock().unwrap_or_else(|e| e.into_inner()).trouble = Some(e);
                    continue;
                }
            },
            Err(e) => {
                shared.lock().unwrap_or_else(|e| e.into_inner()).trouble = Some(e);
                continue;
            }
        };
        if drain(&shared, &queue, &play) {
            continue;
        }
        {
            let mut s = shared.lock().unwrap_or_else(|e| e.into_inner());
            s.speaking = true;
            s.mode = Mode::Speaking;
            s.remember(&sentence);
        }
        {
            let mut buf = play.lock().unwrap_or_else(|e| e.into_inner());
            buf.extend(resample(&audio.0, audio.1, rate, channels));
        }
        // Wait for the loudspeaker to catch up, but keep an eye on Esc.
        loop {
            let left = play.lock().unwrap_or_else(|e| e.into_inner()).len();
            if left == 0 {
                break;
            }
            if drain(&shared, &queue, &play) {
                break;
            }
            std::thread::sleep(Duration::from_millis(30));
        }
        let mut s = shared.lock().unwrap_or_else(|e| e.into_inner());
        s.speaking = false;
        s.quiet_until = Instant::now() + AFTER_SPEAKING;
        s.mode = Mode::Listening;
    }
    let _ = stream.pause();
}

/// True when we were told to be quiet: what is queued and what is playing both go.
fn drain(shared: &Arc<Mutex<Shared>>, queue: &Receiver<String>, play: &Arc<Mutex<VecDeque<f32>>>) -> bool {
    let mut s = shared.lock().unwrap_or_else(|e| e.into_inner());
    if !s.hush {
        return false;
    }
    s.hush = false;
    s.speaking = false;
    s.quiet_until = Instant::now() + AFTER_SPEAKING;
    s.mode = Mode::Listening;
    drop(s);
    play.lock().unwrap_or_else(|e| e.into_inner()).clear();
    while queue.try_recv().is_ok() {}
    true
}

fn output_stream(from: Arc<Mutex<VecDeque<f32>>>) -> Result<(cpal::Stream, u32, usize), String> {
    let host = cpal::default_host();
    let device = host.default_output_device().ok_or("No loudspeaker.")?;
    let config = device.default_output_config().map_err(|e| format!("loudspeaker: {e}"))?;
    let rate = config.sample_rate().0;
    let channels = config.channels() as usize;
    let format = config.sample_format();
    let config: cpal::StreamConfig = config.into();
    let trouble = |e: cpal::StreamError| eprintln!("loudspeaker: {e}");
    let next = move |n: usize| -> Vec<f32> {
        let mut buf = from.lock().unwrap_or_else(|e| e.into_inner());
        (0..n).map(|_| buf.pop_front().unwrap_or(0.0)).collect()
    };
    let stream = match format {
        cpal::SampleFormat::F32 => device.build_output_stream(
            &config,
            move |d: &mut [f32], _: &_| {
                let got = next(d.len());
                for (slot, s) in d.iter_mut().zip(got) {
                    *slot = s;
                }
            },
            trouble,
            None,
        ),
        cpal::SampleFormat::I16 => device.build_output_stream(
            &config,
            move |d: &mut [i16], _: &_| {
                let got = next(d.len());
                for (slot, s) in d.iter_mut().zip(got) {
                    *slot = (s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
                }
            },
            trouble,
            None,
        ),
        cpal::SampleFormat::U16 => device.build_output_stream(
            &config,
            move |d: &mut [u16], _: &_| {
                let got = next(d.len());
                for (slot, s) in d.iter_mut().zip(got) {
                    *slot = ((s.clamp(-1.0, 1.0) * 32767.0) + 32768.0) as u16;
                }
            },
            trouble,
            None,
        ),
        other => return Err(format!("The loudspeaker speaks {other}, which bla can't write.")),
    };
    stream.map(|s| (s, rate, channels)).map_err(|e| format!("loudspeaker: {e}"))
}

/// Mono at one rate to interleaved frames at another, straight lines between the samples.
fn resample(samples: &[f32], from: u32, to: u32, channels: usize) -> Vec<f32> {
    if samples.is_empty() {
        return Vec::new();
    }
    let step = from as f64 / to as f64;
    let out = ((samples.len() as f64) / step) as usize;
    let mut frames = Vec::with_capacity(out * channels);
    for i in 0..out {
        let at = i as f64 * step;
        let left = at as usize;
        let frac = (at - left as f64) as f32;
        let a = samples[left.min(samples.len() - 1)];
        let b = samples[(left + 1).min(samples.len() - 1)];
        let value = a + (b - a) * frac;
        for _ in 0..channels {
            frames.push(value);
        }
    }
    frames
}

// ── sound files ──────────────────────────────────────────────────────────────

/// Mono 16-bit PCM in a WAV wrapper, which is what /audio/transcriptions takes.
pub fn wav16(samples: &[f32], rate: u32) -> Vec<u8> {
    let data: Vec<u8> = samples.iter().flat_map(|s| ((s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16).to_le_bytes()).collect();
    let mut out = Vec::with_capacity(44 + data.len());
    out.extend(b"RIFF");
    out.extend(((36 + data.len()) as u32).to_le_bytes());
    out.extend(b"WAVEfmt ");
    out.extend(16u32.to_le_bytes()); // the size of this block
    out.extend(1u16.to_le_bytes()); // PCM
    out.extend(1u16.to_le_bytes()); // mono
    out.extend(rate.to_le_bytes());
    out.extend((rate * 2).to_le_bytes()); // bytes a second
    out.extend(2u16.to_le_bytes()); // bytes a frame
    out.extend(16u16.to_le_bytes()); // bits a sample
    out.extend(b"data");
    out.extend((data.len() as u32).to_le_bytes());
    out.extend(data);
    out
}

/// Whatever Drama 3 sent back, as mono samples and their rate. WAV when the service honours
/// `response_format`, MP3 when it doesn't.
pub fn decode(bytes: &[u8]) -> Result<(Vec<f32>, u32), String> {
    if bytes.starts_with(b"RIFF") {
        return decode_wav(bytes);
    }
    decode_mp3(bytes)
}

fn decode_wav(bytes: &[u8]) -> Result<(Vec<f32>, u32), String> {
    let u16at = |at: usize| -> u16 { u16::from_le_bytes([bytes[at], bytes[at + 1]]) };
    let u32at = |at: usize| -> u32 { u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]]) };
    if bytes.len() < 44 || &bytes[8..12] != b"WAVE" {
        return Err("The speech came back in a sound file bla can't read.".into());
    }
    let (mut at, mut rate, mut channels, mut bits, mut float) = (12, 0u32, 1usize, 16u16, false);
    while at + 8 <= bytes.len() {
        let id = &bytes[at..at + 4];
        let size = u32at(at + 4) as usize;
        let body = at + 8;
        if id == b"fmt " && body + 16 <= bytes.len() {
            float = u16at(body) == 3;
            channels = u16at(body + 2).max(1) as usize;
            rate = u32at(body + 4);
            bits = u16at(body + 14);
        } else if id == b"data" {
            let end = (body + size).min(bytes.len());
            let raw = &bytes[body..end];
            let samples: Vec<f32> = match (bits, float) {
                (16, false) => raw.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / i16::MAX as f32).collect(),
                (32, true) => raw.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect(),
                (32, false) => raw.chunks_exact(4).map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]) as f32 / i32::MAX as f32).collect(),
                (8, false) => raw.iter().map(|b| (*b as f32 - 128.0) / 128.0).collect(),
                _ => return Err(format!("The speech came back as {bits}-bit sound, which bla can't read.")),
            };
            let mono = samples.chunks(channels).map(|f| f.iter().sum::<f32>() / channels as f32).collect();
            return Ok((mono, rate.max(1)));
        }
        at = body + size + (size & 1);
    }
    Err("The speech came back empty.".into())
}

fn decode_mp3(bytes: &[u8]) -> Result<(Vec<f32>, u32), String> {
    use symphonia::core::audio::SampleBuffer;
    use symphonia::core::codecs::DecoderOptions;
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    let source = MediaSourceStream::new(Box::new(std::io::Cursor::new(bytes.to_vec())), Default::default());
    let mut hint = Hint::new();
    hint.with_extension("mp3");
    let probed = symphonia::default::get_probe()
        .format(&hint, source, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| format!("The speech came back in a sound file bla can't read: {e}"))?;
    let mut format = probed.format;
    let track = format.default_track().ok_or("The speech came back empty.")?;
    let rate = track.codec_params.sample_rate.unwrap_or(24_000);
    let id = track.id;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("The speech came back in a sound file bla can't read: {e}"))?;
    let mut out: Vec<f32> = Vec::new();
    let mut buffer: Option<SampleBuffer<f32>> = None;
    while let Ok(packet) = format.next_packet() {
        if packet.track_id() != id {
            continue;
        }
        let Ok(decoded) = decoder.decode(&packet) else { continue };
        let spec = *decoded.spec();
        let buf = buffer.get_or_insert_with(|| SampleBuffer::new(decoded.capacity() as u64, spec));
        buf.copy_interleaved_ref(decoded);
        let channels = spec.channels.count().max(1);
        out.extend(buf.samples().chunks(channels).map(|f| f.iter().sum::<f32>() / channels as f32));
    }
    if out.is_empty() {
        return Err("The speech came back empty.".into());
    }
    Ok((out, rate))
}

// ── the service ──────────────────────────────────────────────────────────────

#[derive(Clone)]
struct Api {
    endpoint: String,
    key: String,
    agent: ureq::Agent,
}

impl Api {
    fn new(endpoint: &str, key: String) -> Api {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(20))
            .timeout_read(Duration::from_secs(120))
            .user_agent(concat!("bla/", env!("CARGO_PKG_VERSION")))
            .build();
        Api { endpoint: endpoint.trim_end_matches('/').to_string(), key, agent }
    }

    fn transcribe(&self, wav: &[u8], language: Option<&str>) -> Result<String, String> {
        let boundary = format!("bla-{}", crate::util::random_hex(16));
        let mut body = Vec::new();
        let field = |name: &str, value: &str, body: &mut Vec<u8>| {
            body.extend(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
        };
        field("model", blablador_models::TRANSCRIPTION_MODEL, &mut body);
        if let Some(l) = language.filter(|l| !l.is_empty()) {
            field("language", l, &mut body);
        }
        body.extend(
            format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"turn.wav\"\r\nContent-Type: audio/wav\r\n\r\n").as_bytes(),
        );
        body.extend(wav);
        body.extend(format!("\r\n--{boundary}--\r\n").as_bytes());
        let answer = self
            .agent
            .post(&format!("{}/audio/transcriptions", self.endpoint))
            .set("Authorization", &format!("Bearer {}", self.key))
            .set("Content-Type", &format!("multipart/form-data; boundary={boundary}"))
            .send_bytes(&body)
            .map_err(|e| format!("Whisper: {e}"))?;
        let value: serde_json::Value = answer.into_json().map_err(|e| format!("Whisper: {e}"))?;
        Ok(value.get("text").and_then(|t| t.as_str()).unwrap_or_default().trim().to_string())
    }

    /// Drama 3. We ask for WAV; the service may still answer MP3, which `decode` reads too.
    fn speech(&self, text: &str, voice: Option<&str>) -> Result<Vec<u8>, String> {
        let mut body = json!({"model": blablador_models::SPEECH_MODEL, "input": text, "response_format": "wav"});
        if let Some(v) = voice.filter(|v| !v.is_empty()) {
            body["voice"] = json!(v);
        }
        let answer = self
            .agent
            .post(&format!("{}/audio/speech", self.endpoint))
            .set("Authorization", &format!("Bearer {}", self.key))
            .set("Content-Type", "application/json")
            .send_string(&body.to_string())
            .map_err(|e| format!("Drama 3: {e}"))?;
        let mut bytes = Vec::new();
        std::io::Read::read_to_end(&mut answer.into_reader(), &mut bytes).map_err(|e| format!("Drama 3: {e}"))?;
        if bytes.is_empty() {
            return Err("Drama 3 sent nothing back.".into());
        }
        Ok(bytes)
    }
}

/// What the model is told while the user is talking rather than typing.
pub const SYSTEM_PROMPT: &str = "The user is talking to you out loud and your answer is read back to them, so write it to be heard: \
short sentences, no lists, no tables, no code blocks, no markdown decoration, no URLs read out character by character. \
Say the one thing that answers them, in at most a few sentences, and offer the detail instead of giving it. \
When you have to show code or a long file, say so in one sentence and put it on the screen rather than reading it out.";
