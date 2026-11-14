//! 3D room (Room Mapper): photos go to `alias-visual-geometry`, which builds a floor map and a coloured point cloud.
//! Commands are plain chat completions whose reply content is JSON.

use crate::api::Api;
use anyhow::{anyhow, Result};
use base64::Engine;
use eframe::egui::{self, Color32, ColorImage, Pos2, TextureHandle, Vec2};
use rand::Rng;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const MODEL: &str = blablador_models::VISUAL_GEOMETRY_MODEL;
const BATCH: usize = 4;
const MAX_SIDE: u32 = 1024;
const MAX_POINTS: usize = 200_000;

pub fn valid_session(name: &str) -> bool {
    (1..=64).contains(&name.len()) && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

pub fn default_session() -> String {
    const LETTERS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    let mut rng = rand::thread_rng();
    let tail: String = (0..4).map(|_| LETTERS[rng.gen_range(0..LETTERS.len())] as char).collect();
    format!("room-{}-{tail}", chrono::Local::now().format("%Y%m%d-%H%M"))
}

pub fn step_command(session: &str, height_cm: u32) -> String {
    format!("step session={session} camera_height_cm={height_cm}")
}
pub fn finish_command(session: &str) -> String {
    format!("finish session={session}")
}
pub fn download_command(session: &str, part: u64) -> String {
    format!("download session={session} part={part}")
}
pub fn queue_command(session: &str) -> String {
    format!("queue session={session}")
}

async fn command(api: &Api, text: &str, images: &[String]) -> Result<Value> {
    let mut content = vec![json!({ "type": "text", "text": text })];
    for image in images {
        content.push(json!({ "type": "image_url", "image_url": { "url": format!("data:image/jpeg;base64,{image}") } }));
    }
    let body = json!({ "model": MODEL, "stream": false, "messages": [{ "role": "user", "content": content }] });
    let reply = api.post_json("chat/completions", &body, Duration::from_secs(1800)).await?;
    let text = reply["choices"][0]["message"]["content"].as_str().ok_or_else(|| anyhow!("Empty answer from the mapper."))?;
    let value: Value = serde_json::from_str(text.trim()).map_err(|_| anyhow!("{}", text.chars().take(300).collect::<String>()))?;
    if let Some(error) = value["error"].as_str() {
        return Err(anyhow!("{error}"));
    }
    Ok(value)
}

/// A photo shrunk to at most 1024 px, upright, as base64 JPEG, plus a small thumbnail.
fn prepare(path: &PathBuf) -> Result<(String, ColorImage)> {
    use image::ImageDecoder;
    let mut decoder = image::ImageReader::open(path)?.with_guessed_format()?.into_decoder()?;
    let orientation = decoder.orientation().ok();
    let mut img = image::DynamicImage::from_decoder(decoder)?;
    if let Some(o) = orientation {
        img.apply_orientation(o);
    }
    if img.width() > MAX_SIDE || img.height() > MAX_SIDE {
        img = img.resize(MAX_SIDE, MAX_SIDE, image::imageops::FilterType::Triangle);
    }
    let rgb = img.to_rgb8();
    let mut jpeg = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 85).encode_image(&rgb)?;
    let thumb = img.thumbnail(96, 96).to_rgba8();
    let thumb = ColorImage::from_rgba_unmultiplied([thumb.width() as usize, thumb.height() as usize], thumb.as_raw());
    Ok((base64::engine::general_purpose::STANDARD.encode(jpeg), thumb))
}

fn decode_png(b64: &str) -> Option<ColorImage> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64.trim()).ok()?;
    let img = image::load_from_memory(&bytes).ok()?.to_rgba8();
    Some(ColorImage::from_rgba_unmultiplied([img.width() as usize, img.height() as usize], img.as_raw()))
}

