//! Whether a newer bla has been released, and putting it in place.
//!
//! bla updates itself: the release carries the bare binary for each platform (`bla-<version>-<platform>`), so this
//! downloads it, checks it against SHA256SUMS.txt, starts it once to see that it works here, and writes it over the
//! running program by a rename — which a running program allows on both Unix and Windows. Where bla belongs to
//! something else (the Mac app, Homebrew, cargo) it is not touched: those update it, and the message says how.
//!
//! Three ways in. `bla update` does it now and says what happened. `bla -v` only looks, so a version check in a script
//! stays fast. And at the start of a chat a newer bla installs itself and hands over to the new one, once every few
//! hours at most. Failing to ask GitHub is never mentioned: it is not the user's problem that their train has no
//! signal, and the old bla still works.
//!
//! The check asks the `releases/latest` redirect for its tag instead of the API: no token, so no rate limit shared
//! with whoever else is behind the same address.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const REPO: &str = "surak/blablador-ios";
pub const RELEASES: &str = "https://github.com/surak/blablador-ios/releases";

/// How long an answer, including "you are current", is trusted before asking again.
const REMEMBER: u64 = 6 * 60 * 60;

/// The platform a release is built for, spelled the way the release names it.
pub fn platform() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("windows", "x86_64") => Some("windows-x86_64"),
        ("linux", "x86_64") => Some("linux-x86_64"),
        ("linux", "aarch64") => Some("linux-arm64"),
        ("macos", "aarch64") => Some("macos-arm64"),
        ("macos", "x86_64") => Some("macos-x86_64"),
        _ => None,
    }
}

/// The version this binary calls itself.
pub fn current() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// The latest release's version, without its `v`: `3.12.2`. None when GitHub cannot be asked; a release that is not
/// of the form `v1.2.3` counts as no answer, so a stray tag can never make everyone look out of date.
pub fn latest() -> Option<String> {
    let url = format!("https://github.com/{REPO}/releases/latest");
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(5))
        .timeout_read(Duration::from_secs(5))
        .user_agent(concat!("bla/", env!("CARGO_PKG_VERSION")))
        .redirects(0)
        .build();
    let response = match agent.head(&url).call() {
        Ok(r) => r,
        // The redirect is the answer; ureq hands a 3xx that was not followed over as a status error.
        Err(ureq::Error::Status(300..=399, r)) => r,
        Err(_) => return None,
    };
    let location = response.header("location")?;
    let tag = location.rsplit('/').next()?;
    parse_version(tag)
}

/// `v3.12.2` or `3.12.2` to `3.12.2`; anything else is not a version.
pub fn parse_version(tag: &str) -> Option<String> {
    let version = tag.strip_prefix('v').unwrap_or(tag);
    let numeric = version.split('.').count() >= 2
        && version.split(['.', '-', '+']).take(3).all(|part| part.parse::<u32>().is_ok());
    numeric.then(|| version.trim().to_string())
}

/// Whether `a` is a later version than `b`, comparing `1.2.10` above `1.2.9` and ignoring a suffix such as `-beta`.
pub fn is_newer(a: &str, b: &str) -> bool {
    let parts = |v: &str| -> Vec<u32> {
        v.split(['.', '-', '+']).map(|p| p.parse().unwrap_or(0)).collect()
    };
    let (x, y) = (parts(a), parts(b));
    for i in 0..x.len().max(y.len()) {
        let (l, r) = (*x.get(i).unwrap_or(&0), *y.get(i).unwrap_or(&0));
        if l != r {
            return l > r;
        }
    }
    false
}

