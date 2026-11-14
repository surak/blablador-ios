//! bla: Blablador on the command line. A small, fast coding agent where everything is a plugin.
#![forbid(unsafe_code)]

mod agent;
mod config;
mod llm;
mod plugin;
mod plugins;
mod secret;
mod session;
mod tui;
mod ui;
mod util;

use agent::Agent;
use config::Settings;
use plugin::{CommandResult, Host};
use plugins::permissions::Mode;
use session::Session;
use std::io::{IsTerminal, Read};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use ui::Ui;
use util::Style;

const USAGE: &str = "Usage: bla [options] [question…]
       bla login | logout | sessions | plugins | trust

Asks Blablador and lets it work in the current folder: read, edit and write files and run commands,
asking before it changes anything. Text piped in is added to the question:
  git diff | bla \"write a commit message\"
Without a question in a terminal, starts a chat.

Options:
  -m, --model ID        model to use
  -e, --effort LEVEL    thinking effort: off, low, medium, high or max
  -s, --system TEXT     extra instructions for the model
  -t, --thinking        show the model's thinking
  -c, --continue        continue the last session in this folder
  -r, --resume ID       resume a session (see bla sessions)
      --mode MODE       permissions: default, accept-edits, plan or yolo
  -y, --yes             approve everything that would ask (careful)
      --no-tools        just answer, without tools
      --no-plugin NAME  turn a plugin off for this run (repeatable)
      --json            write events as JSON lines (for scripts)
  -l, --models          list the models
  -v, --version         show the version
  -h, --help            show this help

In a chat: /help lists commands, !command runs a shell command, @file attaches a file,
Ctrl-C stops the answer, Ctrl-D quits.";

#[derive(Default)]
struct Args {
    model: Option<String>,
    effort: Option<String>,
    system: Option<String>,
    thinking: bool,
    continue_last: bool,
    resume: Option<String>,
    mode: Option<String>,
    yes: bool,
    no_tools: bool,
    disabled: Vec<String>,
    json: bool,
    list_models: bool,
    words: Vec<String>,
}

fn parse(argv: Vec<String>) -> Result<Args, String> {
    let mut a = Args::default();
    let mut it = argv.into_iter();
    let value = |it: &mut std::vec::IntoIter<String>, flag: &str| it.next().ok_or(format!("{flag} needs a value"));
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "-m" | "--model" => a.model = Some(value(&mut it, &arg)?),
            "-e" | "--effort" => {
                let level = value(&mut it, &arg)?.to_lowercase();
                if !["off", "low", "medium", "high", "max"].contains(&level.as_str()) {
                    return Err("effort is off, low, medium, high or max".into());
                }
                a.effort = Some(level);
            }
            "-s" | "--system" => a.system = Some(value(&mut it, &arg)?),
            "-t" | "--thinking" => a.thinking = true,
            "-c" | "--continue" => a.continue_last = true,
            "-r" | "--resume" => a.resume = Some(value(&mut it, &arg)?),
            "--mode" => a.mode = Some(value(&mut it, &arg)?),
            "-y" | "--yes" => a.yes = true,
            "--no-tools" => a.no_tools = true,
            "--no-plugin" => a.disabled.push(value(&mut it, &arg)?),
            "--json" => a.json = true,
            "-l" | "--models" => a.list_models = true,
            "-h" | "--help" => return Err(USAGE.into()),
            "-v" | "--version" => return Err(format!("bla {}", env!("CARGO_PKG_VERSION"))),
            "--" => a.words.extend(it.by_ref()),
            _ if arg.starts_with('-') && arg.len() > 1 => return Err(format!("Unknown option {arg}.\n\n{USAGE}")),
            _ => a.words.push(arg),
        }
    }
    Ok(a)
}