/// Parses a binary little-endian PLY with float x,y,z and uchar r,g,b per vertex.
pub fn parse_ply(data: &[u8]) -> Result<(Vec<[f32; 3]>, Vec<[u8; 3]>)> {
    let marker = b"end_header\n";
    let end = data.windows(marker.len()).position(|w| w == marker).ok_or_else(|| anyhow!("Not a PLY file."))? + marker.len();
    let header = String::from_utf8_lossy(&data[..end]);
    if !header.starts_with("ply") || !header.contains("binary_little_endian") {
        return Err(anyhow!("Unsupported PLY format."));
    }
    let count: usize = header
        .lines()
        .find_map(|l| l.strip_prefix("element vertex ").and_then(|n| n.trim().parse().ok()))
        .ok_or_else(|| anyhow!("No vertex count in the PLY."))?;
    let body = &data[end..];
    let count = count.min(body.len() / 15);
    let mut points = Vec::with_capacity(count);
    let mut colors = Vec::with_capacity(count);
    for v in body.chunks_exact(15).take(count) {
        let f = |i: usize| f32::from_le_bytes([v[i], v[i + 1], v[i + 2], v[i + 3]]);
        points.push([f(0), f(4), f(8)]);
        colors.push([v[12], v[13], v[14]]);
    }
    Ok((points, colors))
}

#[derive(Default)]
struct Queue {
    gpu_busy: u64,
    others: u64,
    known: bool,
}

struct Photo {
    path: PathBuf,
    sent: bool,
    thumb: Option<TextureHandle>,
}

pub struct Cloud {
    points: Vec<[f32; 3]>,
    colors: Vec<Color32>,
    centre: [f32; 3],
    radius: f32,
    total: usize,
    frames: u64,
    in_cm: bool,
    ply: Vec<u8>,
}

#[derive(Default)]
struct Shared {
    busy: Option<String>,
    error: Option<String>,
    sent: Vec<PathBuf>,
    thumbs: Vec<(PathBuf, ColorImage)>,
    queue: Queue,
    waited: Option<(f64, u64)>,
    stats: Option<(u64, usize, Option<f64>)>,
    note: Option<String>,
    map: Option<ColorImage>,
    cloud: Option<Cloud>,
}

pub struct Mapper {
    pub open: bool,
    session: String,
    height: u32,
    photos: Vec<Photo>,
    shared: Arc<Mutex<Shared>>,
    map: Option<TextureHandle>,
    cloud: Option<Cloud>,
    last_poll: Option<Instant>,
    yaw: f32,
    pitch: f32,
    zoom: f32,
}

impl Default for Mapper {
    fn default() -> Self {
        Mapper {
            open: false,
            session: default_session(),
            height: 120,
            photos: vec![],
            shared: Arc::default(),
            map: None,
            cloud: None,
            last_poll: None,
            yaw: 0.6,
            pitch: 0.4,
            zoom: 1.0,
        }
    }
}

fn record_queue(shared: &Mutex<Shared>, value: &Value) {
    let q = &value["queue"];
    if q.is_object() {
        let mut s = shared.lock().unwrap();
        s.queue = Queue { gpu_busy: q["gpu_busy"].as_u64().unwrap_or(0), others: q["other_sessions_active"].as_u64().unwrap_or(0), known: true };
        let waited = q["waited_s"].as_f64().unwrap_or(0.0);
        let ahead = q["ahead_on_arrival"].as_u64().unwrap_or(0);
        if waited >= 1.0 && ahead > 0 {
            s.waited = Some((waited, ahead));
        }
    }
}

impl Mapper {
    fn spawn<F>(&self, runtime: &tokio::runtime::Runtime, ctx: &egui::Context, label: &str, work: F)
    where
        F: std::future::Future<Output = Result<()>> + Send + 'static,
    {
        let shared = self.shared.clone();
        {
            let mut s = shared.lock().unwrap();
            s.busy = Some(label.into());
            s.error = None;
        }
        let ctx = ctx.clone();
        runtime.spawn(async move {
            let result = work.await;
            let mut s = shared.lock().unwrap();
            s.busy = None;
            if let Err(e) = result {
                s.error = Some(e.to_string());
            }
            ctx.request_repaint();
        });
    }