/// Where the last answer is kept, so a chat that starts often doesn't ask GitHub every time.
fn state_file() -> PathBuf {
    crate::util::bla_home().join("update-check")
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// The remembered answer as (when it was asked, the tag it found), if one was kept.
fn remembered() -> Option<(u64, String)> {
    read_state(&state_file())
}

fn read_state(file: &std::path::Path) -> Option<(u64, String)> {
    let text = std::fs::read_to_string(file).ok()?;
    let (when, tag) = text.split_once(' ')?;
    Some((when.trim().parse().ok()?, tag.trim().to_string()))
}

fn remember(tag: &str) {
    // A failed write only costs another question next time.
    let _ = std::fs::create_dir_all(crate::util::bla_home());
    let _ = std::fs::write(state_file(), format!("{} {tag}\n", now()));
}

/// Why this module exists: being current is not the same as being silent. Every entry point either reports a newer
/// version or says plainly that this is the latest one. Kept apart from the asking so it can be tested.
pub fn message(running: &str, latest: &str) -> String {
    if is_newer(latest, running) {
        if let Some(by) = installer() {
            format!("bla {running}, and {latest} is out.\n\n  {by}\n\nOr download it from {RELEASES}/tag/v{latest}")
        } else if can_install() {
            format!("bla {running}, and {latest} is out.\n\nRun `bla update` to install it.")
        } else {
            // Ours, but somewhere we cannot write: the install script knows the right place.
            format!("bla {running}, and {latest} is out.\n\n  {}\n\nOr download it from {RELEASES}/tag/v{latest}", install_command())
        }
    } else if is_newer(running, latest) {
        // Nothing to tell someone this far ahead that they don't already know.
        format!("bla {running}, which is ahead of the latest release, {latest}.")
    } else {
        format!("bla {running} is the latest version.")
    }
}

/// How someone without a self-updating bla gets a newer one.
fn install_command() -> String {
    if cfg!(windows) {
        "powershell -ExecutionPolicy ByPass -c \"iex ((New-Object Net.WebClient).DownloadString('https://surak.github.io/blablador-ios/install.ps1'))\"".into()
    } else {
        "curl -fsSL https://surak.github.io/blablador-ios/install.sh | sh".into()
    }
}

/// What the version check and `bla update --check` say. `None` when GitHub cannot be asked.
pub fn report() -> Option<String> {
    let running = current();
    let Some(latest) = latest() else {
        return Some(format!(
            "bla {running}. Could not reach GitHub to see if there is a newer one; try again, or read {RELEASES}/latest."
        ));
    };
    remember(&latest);
    Some(message(running, &latest))
}

// ── updating itself ───────────────────────────────────────────────────────────────────────────────────────────────

/// Who installed this bla, when it is not ours to replace: what to run instead.
///
/// A bla that came with the Mac app lives in the app bundle and is signed with it; one from Homebrew or cargo lives in
/// that tool's store. Overwriting any of them would be undone by the next `brew upgrade` and would break a
/// verification, so those are left alone and pointed at their own updater.
fn installer() -> Option<String> {
    let path = exe_path();
    let text = path.to_string_lossy().replace('\\', "/");
    if text.contains(".app/Contents/Resources/") {
        return Some(
            "This bla came with the Blablador app, which updates itself: open the app, or run\n  \
             brew upgrade --cask surak/tap/blablador"
                .into(),
        );
    }
    for (marker, command) in [
        ("/Caskroom/", "brew upgrade --cask surak/tap/blablador"),
        ("/Cellar/", "brew upgrade bla"),
        ("/homebrew/", "brew upgrade bla"),
        ("/.cargo/bin/", "cargo install --path cli"),
    ] {
        if text.contains(marker) {
            return Some(format!("This bla was installed by another program, so it updates it too:\n  {command}"));
        }
    }
    None
}

fn exe_path() -> PathBuf {
    std::env::current_exe().and_then(std::fs::canonicalize).or_else(|_| std::env::current_exe()).unwrap_or_else(|_| PathBuf::from("bla"))
}

/// The name the release gives this platform's bare binary.
fn bare_name(version: &str, platform: &str) -> String {
    let ext = if cfg!(windows) { ".exe" } else { "" };
    format!("bla-{version}-{platform}{ext}")
}

fn download(url: &str) -> Result<Vec<u8>, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .timeout_read(Duration::from_secs(120))
        .user_agent(concat!("bla/", env!("CARGO_PKG_VERSION")))
        .build();
    let response = agent.get(url).call().map_err(|e| match e {
        ureq::Error::Status(404, _) => format!("{url}: not in this release (404)"),
        ureq::Error::Status(code, _) => format!("{url}: HTTP {code}"),
        other => format!("{url}: {other}"),
    })?;
    let mut bytes = Vec::new();
    response.into_reader().take(80 * 1024 * 1024).read_to_end(&mut bytes).map_err(|e| format!("{url}: {e}"))?;
    Ok(bytes)
}