fn fail(message: &str) -> ! {
    eprintln!("{}", Style::stderr().red(message));
    std::process::exit(1)
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    // The old Swift bla was started with --cli; accept and ignore it.
    let argv: Vec<String> = argv.into_iter().filter(|a| a != "--cli").collect();
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let cwd = cwd.canonicalize().unwrap_or(cwd);

    if argv.len() == 1 {
        match argv[0].as_str() {
            "login" => return login(),
            "logout" => {
                secret::delete();
                println!("The key is removed.");
                return;
            }
            "sessions" => return list_sessions(),
            "plugins" => return list_plugins(&cwd),
            "trust" => {
                let root = config::project_root(&cwd);
                match Settings::trust(&root) {
                    Ok(()) => println!("Trusted {}: its .bla/settings.json, hooks, plugins and skills are used.", root.display()),
                    Err(e) => fail(&e),
                }
                return;
            }
            _ => {}
        }
    }

    let args = match parse(argv) {
        Ok(a) => a,
        Err(text) if text == USAGE || text.starts_with("bla ") => {
            println!("{text}");
            return;
        }
        Err(text) => fail(&text),
    };
    // A resumed session runs in its own folder, with that folder's settings, trust and plugins.
    let resumed = if let Some(id) = &args.resume {
        Some(Session::open(id).unwrap_or_else(|e| fail(&e)))
    } else if args.continue_last {
        match Session::last_in(&cwd) {
            Some(id) => Some(Session::open(&id).unwrap_or_else(|e| fail(&e))),
            None => fail("No earlier session in this folder."),
        }
    } else {
        None
    };
    let cwd = match &resumed {
        Some(s) if s.cwd != cwd => {
            if std::env::set_current_dir(&s.cwd).is_err() {
                fail(&format!("The session's folder {} is gone.", s.cwd.display()));
            }
            s.cwd.clone()
        }
        _ => cwd,
    };
    let settings = Settings::load(&cwd).unwrap_or_else(|e| fail(&e));
    let mode = match args.mode.as_deref().or(settings.permissions.mode.as_deref()) {
        Some(m) => Mode::parse(m).unwrap_or_else(|| fail("Modes: default, accept-edits, plan, yolo")),
        None => Mode::Default,
    };
    let mut disabled = args.disabled.clone();
    if args.no_tools {
        disabled.extend(["core-tools", "skills", "memory", "checkpoints", "blablador", "mcp", "web", "agents", "processes"].map(String::from));
    }
    let (plugins, warnings) =
        plugins::load(plugins::Options { settings: &settings, cwd: &cwd, api_key: secret::api_key().unwrap_or_default(),
        model: args.model.clone().unwrap_or_else(|| settings.model.clone()), mode, disabled: &disabled });
    let host = Host::new(plugins);
    let style = Style::stderr();
    for w in warnings.iter().chain(&host.warnings) {
        eprintln!("{}", style.yellow(&format!("bla: {w}")));
    }
    let Some(provider) = host.provider(&settings.provider) else { fail("No model provider: the openai plugin is off or failed to start.") };

    if args.list_models {
        match provider.models() {
            // The endpoint lists its tools next to its chat models; say which is which.
            Ok(models) => models.iter().for_each(|m| match blablador_models::kind(m) {
                blablador_models::Kind::Chat => println!("{m}"),
                other => println!("{m}  ({})", other.name()),
            }),
            Err(e) => fail(&e),
        }
        return;
    }

    // The question: words, plus whatever is piped in.
    let mut question = args.words.join(" ");
    let stdin_tty = std::io::stdin().is_terminal();
    if !stdin_tty {
        let mut piped = String::new();
        let _ = std::io::stdin().read_to_string(&mut piped);
        if !piped.trim().is_empty() {
            question = if question.is_empty() { piped } else { format!("{question}\n\n```\n{}\n```", piped.trim_end()) };
        }
    }
    let chat = question.trim().is_empty();
    if chat && !stdin_tty {
        fail(USAGE);
    }

    let session = resumed.unwrap_or_else(|| Session::new(&cwd, args.model.as_deref().unwrap_or(&settings.model)));

    let mut agent = Agent::new(host, provider, session, args.model.clone().unwrap_or_else(|| settings.model.clone()));
    agent.effort = args.effort.clone().or(settings.effort.clone());
    agent.max_steps = settings.max_steps.max(1);
    agent.interactive = chat;
    agent.yes = args.yes;
    agent.instructions = args.system.clone();

    // Ctrl-C stops the current answer; twice within a second quits.
    let cancel = agent.cancel.clone();
    let busy = Arc::new(AtomicBool::new(false));
    let last = Arc::new(AtomicU64::new(0));
    {
        let (busy, last) = (busy.clone(), last.clone());
        let _ = ctrlc::set_handler(move || {
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
            if !busy.load(Ordering::Relaxed) || now.saturating_sub(last.swap(now, Ordering::Relaxed)) < 1000 {
                eprintln!();
                std::process::exit(130);
            }
            cancel.store(true, Ordering::Relaxed);
        });
    }

    if chat {
        run_chat(&mut agent, &settings, &busy, args.thinking);
    } else {
        let mut ui: Box<dyn Ui> = if args.json { Box::new(ui::Json) } else { Box::new(ui::Terminal::new(false, args.thinking)) };
        busy.store(true, Ordering::Relaxed);
        let result = agent.turn(&question, ui.as_mut());
        agent.finish();
        if let Err(e) = result {
            ui.error(&e);
            std::process::exit(1);
        }
    }
}

fn login() {
    let key = if std::io::stdin().is_terminal() {
        eprintln!("Paste your Blablador API key (from https://sdlaml.pages.jsc.fz-juelich.de/ai/guides/blablador_api_access/):");
        rpassword::read_password().unwrap_or_default()
    } else {
        let mut k = String::new();
        let _ = std::io::stdin().read_to_string(&mut k);
        k
    };
    match secret::save(&key) {
        Ok(place) => println!("Saved the key in {place}."),
        Err(e) => fail(&e),
    }
}