    fn add_photos(&mut self, runtime: &tokio::runtime::Runtime, ctx: &egui::Context, files: Vec<PathBuf>) {
        let shared = self.shared.clone();
        let ctx = ctx.clone();
        for path in &files {
            self.photos.push(Photo { path: path.clone(), sent: false, thumb: None });
        }
        runtime.spawn_blocking(move || {
            for path in files {
                if let Ok((_, thumb)) = prepare(&path) {
                    shared.lock().unwrap().thumbs.push((path, thumb));
                    ctx.request_repaint();
                }
            }
        });
    }

    fn send(&self, runtime: &tokio::runtime::Runtime, ctx: &egui::Context, api: Api) {
        let pending: Vec<PathBuf> = self.photos.iter().filter(|p| !p.sent).map(|p| p.path.clone()).collect();
        let (session, height, shared) = (self.session.clone(), self.height, self.shared.clone());
        let c = ctx.clone();
        let total = pending.len();
        self.spawn(runtime, ctx, "Sending…", async move {
            let mut done = 0;
            for batch in pending.chunks(BATCH) {
                shared.lock().unwrap().busy = Some(format!("Sending photos {}–{} of {total}…", done + 1, done + batch.len()));
                c.request_repaint();
                let paths = batch.to_vec();
                let images = tokio::task::spawn_blocking(move || paths.iter().map(|p| prepare(p).map(|r| r.0)).collect::<Result<Vec<_>>>()).await??;
                let value = command(&api, &step_command(&session, height), &images).await?;
                record_queue(&shared, &value);
                done += batch.len();
                let mut s = shared.lock().unwrap();
                s.sent.extend(batch.iter().cloned());
                s.stats = Some((
                    value["frames"].as_u64().unwrap_or(0),
                    value["frontiers"].as_array().map(|a| a.len()).unwrap_or(0),
                    value["obstacle_ahead_cm"].as_f64(),
                ));
                s.note = value["note"].as_str().map(String::from);
                if let Some(map) = value["map_png"].as_str().and_then(decode_png) {
                    s.map = Some(map);
                }
                drop(s);
                c.request_repaint();
            }
            Ok(())
        });
    }

    fn build(&self, runtime: &tokio::runtime::Runtime, ctx: &egui::Context, api: Api) {
        let (session, shared) = (self.session.clone(), self.shared.clone());
        let c = ctx.clone();
        self.spawn(runtime, ctx, "Building the 3D model…", async move {
            let value = command(&api, &finish_command(&session), &[]).await?;
            record_queue(&shared, &value);
            let parts = value["parts"].as_u64().unwrap_or(0);
            let frames = value["frames_used"].as_u64().unwrap_or(0);
            let in_cm = value["units"].as_str() == Some("cm");
            shared.lock().unwrap().note = value["note"].as_str().map(String::from);
            let mut ply = Vec::new();
            for part in 0..parts {
                shared.lock().unwrap().busy = Some(format!("Downloading part {} of {parts}…", part + 1));
                c.request_repaint();
                let value = command(&api, &download_command(&session, part), &[]).await?;
                let data = value["data"].as_str().ok_or_else(|| anyhow!("Missing part {part}."))?;
                ply.extend(base64::engine::general_purpose::STANDARD.decode(data.trim())?);
            }
            let cloud = tokio::task::spawn_blocking(move || make_cloud(ply, frames, in_cm)).await??;
            shared.lock().unwrap().cloud = Some(cloud);
            Ok(())
        });
    }

    fn poll_queue(&mut self, runtime: &tokio::runtime::Runtime, ctx: &egui::Context, api: &Api) {
        if self.last_poll.is_some_and(|t| t.elapsed() < Duration::from_secs(5)) || api.key.is_empty() || !valid_session(&self.session) {
            return;
        }
        self.last_poll = Some(Instant::now());
        let (api, shared, session, c) = (api.clone(), self.shared.clone(), self.session.clone(), ctx.clone());
        runtime.spawn(async move {
            if let Ok(value) = command(&api, &queue_command(&session), &[]).await {
                record_queue(&shared, &value);
                c.request_repaint();
            }
        });
    }