/// The checksum SHA256SUMS.txt gives for `name`, lower case.
fn expected_sum(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|line| {
        let (sum, file) = line.split_once(char::is_whitespace)?;
        let file = file.trim().trim_start_matches('*');
        (file == name && sum.len() == 64).then(|| sum.to_lowercase())
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// Where a new binary is written before it takes the old one's place: beside it, since a rename across filesystems
/// is a copy, and a copy over a running program fails.
fn staging_path(target: &Path) -> PathBuf {
    let name = target.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "bla".into());
    target.with_file_name(format!(".{name}.new-{}", crate::util::random_hex(8)))
}

/// The bytes of a downloaded bla are written to `file` and made executable; on Unix the mode of the binary it replaces
/// is kept, so a bla in `/usr/local/bin` stays `0755`.
fn write_program(file: &Path, bytes: &[u8], like: &Path) -> Result<(), String> {
    use std::io::Write;
    let mut out = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(file)
        .map_err(|e| format!("{}: {e}", file.display()))?;
    out.write_all(bytes).and_then(|()| out.flush()).map_err(|e| format!("{}: {e}", file.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // The mode of the binary it replaces, so a bla in /usr/local/bin stays 0755; anything without an executable
        // bit (a stray copy) is made runnable rather than trusted to be.
        let mode = std::fs::metadata(like)
            .map(|m| m.permissions().mode() & 0o777)
            .ok()
            .filter(|mode| mode & 0o111 != 0)
            .unwrap_or(0o755);
        std::fs::set_permissions(file, std::fs::Permissions::from_mode(mode)).map_err(|e| format!("{}: {e}", file.display()))?;
    }
    drop(out);
    Ok(())
}

/// Replaces `target` with `staged` by a rename, which works while the old program is running: the running one keeps
/// its open file, and the next start is the new one. On Windows that rename fails while the file is in use, so the old
/// one is first moved aside and removed after the next start (Windows can delete it then, not now).
fn replace(target: &Path, staged: &Path) -> Result<(), String> {
    let aside = target.with_file_name(format!(
        "{}.old-{}",
        target.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "bla".into()),
        crate::util::random_hex(8)
    ));
    if std::fs::rename(staged, target).is_ok() {
        return Ok(());
    }
    // Windows: the running bla.exe is locked, so it is renamed out of the way first.
    std::fs::rename(target, &aside).map_err(|e| {
        let _ = std::fs::remove_file(staged);
        format!("{}: {e} (no permission? run bla from a folder you can write to, or update it the way it was installed)", target.display())
    })?;
    if let Err(e) = std::fs::rename(staged, target) {
        let _ = std::fs::rename(&aside, target);
        let _ = std::fs::remove_file(staged);
        return Err(format!("{}: {e}; the old bla was put back", target.display()));
    }
    // Leftovers from this and earlier updates go now or, on Windows, at the next start.
    sweep_old(target);
    Ok(())
}

/// Removes the `.bla.old-*` files earlier updates left behind, as far as this system allows.
pub fn sweep_old(target: &Path) {
    let (Some(dir), Some(name)) = (target.parent(), target.file_name()) else { return };
    let prefix = format!(".{}.old-", name.to_string_lossy());
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with(&prefix) {
            // Still open by the bla that wrote it (Windows, during an update): it goes on the next start.
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

/// Downloads `version` for this platform and puts it in place of the running bla. `Err` says what went wrong, in words
/// the user can act on; nothing is touched unless the download checked out and the new bla started.
pub fn install(version: &str) -> Result<String, String> {
    let platform = platform().ok_or_else(|| {
        format!("no release is built for {} {}; see {RELEASES}/latest", std::env::consts::OS, std::env::consts::ARCH)
    })?;
    if let Some(by) = installer() {
        return Err(by);
    }
    let target = exe_path();
    if !target.exists() {
        return Err(format!("cannot find the running bla ({})", target.display()));
    }

    let tag = format!("v{version}");
    let base = format!("{RELEASES}/download/{tag}");
    let name = bare_name(version, platform);
    let bytes = download(&format!("{base}/{name}"))?;
    // The checksum is not optional: without it a strange copy is not run at all.
    let sums = download(&format!("{base}/SHA256SUMS.txt"))?;
    let sums = String::from_utf8_lossy(&sums);
    let want = expected_sum(&sums, &name).ok_or_else(|| format!("{name} is not in SHA256SUMS.txt"))?;
    let got = sha256_hex(&bytes);
    if got != want {
        return Err(format!("{name} does not match SHA256SUMS.txt ({got}, expected {want}); nothing was changed"));
    }

    // Written beside the old one, started once to be sure it runs here, then renamed into place.
    let staged = staging_path(&target);
    write_program(&staged, &bytes, &target)?;
    if let Err(e) = prove(&staged, version) {
        let _ = std::fs::remove_file(&staged);
        return Err(e);
    }
    if let Err(e) = replace(&target, &staged) {
        let _ = std::fs::remove_file(&staged);
        return Err(e);
    }
    sweep_old(&target);
    remember(version);
    Ok(format!("bla {version} is installed ({})", target.display()))
}

/// Starts the new binary before it replaces a working one: a build that cannot run here (an older C library, a broken
/// download) is found now, while the old bla is still there. `--version` is answered without touching the network.
fn prove(staged: &Path, version: &str) -> Result<(), String> {
    let output = std::process::Command::new(staged)
        .arg("--version")
        .env("BLA_NO_UPDATE_CHECK", "1")
        .env("BLABLADOR_NO_KEYRING", "1")
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("the new bla {} does not start here: {e}; nothing was changed", staged.display()))?;
    let said = String::from_utf8_lossy(&output.stdout);
    let said = said.trim();
    if !said.starts_with(&format!("bla {version}")) {
        let why = String::from_utf8_lossy(&output.stderr);
        let why = why.trim();
        return Err(format!(
            "the new bla does not run here{}; nothing was changed",
            if why.is_empty() { format!(" (it said {said:?})") } else { format!(": {why}") }
        ));
    }
    Ok(())
}

/// `bla update`: look, then put the newer one in place. Says what it did, or why it could not.
pub fn update() -> String {
    let running = current();
    let Some(latest) = latest() else {
        return format!("Could not reach GitHub to look for a newer bla; try again, or read {RELEASES}/latest.");
    };
    remember(&latest);
    if !is_newer(&latest, running) {
        return message(running, &latest);
    }
    match install(&latest) {
        Ok(said) => format!("{said}. Start bla again to use it."),
        Err(why) => format!("bla {running}, and {latest} is out, but it was not installed.\n\n{why}"),
    }
}

/// Whether this bla may replace itself: it is ours, and it sits where we can write.
pub fn can_install() -> bool {
    installer().is_none() && exe_path().exists()
}

/// The start of a chat: a newer bla installs itself here and starts the chat again with it, so the user never has to
/// think about it. A bla that belongs to another installer is only mentioned once. BLA_NO_UPDATE_CHECK (never look)
/// and BLA_NO_AUTO_UPDATE (look, but don't touch) turn it off.
pub fn auto(style: &crate::util::Style) {
    if std::env::var_os("BLA_NO_AUTO_UPDATE").is_some() {
        return;
    }
    let Some(version) = due() else { return };
    if !can_install() {
        let line = message(current(), &version).replace('\n', "\n  ");
        eprintln!("{}", style.yellow(&format!("bla: {line}")));
        return;
    }
    eprintln!("{}", style.dim(&format!("bla: installing bla {version}…")));
    match install(&version) {
        Ok(said) => {
            eprintln!("{}", style.green(&format!("bla: {said}")));
            hand_over();
        }
        // The old bla works: say what happened and carry on rather than keeping the user out of their chat.
        Err(why) => eprintln!("{}", style.yellow(&format!("bla: could not update to {version}: {why}"))),
    }
}

/// Starts this chat again as the new binary, which by now is what this path points to.
fn hand_over() -> ! {
    let exe = exe_path();
    let args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    let status = std::process::Command::new(&exe).args(&args).status();
    std::process::exit(match status {
        Ok(s) => s.code().unwrap_or(0),
        Err(e) => {
            eprintln!("bla {} is installed; start it again to use it ({e}).", current());
            0
        }
    });
}

/// The latest version, from the remembered answer while it is fresh and from GitHub otherwise. Used where waiting on
/// the network would be rude (`bla -v`).
pub fn latest_if_stale() -> Option<String> {
    match remembered() {
        Some((when, tag)) if now().saturating_sub(when) < REMEMBER => Some(tag),
        _ => latest().inspect(|tag| remember(tag)),
    }
}

/// For the start of a chat: whether there is something newer to say, and whether bla may put it in place itself.
/// Hidden by BLA_NO_UPDATE_CHECK, for whoever would rather bla never phoned home.
pub fn due() -> Option<String> {
    if std::env::var_os("BLA_NO_UPDATE_CHECK").is_some() {
        return None;
    }
    let tag = latest_if_stale()?;
    is_newer(&tag, current()).then_some(tag)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_as_numbers() {
        assert!(is_newer("3.12.2", "3.12.1"));
        assert!(is_newer("3.13.0", "3.12.9"));
        assert!(is_newer("4.0.0", "3.99.99"));
        assert!(!is_newer("3.12.1", "3.12.1"));
        assert!(!is_newer("3.12.1", "3.12.2"));
        // 10 is above 9; read as text it would not be.
        assert!(is_newer("1.2.10", "1.2.9"));
        assert!(!is_newer("1.2.9", "1.2.10"));
        // A suffix such as -beta or +build must not hide a newer version.
        assert!(is_newer("3.13.0-beta", "3.12.1"));
    }

    #[test]
    fn tags_become_versions_and_nonsense_does_not() {
        assert_eq!(parse_version("v3.12.2"), Some("3.12.2".into()));
        assert_eq!(parse_version("3.12.2"), Some("3.12.2".into()));
        assert_eq!(parse_version("v3.12.2-beta.1").as_deref(), Some("3.12.2-beta.1"));
        assert_eq!(parse_version("latest"), None);
        assert_eq!(parse_version("v3"), None);
        assert_eq!(parse_version(""), None);
    }

    #[test]
    fn being_current_is_said_out_loud() {
        // The point of the module: no silence, ever.
        let said = message("3.12.1", "3.12.1");
        assert!(said.contains("3.12.1") && said.contains("latest"), "{said}");

        let newer = message("3.12.1", "3.12.2");
        assert!(newer.contains("3.12.2 is out"), "{newer}");
        assert!(newer.contains("bla update"), "{newer}");

        let ahead = message("3.13.0", "3.12.2");
        assert!(ahead.contains("ahead of the latest release"), "{ahead}");
    }

    /// A test binary lives in `target/debug`, not in a cask, a cargo install or an app bundle, so it may update itself
    /// and is pointed at `bla update` rather than at the install script.
    #[test]
    fn a_bla_of_our_own_may_update_itself() {
        assert_eq!(installer(), None, "{}", exe_path().display());
        assert!(can_install());
        let newer = message("3.12.1", "3.12.2");
        assert!(newer.contains("`bla update`"), "{newer}");
        assert!(!newer.contains("install.sh"), "{newer}");
    }

    #[test]
    fn the_bare_binary_is_named_the_way_the_release_names_it() {
        assert_eq!(bare_name("3.12.2", "linux-arm64"), if cfg!(windows) { "bla-3.12.2-linux-arm64.exe" } else { "bla-3.12.2-linux-arm64" });
        assert_eq!(platform().is_some(), cfg!(any(windows, target_os = "linux", target_os = "macos")));
    }

    #[test]
    fn a_checksum_is_read_from_sums_or_not_at_all() {
        let sums = "aaa\n\
                   0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  Blablador-3.12.2-bla-linux-arm64.tar.gz\n\
                   fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210 *bla-3.12.2-linux-arm64\n";
        assert_eq!(expected_sum(sums, "bla-3.12.2-linux-arm64").as_deref(), Some("fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"));
        assert_eq!(expected_sum(sums, "bla-3.12.2-windows-x86_64.exe"), None, "another platform's file is not our answer");
        // A line that is not a checksum must not be read as one.
        assert_eq!(expected_sum("0123  bla-3.12.2-linux-arm64\n", "bla-3.12.2-linux-arm64"), None);
        assert_eq!(expected_sum("", "bla-3.12.2-linux-arm64"), None);
    }

    #[test]
    fn a_sha256_is_the_one_sha256sum_prints() {
        assert_eq!(sha256_hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    /// The whole point of writing beside the binary: the running bla is replaced by a rename, so an update while bla is
    /// open is not "text file busy". Nothing outside the test's own folder is touched.
    #[test]
    fn a_new_binary_takes_the_old_ones_place() {
        let dir = std::env::temp_dir().join(format!("bla-update-{}", crate::util::random_hex(8)));
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join(if cfg!(windows) { "bla.exe" } else { "bla" });
        std::fs::write(&target, b"old").unwrap();
        let staged = staging_path(&target);
        assert_eq!(staged.parent(), target.parent(), "written beside the old one, never in /tmp");
        assert_ne!(staged, target);
        assert!(staged.file_name().unwrap().to_string_lossy().starts_with('.'), "hidden while it downloads");

        write_program(&staged, b"new", &target).unwrap();
        assert_eq!(std::fs::read(&staged).unwrap(), b"new");
        assert_eq!(std::fs::read(&target).unwrap(), b"old", "the old one stays until the new one is whole");
        replace(&target, &staged).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        assert!(!staged.exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert!(std::fs::metadata(&target).unwrap().permissions().mode() & 0o111 != 0, "still runnable");
        }

        // Leftovers of an earlier update are swept away.
        let leftover = dir.join(format!(".{}.old-abc", target.file_name().unwrap().to_string_lossy()));
        std::fs::write(&leftover, b"old").unwrap();
        sweep_old(&target);
        assert!(!leftover.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A download that is not what SHA256SUMS.txt promises is never written over a working bla.
    #[test]
    fn the_new_binary_has_to_prove_itself_before_it_is_used() {
        let dir = std::env::temp_dir().join(format!("bla-prove-{}", crate::util::random_hex(8)));
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join(if cfg!(windows) { "bla.exe" } else { "bla" });
        std::fs::write(&target, b"the working one").unwrap();

        // Nothing that is not a program.
        let junk = staging_path(&target);
        write_program(&junk, b"not a program at all\n", &target).unwrap();
        let refused = prove(&junk, "3.12.2").unwrap_err();
        assert!(refused.contains("does not run here"), "{refused}");
        assert!(refused.contains("nothing was changed"), "{refused}");
        assert_eq!(std::fs::read(&target).unwrap(), b"the working one");

        // A program that runs but is not the version it claims (a stray download, a wrong platform) is refused too.
        #[cfg(unix)]
        {
            let wrong = staging_path(&target);
            write_program(&wrong, b"#!/bin/sh\necho bla 3.11.0\n", &target).unwrap();
            assert!(prove(&wrong, "3.12.2").is_err());

            let right = staging_path(&target);
            write_program(&right, b"#!/bin/sh\necho bla 3.12.2\n", &target).unwrap();
            assert!(prove(&right, "3.12.2").is_ok());
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_remembered_answer_survives_and_expires() {
        let file = std::env::temp_dir().join(format!("bla-update-check-{}", crate::util::random_hex(8)));
        assert_eq!(read_state(&file), None, "a missing file is not an answer");
        std::fs::write(&file, "1700000000 3.12.2\n").unwrap();
        assert_eq!(read_state(&file), Some((1700000000, "3.12.2".into())));
        // Nonsense on disk must not be read as an old version.
        std::fs::write(&file, "nonsense\n").unwrap();
        assert_eq!(read_state(&file), None);
        let _ = std::fs::remove_file(&file);
    }
}
