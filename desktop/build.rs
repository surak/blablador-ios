// Puts Blablador's icon into Blablador.exe, for Explorer, shortcuts and the taskbar; without it Windows shows a blank
// program icon. The window's own icon is set in main.rs.
fn main() {
    println!("cargo:rerun-if-changed=windows/blablador.ico");
    #[cfg(windows)]
    {
        let mut resource = winresource::WindowsResource::new();
        resource.set_icon("windows/blablador.ico");
        resource.compile().expect("the Windows icon resource");
    }
}