    pub fn window(&mut self, ctx: &egui::Context, runtime: &tokio::runtime::Runtime, api: Api) {
        if !self.open {
            return;
        }
        self.poll_queue(runtime, ctx, &api);
        ctx.request_repaint_after(Duration::from_secs(5));

        // Take what the background tasks produced.
        let (busy, error, queue, waited, stats, note) = {
            let mut s = self.shared.lock().unwrap();
            for path in std::mem::take(&mut s.sent) {
                self.photos.iter_mut().filter(|p| p.path == path).for_each(|p| p.sent = true);
            }
            for (path, image) in std::mem::take(&mut s.thumbs) {
                let texture = ctx.load_texture(path.to_string_lossy(), image, Default::default());
                self.photos.iter_mut().filter(|p| p.path == path).for_each(|p| p.thumb = Some(texture.clone()));
            }
            if let Some(map) = s.map.take() {
                self.map = Some(ctx.load_texture("room-map", map, Default::default()));
            }
            if let Some(cloud) = s.cloud.take() {
                self.cloud = Some(cloud);
                self.zoom = 1.0;
            }
            (s.busy.clone(), s.error.clone(), (s.queue.known, s.queue.gpu_busy, s.queue.others), s.waited, s.stats, s.note.clone())
        };

        let mut open = self.open;
        egui::Window::new("3D room").open(&mut open).default_width(560.0).default_height(640.0).show(ctx, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.label("Take photos around a room; Blablador maps the floor and builds a 3D model.");
                let idle = busy.is_none();
                ui.horizontal(|ui| {
                    ui.label("Name");
                    ui.add_enabled(idle, egui::TextEdit::singleline(&mut self.session).desired_width(220.0));
                    ui.label("Camera height");
                    ui.add_enabled(idle, egui::DragValue::new(&mut self.height).range(10..=300).suffix(" cm"));
                });
                if !valid_session(&self.session) {
                    ui.colored_label(Color32::from_rgb(220, 80, 70), "Use 1–64 letters, digits, - or _.");
                }

                let (known, gpu, others) = queue;
                if known {
                    let (color, text) = if gpu > 0 {
                        (Color32::from_rgb(220, 80, 70), format!("The GPU is busy: {gpu} request(s) running or waiting. Your photos will wait their turn."))
                    } else if others > 0 {
                        (Color32::from_rgb(230, 170, 40), format!("{others} other people are mapping right now. Sending may take a little longer."))
                    } else {
                        (Color32::from_rgb(70, 180, 90), "Nobody else is mapping right now.".to_string())
                    };
                    ui.horizontal_wrapped(|ui| {
                        let (rect, _) = ui.allocate_exact_size(Vec2::splat(12.0), egui::Sense::hover());
                        ui.painter().circle_filled(rect.center(), 5.0, color);
                        ui.label(text);
                    });
                }

                ui.horizontal(|ui| {
                    if ui.add_enabled(idle, egui::Button::new("Add photos…")).clicked() {
                        if let Some(files) = rfd::FileDialog::new().add_filter("Images", &["jpg", "jpeg", "png", "webp"]).pick_files() {
                            self.add_photos(runtime, ctx, files);
                        }
                    }
                    let pending = self.photos.iter().filter(|p| !p.sent).count();
                    if pending > 0
                        && ui.add_enabled(idle && valid_session(&self.session), egui::Button::new(format!("Send {pending} photos"))).clicked()
                    {
                        self.send(runtime, ctx, api.clone());
                    }
                });
                ui.horizontal_wrapped(|ui| {
                    for photo in &self.photos {
                        let (rect, _) = ui.allocate_exact_size(Vec2::splat(64.0), egui::Sense::hover());
                        if let Some(t) = &photo.thumb {
                            let size = t.size_vec2();
                            let scale = 64.0 / size.x.max(size.y);
                            let r = egui::Rect::from_center_size(rect.center(), size * scale);
                            ui.painter().image(t.id(), r, egui::Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)), Color32::WHITE);
                        } else {
                            ui.painter().rect_filled(rect, 4.0, ui.visuals().faint_bg_color);
                        }
                        if photo.sent {
                            let c = rect.right_top() + Vec2::new(-10.0, 10.0);
                            ui.painter().circle_filled(c, 8.0, Color32::from_rgb(70, 180, 90));
                            ui.painter().text(c, egui::Align2::CENTER_CENTER, "✓", egui::FontId::proportional(11.0), Color32::WHITE);
                        }
                    }
                });

