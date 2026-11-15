//! Whether a newer bla has been released. bla doesn't update itself — the install script does, and it replaced a
//! binary that might be in use — so this only looks and says what it found.
//!
//! Two ways in: the tag in the version check or `bla update`, which say what they found or that there is nothing
//! newer. The third, a question in this folder, only speaks when there is something to say: a line at the start of
//! a new chat, at most once every few hours. Failing to ask GitHub is never mentioned; it is not the user's problem
//! that their train has no signal.
//!
//! The check asks the `releases/latest` redirect for its tag instead of the API: no token, so no rate limit shared
//! with whoever else is behind the same address.

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const REPO: &str = "surak/blablador-ios";
pub const RELEASES: &str = "https://github.com/surak/blablador-ios/releases";

/// How long an answer, including "you are current", is trusted before asking again.
const REMEMBER: u64 = 6 * 60 * 60;

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
        format!(
            "bla {running}, and {latest} is out.\n\n  curl -fsSL https://surak.github.io/blablador-ios/install.sh | sh\n\n\
             Or download it from {RELEASES}/tag/v{latest}\n\
             If you installed it with cargo, brew or a package of your own, update it the same way."
        )
    } else if is_newer(running, latest) {
        // Nothing to tell someone this far ahead that they don't already know.
        format!("bla {running}, which is ahead of the latest release, {latest}.")
    } else {
        format!("bla {running} is the latest version.")
    }
}

/// What the version check and `bla update` say. `None` when GitHub cannot be asked.
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

/// The latest version, from the remembered answer while it is fresh and from GitHub otherwise. Used where waiting on
/// the network would be rude (`bla -v`).
pub fn latest_if_stale() -> Option<String> {
    match remembered() {
        Some((when, tag)) if now().saturating_sub(when) < REMEMBER => Some(tag),
        _ => latest().inspect(|tag| remember(tag)),
    }
}

/// For the start of a chat: a line when a newer release is out, and nothing at all otherwise. Hidden by
/// BLA_NO_UPDATE_CHECK, for whoever would rather bla never phoned home.
pub fn notice() -> Option<String> {
    let tag = latest_if_stale()?;
    one_line(current(), &tag, std::env::var_os("BLA_NO_UPDATE_CHECK").is_none())
}

/// The line itself: quiet when there is nothing newer to say, or when asked to be quiet.
fn one_line(running: &str, tag: &str, wanted: bool) -> Option<String> {
    (wanted && is_newer(tag, running))
        .then(|| format!("bla {tag} is out; you have {running}. Run `bla update` for how to get it."))
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
        assert!(!said.contains("install.sh"), "{said}");

        let newer = message("3.12.1", "3.12.2");
        assert!(newer.contains("3.12.2 is out"), "{newer}");
        assert!(newer.contains("install.sh"), "{newer}");
        assert!(newer.contains("tag/v3.12.2"), "{newer}");

        let ahead = message("3.13.0", "3.12.2");
        assert!(ahead.contains("ahead of the latest release"), "{ahead}");
        assert!(!ahead.contains("install.sh"), "{ahead}");
    }

    #[test]
    fn the_chat_line_speaks_only_when_there_is_news() {
        assert_eq!(one_line("3.12.1", "3.12.1", true), None, "current: say nothing in a chat");
        assert_eq!(one_line("3.13.0", "3.12.1", true), None, "ahead of the release: nothing to say");
        assert_eq!(one_line("3.12.1", "3.12.2", false), None, "asked to be quiet");
        let line = one_line("3.12.1", "3.12.2", true).unwrap();
        assert!(line.contains("3.12.2 is out") && line.contains("you have 3.12.1"), "{line}");
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
