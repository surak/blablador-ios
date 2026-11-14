//! The built-in plugins and the list a session starts with. Each can be turned off with
//! `"plugins": {"disabled": [...]}` or `--no-plugin NAME`, the provider and the core tools included.

pub mod blablador;
pub mod checkpoints;
pub mod compaction;
pub mod context;
pub mod core_tools;
pub mod external;
pub mod hooks;
pub mod memory;
pub mod openai;
pub mod permissions;
pub mod skills;

use crate::config::Settings;
use crate::plugin::Plugin;
use std::path::Path;
use std::sync::Arc;

pub const BUILT_IN: &[(&str, &str)] = &[
    ("openai", "Model provider for OpenAI-compatible endpoints (Blablador)"),
    ("core-tools", "read, write, edit and bash"),
    ("context", "AGENTS.md and CLAUDE.md instructions, the git branch, and @file mentions"),
    ("permissions", "Allow, ask and deny rules and the default, accept-edits, plan and yolo modes"),
    ("hooks", "Shell hooks at session start, prompt, tool calls and stop (Claude Code format)"),
    ("skills", "SKILL.md skills: listed in the prompt, loaded on demand, and written by the agent itself"),
    ("memory", "The long-term memory shared with the Blablador apps, frozen into each session's prompt"),
    ("blablador", "Blablador's other models as tools: vision, OCR, image generation, transcription"),
    ("checkpoints", "Keeps files as they were before each turn; /undo restores them"),
    ("compaction", "Summarises long conversations so they fit the model's context"),
];

pub struct Options<'a> {
    pub settings: &'a Settings,
    pub cwd: &'a Path,
    pub api_key: String,
    /// The chat's model, which look_at_image tries first.
    pub model: String,
    pub mode: permissions::Mode,
    pub disabled: &'a [String],
}

/// Builds the plugins in order. Problems with optional plugins become warnings rather than errors.
pub fn load(o: Options) -> (Vec<Arc<dyn Plugin>>, Vec<String>) {
    let on = |name: &str| !o.settings.plugins.disabled.iter().any(|d| d == name) && !o.disabled.iter().any(|d| d == name);
    let mut plugins: Vec<Arc<dyn Plugin>> = Vec::new();
    let mut warnings = Vec::new();
    let s = o.settings;
    if on("openai") {
        match openai::OpenAi::new(&s.endpoint, o.api_key.clone(), s.allow_insecure_http) {
            Ok(p) => plugins.push(Arc::new(openai::OpenAiPlugin::new(p))),
            Err(e) => warnings.push(e),
        }
    }
    if on("blablador") {
        plugins.push(Arc::new(blablador::Blablador::new(&s.endpoint, o.api_key.clone(), &o.model)));
    }
    if on("permissions") {
        let p = &s.permissions;
        plugins.push(Arc::new(permissions::Permissions::new(o.mode, &p.allow, &p.ask, &p.deny, s.project_trusted)));
    }
    if on("core-tools") {
        plugins.push(Arc::new(core_tools::CoreTools::new()));
    }
    if on("context") {
        plugins.push(Arc::new(context::Context));
    }
    if on("hooks") {
        let hooks = hooks::Hooks::new(&s.hooks);
        if !hooks.is_empty() {
            plugins.push(Arc::new(hooks));
        }
    }
    if on("skills") {
        let (own, dirs) = skills::Skills::default_dirs(o.cwd, s.project_trusted);
        plugins.push(Arc::new(skills::Skills::new(own, dirs)));
    }
    if on("memory") {
        plugins.push(Arc::new(memory::Memory::new(crate::util::bla_home().join("memory"))));
    }
    if on("checkpoints") {
        plugins.push(Arc::new(checkpoints::Checkpoints::default()));
    }
    if on("compaction") {
        plugins.push(Arc::new(compaction::Compaction::new(s.compact_at)));
    }
    // External plugins: from settings, ~/.bla/plugins, and the project's .bla/plugins when trusted.
    let mut external: Vec<(String, String, Vec<String>, std::path::PathBuf)> =
        s.plugins.external.iter().map(|e| (e.name.clone(), e.description.clone(), e.command.clone(), o.cwd.to_path_buf())).collect();
    external.extend(external::manifests(&crate::util::bla_home().join("plugins")));
    if s.project_trusted {
        external.extend(external::manifests(&crate::config::project_root(o.cwd).join(".bla").join("plugins")));
    }
    for (name, description, command, dir) in external {
        if !on(&name) || plugins.iter().any(|p| p.name() == name) {
            continue;
        }
        match external::External::start(&name, &description, &command, &dir) {
            Ok(p) => plugins.push(Arc::new(p)),
            Err(e) => warnings.push(format!("plugin {name}: {e}")),
        }
    }
    (plugins, warnings)
}