                if let Some(text) = &busy {
                    ui.horizontal(|ui| {
                        ui.spinner();
                        ui.label(text);
                    });
                }
                if let Some(e) = &error {
                    ui.colored_label(Color32::from_rgb(220, 80, 70), e);
                }
                if let Some((secs, n)) = waited {
                    ui.weak(format!("Waited {secs:.0} s for {n} request(s) from others."));
                }
                if let Some(note) = &note {
                    ui.label(note);
                }

                if let Some((frames, edges, obstacle)) = stats {
                    ui.separator();
                    let obstacle = obstacle.map(|o| format!("{o:.0} cm")).unwrap_or_else(|| "none".into());
                    ui.label(format!("Photos: {frames}   ·   Unexplored edges: {edges}   ·   Obstacle ahead: {obstacle}"));
                    if let Some(map) = &self.map {
                        let size = map.size_vec2();
                        let scale = (ui.available_width() / size.x).min(1.0).max(0.1);
                        ui.image((map.id(), size * scale));
                    }
                    ui.weak("white floor · black obstacles · grey unknown · orange edges · blue path");
                    if ui.add_enabled(idle, egui::Button::new("Build the 3D model")).clicked() {
                        self.build(runtime, ctx, api.clone());
                    }
                }

                if self.cloud.is_some() {
                    ui.separator();
                    self.viewer(ui);
                }
            });
        });
        self.open = open;
    }

    fn viewer(&mut self, ui: &mut egui::Ui) {
        let Some(cloud) = &self.cloud else { return };
        ui.label(if cloud.in_cm {
            format!("{} points from {} photos, in centimetres.", cloud.total, cloud.frames)
        } else {
            format!("{} points from {} photos. No floor found, so the size is not to scale.", cloud.total, cloud.frames)
        });
        let width = ui.available_width();
        let (rect, response) = ui.allocate_exact_size(Vec2::new(width, width * 0.7), egui::Sense::drag());
        if response.dragged() {
            let d = response.drag_delta();
            self.yaw += d.x * 0.01;
            self.pitch = (self.pitch + d.y * 0.01).clamp(-1.5, 1.5);
        }
        if response.hovered() {
            let scroll = ui.input(|i| i.smooth_scroll_delta.y);
            if scroll != 0.0 {
                self.zoom = (self.zoom * (scroll * 0.003).exp()).clamp(0.1, 20.0);
            }
        }
        let painter = ui.painter_at(rect);
        painter.rect_filled(rect, 4.0, Color32::from_gray(20));
        let (sy, cy, sp, cp) = (self.yaw.sin(), self.yaw.cos(), self.pitch.sin(), self.pitch.cos());
        let scale = rect.width().min(rect.height()) * 0.45 * self.zoom / cloud.radius.max(1e-6);
        let mut mesh = egui::Mesh::default();
        let s = 1.0;
        for (p, &color) in cloud.points.iter().zip(&cloud.colors) {
            // y points down in the model; flip it so up is up.
            let (x, y, z) = (p[0] - cloud.centre[0], -(p[1] - cloud.centre[1]), p[2] - cloud.centre[2]);
            let (x, z) = (x * cy - z * sy, x * sy + z * cy);
            let (y, _z) = (y * cp - z * sp, y * sp + z * cp);
            let pos = Pos2::new(rect.center().x + x * scale, rect.center().y - y * scale);
            if rect.contains(pos) {
                mesh.add_colored_rect(egui::Rect::from_center_size(pos, Vec2::splat(s * 1.5)), color);
            }
        }
        painter.add(mesh);
        ui.horizontal(|ui| {
            ui.weak("Drag to turn, scroll to zoom.");
            if ui.button("Save PLY…").clicked() {
                if let Some(path) = rfd::FileDialog::new().set_file_name(format!("{}.ply", self.session)).save_file() {
                    if let Err(e) = std::fs::write(path, &cloud.ply) {
                        self.shared.lock().unwrap().error = Some(e.to_string());
                    }
                }
            }
        });
    }
}

