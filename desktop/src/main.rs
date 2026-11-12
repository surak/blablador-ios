// No console window next to the app on Windows.
#![cfg_attr(windows, windows_subsystem = "windows")]

mod api;
mod app;
mod chat;
mod effort;
mod extract;
mod knowledge;
mod mapper;
mod model;
mod storage;
mod tools;

fn main() -> eframe::Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
    let options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("Blablador")
            .with_app_id("de.fz-juelich.blablador")
            .with_inner_size([1100.0, 760.0])
            .with_min_inner_size([520.0, 400.0]),
        ..Default::default()
    };
    eframe::run_native("Blablador", options, Box::new(move |cc| Ok(Box::new(app::App::new(cc, runtime)))))
}
