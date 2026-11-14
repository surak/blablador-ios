//! Small helpers shared by the core and the plugins: paths, globs, truncation, time and running programs.

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::io::{IsTerminal, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Variables a child process never sees: the API key stays with bla.
pub const SECRET_ENV: &[&str] = &["BLABLADOR_API_KEY"];

pub fn home() -> PathBuf {
    directories::BaseDirs::new().map(|d| d.home_dir().to_path_buf()).unwrap_or_else(|| PathBuf::from("."))
}

/// `~/.bla`, or `BLA_HOME`: settings, sessions, skills, memory and plugins.
pub fn bla_home() -> PathBuf {
    #[cfg(test)]
    return test_home();
    #[cfg(not(test))]
    std::env::var_os("BLA_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".bla"))
}

/// One home for the whole test run: tests run in parallel, so they must not change the environment.
#[cfg(test)]
pub fn test_home() -> PathBuf {
    static HOME: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    HOME.get_or_init(|| std::env::temp_dir().join(format!("bla-test-home-{}", random_hex(8)))).clone()
}

/// A path the model gave, relative to the working directory, with `~` expanded and `.`/`..` folded.
pub fn resolve(cwd: &Path, path: &str) -> PathBuf {
    let path = path.trim();
    let joined = if let Some(rest) = path.strip_prefix("~/") {
        home().join(rest)
    } else if path == "~" {
        home()
    } else if Path::new(path).is_absolute() {
        PathBuf::from(path)
    } else {
        cwd.join(path)
    };
    let mut out = PathBuf::new();
    for part in joined.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

/// The path with symlinks resolved as far as it exists, so a link can't lead out of the workspace unseen.
pub fn real_path(path: &Path) -> PathBuf {
    let mut existing = path.to_path_buf();
    let mut rest = Vec::new();
    while !existing.exists() {
        match (existing.file_name().map(|n| n.to_os_string()), existing.parent()) {
            (Some(name), Some(parent)) => {
                rest.push(name);
                existing = parent.to_path_buf();
            }
            _ => break,
        }
    }
    let mut real = existing.canonicalize().unwrap_or(existing);
    for name in rest.into_iter().rev() {
        real.push(name);
    }
    real
}

/// Whether `path` is inside `root` once symlinks are resolved.
pub fn inside(root: &Path, path: &Path) -> bool {
    real_path(path).starts_with(real_path(root))
}

/// The path as the user thinks of it: relative to the working directory when inside it.
pub fn display_path(cwd: &Path, path: &Path) -> String {
    match path.strip_prefix(cwd) {
        Ok(rel) if !rel.as_os_str().is_empty() => rel.display().to_string(),
        Ok(_) => ".".into(),
        Err(_) => path.display().to_string(),
    }
}

/// Glob match. `*` and `?` stay within one path segment when `paths` is set, `**` crosses them;
/// without `paths` (commands) `*` matches anything.
pub fn glob_match(pattern: &str, text: &str, paths: bool) -> bool {
    let (p, t) = (pattern.as_bytes(), clip(text, 64 * 1024).as_bytes());
    // memo[i * (t.len() + 1) + j]: does p[i..] match t[j..]? Keeps it O(pattern × text).
    let mut memo = vec![None; (p.len() + 1) * (t.len() + 1)];
    fn go(p: &[u8], t: &[u8], i: usize, j: usize, paths: bool, memo: &mut Vec<Option<bool>>) -> bool {
        let key = i * (t.len() + 1) + j;
        if let Some(known) = memo[key] {
            return known;
        }
        let result = if i == p.len() {
            j == t.len()
        } else if p[i] == b'*' {
            let deep = !paths || p.get(i + 1) == Some(&b'*');
            let mut next = i + 1;
            while next < p.len() && p[next] == b'*' {
                next += 1;
            }
            // `**/` also matches no folder at all.
            (deep && paths && p.get(next) == Some(&b'/') && go(p, t, next + 1, j, paths, memo))
                || (j..=t.len()).take_while(|&k| deep || k == j || t[k - 1] != b'/').any(|k| go(p, t, next, k, paths, memo))
        } else if j < t.len() && (p[i] == t[j] || (p[i] == b'?' && !(paths && t[j] == b'/'))) {
            go(p, t, i + 1, j + 1, paths, memo)
        } else {
            false
        };
        memo[key] = Some(result);
        result
    }
    go(p, t, 0, 0, paths, &mut memo)
}

/// Keeps the end of long output (where errors are), at most `max_lines` and `max_bytes`.
pub fn truncate_tail(text: &str, max_lines: usize, max_bytes: usize) -> (String, bool) {
    let lines: Vec<&str> = text.lines().collect();
    let mut kept = Vec::new();
    let mut bytes = 0;
    for line in lines.iter().rev() {
        if kept.len() == max_lines || bytes + line.len() + 1 > max_bytes {
            break;
        }
        bytes += line.len() + 1;
        kept.push(*line);
    }
    let cut = kept.len() < lines.len();
    kept.reverse();
    (kept.join("\n"), cut)
}

/// Cuts `text` to at most `max` bytes on a character boundary.
pub fn clip(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

pub fn random_hex(len: usize) -> String {
    let mut out = String::new();
    while out.len() < len {
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_u128(SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
        out.push_str(&format!("{:016x}", hasher.finish()));
    }
    out.truncate(len);
    out
}

/// (year, month, day, hour, minute, second) in UTC.
pub fn utc_now() -> (i64, u32, u32, u32, u32, u32) {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    // Howard Hinnant's civil-from-days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day, (rem / 3600) as u32, (rem % 3600 / 60) as u32, (rem % 60) as u32)
}

pub fn today() -> String {
    let (y, m, d, ..) = utc_now();
    format!("{y:04}-{m:02}-{d:02}")
}

pub fn timestamp() -> String {
    let (y, mo, d, h, mi, s) = utc_now();
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

/// The shell for `bash` tool calls and hooks.
pub fn shell() -> (String, &'static str) {
    if cfg!(windows) {
        ("cmd".into(), "/C")
    } else if Path::new("/bin/bash").exists() {
        ("/bin/bash".into(), "-c")
    } else {
        ("/bin/sh".into(), "-c")
    }
}

pub struct Finished {
    /// None when killed: timed out or cancelled.
    pub code: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub timed_out: bool,
}

/// Runs a program with `input` on stdin, without the API key in its environment, until it ends,
/// `timeout` passes or `cancel` is set.
pub fn run(mut command: Command, input: &[u8], timeout: Duration, cancel: &AtomicBool) -> std::io::Result<Finished> {
    for name in SECRET_ENV {
        command.env_remove(name);
    }
    // Its own process group, so a timeout or Ctrl-C stops what it started in the background too.
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
    let mut stdin = child.stdin.take();
    let input = input.to_vec();
    std::thread::spawn(move || {
        if let Some(stdin) = stdin.as_mut() {
            let _ = stdin.write_all(&input);
        }
    });
    // The readers collect as they go: a background grandchild may hold the pipes open long after the shell ends.
    fn collect(pipe: Option<impl Read + Send + 'static>) -> (std::sync::Arc<std::sync::Mutex<Vec<u8>>>, std::sync::mpsc::Receiver<()>) {
        let buf = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let (done, finished) = std::sync::mpsc::channel();
        let shared = buf.clone();
        std::thread::spawn(move || {
            if let Some(mut pipe) = pipe {
                let mut chunk = [0u8; 8192];
                while let Ok(n) = pipe.read(&mut chunk) {
                    if n == 0 {
                        break;
                    }
                    shared.lock().unwrap().extend_from_slice(&chunk[..n]);
                }
            }
            let _ = done.send(());
        });
        (buf, finished)
    }
    let (out, out_done) = collect(child.stdout.take());
    let (err, err_done) = collect(child.stderr.take());
    let start = Instant::now();
    let mut timed_out = false;
    let pid = child.id();
    let code = loop {
        if let Some(status) = child.try_wait()? {
            break status.code();
        }
        timed_out = start.elapsed() > timeout;
        if timed_out || cancel.load(Ordering::Relaxed) {
            kill_group(pid);
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    let grace = Duration::from_millis(if code.is_some() { 500 } else { 100 });
    let _ = out_done.recv_timeout(grace);
    let _ = err_done.recv_timeout(grace);
    let stdout = std::mem::take(&mut *out.lock().unwrap());
    let stderr = std::mem::take(&mut *err.lock().unwrap());
    Ok(Finished { code, stdout, stderr, timed_out })
}

/// Stops a whole process group (Unix); without `unsafe`, through kill(1).
pub fn kill_group(pid: u32) {
    #[cfg(unix)]
    {
        // `--` matters: without it, procps kill (Ubuntu 22.04) misreads `-<pgid>` and kills its own group.
        let _ = Command::new("kill").args(["-s", "KILL", "--", &format!("-{pid}")]).stdout(Stdio::null()).stderr(Stdio::null()).status();
    }
    #[cfg(not(unix))]
    let _ = pid;
}

/// ANSI styling, off when the stream isn't a terminal or NO_COLOR is set.
pub struct Style {
    pub on: bool,
}

impl Style {
    pub fn stderr() -> Style {
        Style { on: std::io::stderr().is_terminal() && std::env::var_os("NO_COLOR").is_none() }
    }

    pub fn stdout() -> Style {
        Style { on: std::io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none() }
    }

    fn wrap(&self, code: &str, text: &str) -> String {
        if self.on {
            format!("\x1b[{code}m{text}\x1b[0m")
        } else {
            text.to_string()
        }
    }

    pub fn dim(&self, text: &str) -> String {
        self.wrap("2", text)
    }
    pub fn bold(&self, text: &str) -> String {
        self.wrap("1", text)
    }
    pub fn red(&self, text: &str) -> String {
        self.wrap("31", text)
    }
    pub fn green(&self, text: &str) -> String {
        self.wrap("32", text)
    }
    pub fn yellow(&self, text: &str) -> String {
        self.wrap("33", text)
    }
    pub fn cyan(&self, text: &str) -> String {
        self.wrap("36", text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn globs() {
        assert!(glob_match("src/*.rs", "src/main.rs", true));
        assert!(!glob_match("src/*.rs", "src/a/main.rs", true));
        assert!(glob_match("src/**/*.rs", "src/a/b/main.rs", true));
        assert!(glob_match("src/**/*.rs", "src/main.rs", true));
        assert!(glob_match("**", "a/b/c", true));
        assert!(glob_match(".env*", ".env.local", true));
        assert!(glob_match("git *", "git status --short", false));
        assert!(!glob_match("git *", "gitk", false));
        assert!(glob_match("rm -rf *", "rm -rf /tmp/x", false));
        assert!(glob_match("a?c", "abc", true));
        assert!(glob_match("*.rs", "main.rs", true));
        assert!(!glob_match("*.rs", "src/main.rs", true));
        assert!(glob_match("src/**", "src/a/b", true));
        assert!(glob_match("npm run test*", "npm run test:unit", false));
    }

    #[test]
    fn resolves_paths() {
        let cwd = Path::new("/work/project");
        assert_eq!(resolve(cwd, "src/../README.md"), PathBuf::from("/work/project/README.md"));
        assert_eq!(resolve(cwd, "../other"), PathBuf::from("/work/other"));
        assert_eq!(resolve(cwd, "/etc/hosts"), PathBuf::from("/etc/hosts"));
        assert_eq!(display_path(cwd, Path::new("/work/project/a/b")), "a/b");
    }

    #[test]
    fn truncates_from_the_end() {
        let text = (1..=10).map(|n| n.to_string()).collect::<Vec<_>>().join("\n");
        let (kept, cut) = truncate_tail(&text, 3, 1000);
        assert_eq!(kept, "8\n9\n10");
        assert!(cut);
        assert_eq!(clip("héllo", 2), "h");
    }

    #[test]
    fn dates() {
        let (y, m, d, ..) = utc_now();
        assert!(y >= 2024 && (1..=12).contains(&m) && (1..=31).contains(&d));
        assert_eq!(random_hex(20).len(), 20);
    }
}