fn make_cloud(ply: Vec<u8>, frames: u64, in_cm: bool) -> Result<Cloud> {
    let (points, colors) = parse_ply(&ply)?;
    if points.is_empty() {
        return Err(anyhow!("The model has no points."));
    }
    let total = points.len();
    let step = total.div_ceil(MAX_POINTS).max(1);
    let mut lo = [f32::MAX; 3];
    let mut hi = [f32::MIN; 3];
    for p in points.iter().filter(|p| p.iter().all(|v| v.is_finite())) {
        for i in 0..3 {
            lo[i] = lo[i].min(p[i]);
            hi[i] = hi[i].max(p[i]);
        }
    }
    let centre = [(lo[0] + hi[0]) / 2.0, (lo[1] + hi[1]) / 2.0, (lo[2] + hi[2]) / 2.0];
    let radius = ((hi[0] - lo[0]).powi(2) + (hi[1] - lo[1]).powi(2) + (hi[2] - lo[2]).powi(2)).sqrt() / 2.0;
    let keep: Vec<usize> = (0..total).step_by(step).filter(|&i| points[i].iter().all(|v| v.is_finite())).collect();
    Ok(Cloud {
        points: keep.iter().map(|&i| points[i]).collect(),
        colors: keep.iter().map(|&i| Color32::from_rgb(colors[i][0], colors[i][1], colors[i][2])).collect(),
        centre,
        radius,
        total,
        frames,
        in_cm,
        ply,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ply(points: &[([f32; 3], [u8; 3])]) -> Vec<u8> {
        let mut data = format!(
            "ply\nformat binary_little_endian 1.0\nelement vertex {}\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n",
            points.len()
        )
        .into_bytes();
        for (p, c) in points {
            for v in p {
                data.extend(v.to_le_bytes());
            }
            data.extend(c);
        }
        data
    }

    #[test]
    fn parses_ply() {
        let data = ply(&[([1.0, -2.5, 3.0], [255, 0, 10]), ([0.0, 0.5, -1.0], [1, 2, 3])]);
        let (points, colors) = parse_ply(&data).unwrap();
        assert_eq!(points, vec![[1.0, -2.5, 3.0], [0.0, 0.5, -1.0]]);
        assert_eq!(colors, vec![[255, 0, 10], [1, 2, 3]]);
        let cloud = make_cloud(data, 2, true).unwrap();
        assert_eq!(cloud.total, 2);
        assert_eq!(cloud.centre, [0.5, -1.0, 1.0]);
    }

    #[test]
    fn parses_split_parts_and_rejects_junk() {
        let data = ply(&[([1.0, 2.0, 3.0], [4, 5, 6])]);
        let (a, b) = data.split_at(data.len() / 2);
        let joined = [a, b].concat();
        assert_eq!(parse_ply(&joined).unwrap().0.len(), 1);
        assert!(parse_ply(b"hello").is_err());
        // A truncated body yields only the complete vertices.
        assert_eq!(parse_ply(&data[..data.len() - 1]).unwrap().0.len(), 0);
    }

    #[test]
    fn commands_and_names() {
        assert_eq!(step_command("room-1", 120), "step session=room-1 camera_height_cm=120");
        assert_eq!(finish_command("a_b"), "finish session=a_b");
        assert_eq!(download_command("x", 3), "download session=x part=3");
        assert_eq!(queue_command("x"), "queue session=x");
        let name = default_session();
        assert!(valid_session(&name) && name.starts_with("room-"));
        assert!(!valid_session("") && !valid_session("a b") && !valid_session(&"a".repeat(65)));
    }
}