/// `text` padded to `width` columns, then styled: escape codes don't count as columns.
fn padded(text: &str, width: usize, paint: impl Fn(&str) -> String) -> String {
    let pad = width.saturating_sub(text.chars().count());
    format!("{}{}", paint(text), " ".repeat(pad))
}

fn ago(t: std::time::SystemTime) -> String {
    let s = std::time::SystemTime::now().duration_since(t).map(|d| d.as_secs()).unwrap_or(0);
    match s {
        0..=59 => "just now".into(),
        60..=3599 => format!("{} min ago", s / 60),
        3600..=86_399 => format!("{} h ago", s / 3600),
        _ => format!("{} days ago", s / 86_400),
    }
}

fn list_sessions() {
    let style = Style::stdout();
    for s in Session::list().into_iter().take(30) {
        println!("{}  {:<12} {}  {}", style.bold(&s.id), ago(s.modified), s.title, style.dim(&s.cwd));
    }
}

fn sessions_text() -> String {
    Session::list().into_iter().take(30).map(|s| format!("{}  {:<12} {}  {}", s.id, ago(s.modified), s.title, s.cwd)).collect::<Vec<_>>().join("\n")
}

fn list_plugins(cwd: &std::path::Path) {
    let style = Style::stdout();
    let settings = Settings::load(cwd).unwrap_or_default();
    for (name, description) in plugins::BUILT_IN {
        let off = settings.plugins.disabled.iter().any(|d| d == name);
        println!("{} {} {}", padded(name, 13, |t| style.bold(t)), if off { style.red("off") } else { style.green("on ") }, description);
    }
    for e in &settings.plugins.external {
        println!("{} {} {}", padded(&e.name, 13, |t| style.bold(t)), style.cyan("ext"), e.command.join(" "));
    }
    let mut dirs = vec![util::bla_home().join("plugins")];
    if settings.project_trusted {
        dirs.push(config::project_root(cwd).join(".bla").join("plugins"));
    }
    for dir in dirs {
        for (name, description, command, _) in plugins::external::manifests(&dir) {
            println!("{} {} {}", padded(&name, 13, |t| style.bold(t)), style.cyan("ext"), if description.is_empty() { command.join(" ") } else { description });
        }
    }
    if !settings.project_trusted && config::project_root(cwd).join(".bla").exists() {
        println!("\n{}", style.dim("This project has a .bla folder; its hooks, plugins and skills are used once you run `bla trust`."));
    }
}

const CHAT_HELP: &str = "/help         this list
/new          start a new session
/sessions     recent sessions
/resume ID    continue a session
/model [ID]   show or change the model
/models       list the models
/effort LEVEL thinking effort: off, low, medium, high, max
/tools        the tools the model has
/plugins      the plugins that are on
/exit         quit (or Ctrl-D)
!command      run a shell command and show the model its output
@path         attach a file to your message";

