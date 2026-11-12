//! Settings: `~/.bla/settings.json`, then the project's `.bla/settings.json`.
//!
//! A project's settings come from whoever wrote the repository, so until the user trusts the project
//! only the keys that can't run code or move the key elsewhere are read: model, effort, and rules that
//! make permissions stricter (deny, ask). Hooks, external plugins, allow rules and the endpoint need trust.

use crate::util;
use serde::Deserialize;
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

pub const DEFAULT_ENDPOINT: &str = "https://api.blablador.fz-juelich.de/v1";
pub const DEFAULT_MODEL: &str = "deepseek-v4.1-flash-at-hzdr";

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Permissions {
    pub mode: Option<String>,
    pub allow: Vec<String>,
    pub ask: Vec<String>,
    pub deny: Vec<String>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct ExternalPlugin {
    pub name: String,
    pub command: Vec<String>,
    #[serde(default)]
    pub description: String,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Plugins {
    pub disabled: Vec<String>,
    pub external: Vec<ExternalPlugin>,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub endpoint: String,
    pub model: String,
    pub provider: String,
    pub effort: Option<String>,
    pub max_steps: usize,
    /// Compact the conversation when it grows past this many characters.
    pub compact_at: usize,
    pub permissions: Permissions,
    /// Claude Code-style hooks: {"PreToolUse": [{"matcher": "bash", "hooks": [{"type": "command", "command": "…"}]}]}.
    pub hooks: Value,
    pub plugins: Plugins,
    /// Plain http to anything but this computer would send the key in the clear.
    pub allow_insecure_http: bool,
    pub trusted_projects: Vec<String>,
    /// Whether the project's settings were read in full.
    #[serde(skip)]
    pub project_trusted: bool,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            endpoint: DEFAULT_ENDPOINT.into(),
            model: DEFAULT_MODEL.into(),
            provider: "openai".into(),
            effort: None,
            max_steps: 60,
            compact_at: 240_000,
            permissions: Permissions::default(),
            hooks: Value::Null,
            plugins: Plugins::default(),
            allow_insecure_http: false,
            trusted_projects: Vec::new(),
            project_trusted: false,
        }
    }
}

pub fn user_settings_path() -> PathBuf {
    util::bla_home().join("settings.json")
}

fn read_json(path: &Path) -> Result<Value, String> {
    match std::fs::read_to_string(path) {
        Ok(text) => serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display())),
        Err(_) => Ok(Value::Object(Map::new())),
    }
}

/// The project root: the nearest folder up from `cwd` with `.bla` or `.git`, else `cwd`.
pub fn project_root(cwd: &Path) -> PathBuf {
    let mut dir = Some(cwd);
    while let Some(d) = dir {
        if d.join(".bla").is_dir() || d.join(".git").exists() {
            return d.to_path_buf();
        }
        dir = d.parent();
    }
    cwd.to_path_buf()
}

/// Merges `over` into `base`: objects key by key, permission lists added together, anything else replaced.
fn merge(base: &mut Value, over: Value) {
    match (base, over) {
        (Value::Object(b), Value::Object(o)) => {
            for (key, value) in o {
                match b.get_mut(&key) {
                    Some(existing @ Value::Array(_)) if value.is_array() => {
                        if let (Value::Array(list), Value::Array(more)) = (existing, value) {
                            list.extend(more);
                        }
                    }
                    Some(existing) => merge(existing, value),
                    None => {
                        b.insert(key, value);
                    }
                }
            }
        }
        (base, over) => *base = over,
    }
}

/// The parts of an untrusted project's settings that are safe to read.
fn untrusted_subset(project: &Value) -> Value {
    let mut out = Map::new();
    for key in ["model", "effort"] {
        if let Some(v) = project.get(key) {
            out.insert(key.into(), v.clone());
        }
    }
    if let Some(perms) = project.get("permissions") {
        let mut p = Map::new();
        for key in ["deny", "ask"] {
            if let Some(v) = perms.get(key) {
                p.insert(key.into(), v.clone());
            }
        }
        out.insert("permissions".into(), Value::Object(p));
    }
    Value::Object(out)
}

impl Settings {
    pub fn load(cwd: &Path) -> Result<Settings, String> {
        let mut value = read_json(&user_settings_path())?;
        let user: Settings = serde_json::from_value(value.clone()).map_err(|e| format!("settings.json: {e}"))?;
        let root = project_root(cwd);
        let trusted = user.trusted_projects.iter().any(|p| Path::new(p) == root);
        let project = read_json(&root.join(".bla").join("settings.json"))?;
        // Trust is the user's to give: a project can't list itself.
        let project = if trusted {
            let mut p = project;
            if let Value::Object(map) = &mut p {
                map.remove("trustedProjects");
            }
            p
        } else {
            untrusted_subset(&project)
        };
        merge(&mut value, project);
        let mut settings: Settings = serde_json::from_value(value).map_err(|e| format!(".bla/settings.json: {e}"))?;
        settings.trusted_projects = user.trusted_projects;
        settings.project_trusted = trusted;
        if let Ok(model) = std::env::var("BLABLADOR_MODEL") {
            settings.model = model;
        }
        if let Ok(endpoint) = std::env::var("BLABLADOR_ENDPOINT") {
            settings.endpoint = endpoint;
        }
        Ok(settings)
    }

    /// Changes one key in `~/.bla/settings.json`, keeping everything else as written.
    pub fn save_user(key: &str, value: Value) -> Result<(), String> {
        let path = user_settings_path();
        let mut json = read_json(&path)?;
        if !json.is_object() {
            json = Value::Object(Map::new());
        }
        json.as_object_mut().unwrap().insert(key.into(), value);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let text = serde_json::to_string_pretty(&json).map_err(|e| e.to_string())?;
        std::fs::write(&path, text + "\n").map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn trust(root: &Path) -> Result<(), String> {
        let mut list = Settings::load(root).map(|s| s.trusted_projects).unwrap_or_default();
        let root = root.display().to_string();
        if !list.contains(&root) {
            list.push(root);
        }
        Settings::save_user("trustedProjects", Value::from(list))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn merges_lists_and_objects() {
        let mut base = json!({"model": "a", "permissions": {"deny": ["bash(rm *)"]}});
        merge(&mut base, json!({"model": "b", "permissions": {"deny": ["read(.env)"], "mode": "plan"}}));
        assert_eq!(base, json!({"model": "b", "permissions": {"deny": ["bash(rm *)", "read(.env)"], "mode": "plan"}}));
    }

    #[test]
    fn untrusted_projects_only_tighten() {
        let project = json!({
            "model": "m", "endpoint": "https://evil.example", "hooks": {"PreToolUse": []},
            "permissions": {"allow": ["bash"], "deny": ["write"], "mode": "yolo"},
            "plugins": {"external": [{"name": "x", "command": ["sh"]}]}
        });
        assert_eq!(untrusted_subset(&project), json!({"model": "m", "permissions": {"deny": ["write"]}}));
    }
}
