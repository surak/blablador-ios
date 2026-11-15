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
mod proteins;
mod storage;
mod tools;

fn main() {
    // Without a console nobody sees a panic; say it in a dialog, and keep it in a log next to the data.
    std::panic::set_hook(Box::new(|info| {
        let text = format!("Blablador stopped: {info}");
        report(&text);
    }));
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
    // wgpu first (DirectX 12 on Windows, falling back to its software renderer), then OpenGL: plenty of Windows
    // machines (older graphics, virtual machines, Remote Desktop) have no OpenGL the app can use.
    let mut errors = Vec::new();
    let mut runtime = Some(runtime);
    let renderers = match std::env::var("BLABLADOR_RENDERER").as_deref() {
        Ok("glow") => vec![eframe::Renderer::Glow],
        Ok("wgpu") => vec![eframe::Renderer::Wgpu],
        _ => vec![eframe::Renderer::Wgpu, eframe::Renderer::Glow],
    };
    for renderer in renderers {
        let Some(rt) = runtime.take() else { break };
        let cell = std::rc::Rc::new(std::cell::RefCell::new(Some(rt)));
        let taken = cell.clone();
        let options = eframe::NativeOptions {
            viewport: eframe::egui::ViewportBuilder::default()
                .with_title("Blablador")
                .with_app_id("de.fz-juelich.blablador")
                .with_inner_size([1100.0, 760.0])
                .with_min_inner_size([520.0, 400.0]),
            renderer,
            ..Default::default()
        };
        let result = eframe::run_native(
            "Blablador",
            options,
            Box::new(move |cc| Ok(Box::new(app::App::new(cc, taken.borrow_mut().take().expect("one start"))))),
        );
        match result {
            Ok(()) => return,
            Err(e) => {
                errors.push(format!("{renderer:?}: {e}"));
                // The app never started, so the runtime was not handed over and the next renderer can have it.
                runtime = cell.borrow_mut().take();
                if runtime.is_none() {
                    break;
                }
            }
        }
    }
    report(&format!("Blablador could not open its window.\n\n{}", errors.join("\n")));
}

/// An error the user must see: a dialog, since the Windows app has no console, and blablador-error.log.
fn report(text: &str) {
    eprintln!("{text}");
    let _ = std::fs::write(storage::data_dir().join("blablador-error.log"), text);
    // CI starts the app to see that it opens; there a dialog would only wait for nobody.
    if std::env::var_os("BLABLADOR_NO_DIALOG").is_some() {
        std::process::exit(1);
    }
    rfd::MessageDialog::new()
        .set_level(rfd::MessageLevel::Error)
        .set_title("Blablador")
        .set_description(format!("{text}\n\nPlease send this to the Blablador team."))
        .show();
}