fn run_chat(agent: &mut Agent, settings: &Settings, busy: &AtomicBool, thinking: bool) {
    let _ = thinking;
    let mut screen = match tui::Screen::open(agent.cancel.clone(), util::bla_home().join("history")) {
        Ok(s) => s,
        Err(e) => fail(&e),
    };
    agent.start();
    let cwd = util::display_path(&util::home(), &agent.session.cwd);
    let mut lines = vec![
        agent.model.clone(),
        cwd.clone(),
        String::new(),
        "/help commands · @file attaches · !cmd runs a shell command".into(),
        "Esc stops · Ctrl-O opens all tool output · Ctrl-C twice quits".into(),
    ];
    if !agent.session.messages.is_empty() {
        lines.push(format!("Resumed {} ({} messages).", agent.session.id, agent.session.messages.len()));
    }
    if !settings.project_trusted && config::project_root(&agent.session.cwd).join(".bla").exists() {
        lines.push("This project has a .bla folder; its hooks and plugins are ignored until `bla trust`.".into());
    }
    screen.welcome(lines);
    screen.set_info(&agent.model, agent.effort.as_deref(), &cwd);
    let mut commands: Vec<(String, String)> = CHAT_HELP
        .lines()
        .filter_map(|l| l.strip_prefix('/'))
        .map(|l| {
            let (name, help) = l.split_once(' ').unwrap_or((l, ""));
            (name.to_string(), help.trim().to_string())
        })
        .collect();
    for (_, c) in agent.host.commands() {
        commands.push((c.name.to_string(), c.help.to_string()));
    }
    commands.sort();
    screen.set_commands(commands);

    loop {
        busy.store(false, Ordering::Relaxed);
        let Some(line) = screen.read_line() else {
            break;
        };
        let input = line.trim();
        if input.is_empty() {
            continue;
        }
        busy.store(true, Ordering::Relaxed);

        if let Some(command) = input.strip_prefix('!') {
            let tool = agent.host.tool("bash").cloned();
            match tool {
                Some(bash) => {
                    let args = serde_json::json!({"command": command});
                    screen.tool_start("bash", command);
                    let out = bash.run(&args, &plugin::ToolCtx { cwd: &agent.session.cwd, cancel: &agent.cancel });
                    screen.tool_end("bash", &out);
                    agent.session.push(llm::Message::user(format!("I ran `{command}` in the shell:\n```\n{}\n```", util::clip(&out.content, 20_000))));
                }
                None => screen.error("The bash tool is off."),
            }
            continue;
        }

        if let Some(rest) = input.strip_prefix('/') {
            let (name, args) = rest.split_once(' ').unwrap_or((rest, ""));
            let args = args.trim();
            match name {
                "exit" | "quit" | "q" => break,
                "help" | "?" => {
                    let mut text = CHAT_HELP.to_string();
                    for (plugin, c) in agent.host.commands() {
                        text.push_str(&format!("\n/{:<13}{} ({plugin})", c.name, c.help));
                    }
                    screen.say(&text);
                }
                "new" | "clear" => {
                    agent.switch(Session::new(&agent.session.cwd.clone(), &agent.model));
                    screen.clear();
                    screen.notice("New session.");
                }
                "sessions" => screen.say(&sessions_text()),
                "resume" => match Session::open(args) {
                    // Another folder has its own settings, trust and plugins: start bla there instead.
                    Ok(s) if s.cwd != agent.session.cwd => screen.error(&format!("That session is in {}; run bla -r {args} there.", s.cwd.display())),
                    Ok(s) => {
                        let n = s.messages.len();
                        agent.switch(s);
                        screen.notice(&format!("Resumed ({n} messages)."));
                    }
                    Err(e) => screen.error(&e),
                },
                "model" if args.is_empty() => screen.say(&agent.model),
                // Embedders, image models and the molecular job APIs are all in /v1/models; none of them answers a question.
                "model" if !blablador_models::is_chat_capable(args) => screen.error(&format!(
                    "{args} is for {}, not for chatting.",
                    blablador_models::kind(args).name()
                )),
                "model" => {
                    agent.model = args.to_string();
                    let _ = Settings::save_user("model", serde_json::Value::from(args));
                    screen.set_info(&agent.model, agent.effort.as_deref(), &cwd);
                    screen.notice(&format!("Model: {args} (saved as the default)"));
                }
                "models" => match agent.provider.models() {
                    Ok(list) => screen.say(
                        &list
                            .iter()
                            .map(|m| {
                                let mark = if *m == agent.model { "* " } else { "  " };
                                match blablador_models::kind(m) {
                                    blablador_models::Kind::Chat => format!("{mark}{m}"),
                                    other => format!("{mark}{m}  ({})", other.name()),
                                }
                            })
                            .collect::<Vec<_>>()
                            .join("\n"),
                    ),
                    Err(e) => screen.error(&e),
                },
                "effort" if ["off", "low", "medium", "high", "max"].contains(&args) => {
                    agent.effort = Some(args.into());
                    screen.set_info(&agent.model, agent.effort.as_deref(), &cwd);
                    screen.notice(&format!("Effort: {args}"));
                }
                "effort" => screen.say(&format!("Effort: {} (off, low, medium, high, max)", agent.effort.as_deref().unwrap_or("the model's default"))),
                "tools" => screen
                    .say(&agent.host.tools().iter().map(|t| format!("{:<12} {}", t.name(), util::clip(t.description(), 100))).collect::<Vec<_>>().join("\n")),
                "plugins" => screen.say(&agent.host.plugins.iter().map(|p| format!("{:<13} {}", p.name(), p.description())).collect::<Vec<_>>().join("\n")),
                "system" => screen.say(agent.system_prompt()),
                _ => match agent.command(name, args) {
                    Some(Ok(CommandResult::Output(text))) => screen.say(&text),
                    Some(Ok(CommandResult::Prompt(prompt))) => {
                        if let Err(e) = agent.turn(&prompt, &mut screen) {
                            screen.error(&e);
                        }
                    }
                    Some(Err(e)) => screen.error(&e),
                    None => screen.error(&format!("Unknown command /{name}. /help lists them.")),
                },
            }
            continue;
        }

        if let Err(e) = agent.turn(input, &mut screen) {
            screen.error(&e);
        }
    }
    screen.close();
    agent.finish();
    println!("Session {} · bla -r {} to continue", agent.session.id, agent.session.id);
}

#[cfg(test)]
mod tests;
