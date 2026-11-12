//! Skills: folders with a `SKILL.md` (front matter `name` and `description`, then instructions), the format
//! Claude Code, pi and Hermes share. They are found in `~/.bla/skills`, `~/.claude/skills`, `~/.agents/skills`
//! and the same folders in the project (`.bla/skills`…, only when the project is trusted).
//!
//! Only names and descriptions go in the prompt; the `skill` tool loads one when a task needs it. Like Hermes,
//! the agent can save what it learned as a new skill in `~/.bla/skills`, and `/<skill> task` runs one directly.

use crate::llm::Message;
use crate::plugin::{CommandResult, CommandSpec, Ctx, Kind, Plugin, Session, Tool, ToolCtx, ToolOutput};
use crate::util;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

#[derive(Clone, Debug)]
pub struct Skill {
    pub name: String,
    pub description: String,
    pub dir: PathBuf,
}

/// `name` and `description` from YAML front matter, and the body after it.
pub fn front_matter(text: &str) -> (Option<String>, Option<String>, &str) {
    let Some(rest) = text.strip_prefix("---") else { return (None, None, text) };
    let Some(end) = rest.find("\n---") else { return (None, None, text) };
    let (mut name, mut description) = (None, None);
    for line in rest[..end].lines() {
        if let Some((key, value)) = line.split_once(':') {
            let value = value.trim().trim_matches(|c| c == '"' || c == '\'').to_string();
            match key.trim() {
                "name" => name = Some(value),
                "description" => description = Some(value),
                _ => {}
            }
        }
    }
    let body = rest[end + 4..].trim_start_matches(|c| c != '\n').trim_start();
    (name, description, body)
}

pub fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 64 && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-') && !name.starts_with('-')
}

pub fn discover(dirs: &[PathBuf]) -> Vec<Skill> {
    let mut skills: Vec<Skill> = Vec::new();
    for root in dirs {
        let Ok(entries) = std::fs::read_dir(root) else { continue };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let dir = entry.path();
            let Ok(text) = std::fs::read_to_string(dir.join("SKILL.md")) else { continue };
            let (name, description, _) = front_matter(&text);
            let name = name.unwrap_or_else(|| entry.file_name().to_string_lossy().to_string());
            let Some(description) = description.filter(|d| !d.is_empty()) else { continue };
            // The first folder wins: the user's own skills over the project's.
            if !skills.iter().any(|s| s.name == name) {
                skills.push(Skill { name, description: util::clip(&description, 1024).to_string(), dir });
            }
        }
    }
    skills
}

pub struct Skills {
    dirs: Vec<PathBuf>,
    own: PathBuf,
    found: Arc<RwLock<Vec<Skill>>>,
}

impl Skills {
    /// `own` is where new skills go; `dirs` are searched in order, `own` first.
    pub fn new(own: PathBuf, mut dirs: Vec<PathBuf>) -> Skills {
        dirs.insert(0, own.clone());
        Skills { dirs, own, found: Arc::new(RwLock::new(Vec::new())) }
    }

    pub fn default_dirs(cwd: &Path, trusted: bool) -> (PathBuf, Vec<PathBuf>) {
        let home = util::home();
        let mut dirs = vec![home.join(".claude/skills"), home.join(".agents/skills")];
        if trusted {
            let root = crate::config::project_root(cwd);
            dirs.extend([root.join(".bla/skills"), root.join(".claude/skills"), root.join(".agents/skills")]);
        }
        (util::bla_home().join("skills"), dirs)
    }

    fn get(&self, name: &str) -> Option<Skill> {
        self.found.read().unwrap().iter().find(|s| s.name == name).cloned()
    }
}

struct SkillTool {
    own: PathBuf,
    found: Arc<RwLock<Vec<Skill>>>,
}

impl Tool for SkillTool {
    fn name(&self) -> &str {
        "skill"
    }
    fn description(&self) -> &str {
        "Skills hold instructions for particular tasks. view loads a skill's instructions (and lists its other files; \
         give file to read one). create saves a new skill: content is a SKILL.md with front matter (name, description) \
         and the steps. update replaces a skill you created."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "action": {"type": "string", "enum": ["view", "create", "update"]},
            "name": {"type": "string", "description": "Lowercase letters, digits and hyphens"},
            "file": {"type": "string", "description": "A file in the skill's folder, for view"},
            "content": {"type": "string", "description": "The whole SKILL.md, for create and update"}
        }, "required": ["action", "name"]})
    }
    fn kind(&self, args: &Value) -> Kind {
        match args["action"].as_str() {
            Some("create") | Some("update") => Kind::Write,
            _ => Kind::Read,
        }
    }
    fn summary(&self, args: &Value) -> String {
        format!("{} {}", args["action"].as_str().unwrap_or("view"), args["name"].as_str().unwrap_or_default())
    }
    fn run(&self, args: &Value, _ctx: &ToolCtx) -> ToolOutput {
        let name = args["name"].as_str().unwrap_or_default().trim();
        match args["action"].as_str().unwrap_or("view") {
            "view" => {
                let Some(skill) = self.found.read().unwrap().iter().find(|s| s.name == name).cloned() else {
                    return ToolOutput::err(format!("There is no skill {name}."));
                };
                if let Some(file) = args["file"].as_str().filter(|f| !f.is_empty()) {
                    let path = util::resolve(&skill.dir, file);
                    if !util::inside(&skill.dir, &path) {
                        return ToolOutput::err("That file is outside the skill's folder.");
                    }
                    return match std::fs::read_to_string(&path) {
                        Ok(t) => ToolOutput::ok(util::clip(&t, 100 * 1024).to_string()),
                        Err(e) => ToolOutput::err(format!("{file}: {e}")),
                    };
                }
                let text = std::fs::read_to_string(skill.dir.join("SKILL.md")).unwrap_or_default();
                let (_, _, body) = front_matter(&text);
                let mut files: Vec<String> = std::fs::read_dir(&skill.dir)
                    .into_iter()
                    .flatten()
                    .flatten()
                    .map(|e| e.file_name().to_string_lossy().to_string())
                    .filter(|n| n != "SKILL.md" && !n.starts_with('.'))
                    .collect();
                files.sort();
                let mut out = format!("Skill {name} (folder {}):\n\n{body}", skill.dir.display());
                if !files.is_empty() {
                    out.push_str(&format!("\n\nOther files in the skill (view them with file): {}", files.join(", ")));
                }
                ToolOutput::ok(out)
            }
            action @ ("create" | "update") => {
                if !valid_name(name) {
                    return ToolOutput::err("Skill names use lowercase letters, digits and hyphens, at most 64.");
                }
                let content = args["content"].as_str().unwrap_or_default();
                let (fm_name, description, body) = front_matter(content);
                if description.as_deref().map(str::is_empty).unwrap_or(true) || body.trim().is_empty() {
                    return ToolOutput::err("content needs front matter with name and description, then the instructions.");
                }
                if fm_name.as_deref().is_some_and(|n| n != name) {
                    return ToolOutput::err("The name in the front matter must match name.");
                }
                let dir = self.own.join(name);
                let file = dir.join("SKILL.md");
                if action == "create" && file.exists() {
                    return ToolOutput::err(format!("A skill {name} exists already; use update."));
                }
                if action == "update" && !file.exists() {
                    return ToolOutput::err(format!("You can only update skills in {}.", self.own.display()));
                }
                if let Err(e) = std::fs::create_dir_all(&dir).and_then(|_| std::fs::write(&file, content)) {
                    return ToolOutput::err(format!("{}: {e}", file.display()));
                }
                let mut found = self.found.write().unwrap();
                found.retain(|s| s.name != name);
                found.insert(0, Skill { name: name.into(), description: description.unwrap_or_default(), dir });
                ToolOutput::ok(format!("Saved the skill {name} in {}.", file.display()))
            }
            other => ToolOutput::err(format!("Unknown action {other}; use view, create or update.")),
        }
    }
}

impl Plugin for Skills {
    fn name(&self) -> &str {
        "skills"
    }
    fn description(&self) -> &str {
        "SKILL.md skills: listed in the prompt, loaded on demand, and written by the agent itself"
    }
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        vec![Arc::new(SkillTool { own: self.own.clone(), found: self.found.clone() })]
    }
    fn commands(&self) -> Vec<CommandSpec> {
        let mut list = vec![CommandSpec { name: "skills".into(), help: "list the skills".into() }];
        for s in self.found.read().unwrap().iter() {
            list.push(CommandSpec { name: s.name.clone(), help: format!("skill: {}", util::clip(&s.description, 70)) });
        }
        list
    }
    fn session_start(&self, _session: &Session) {
        *self.found.write().unwrap() = discover(&self.dirs);
    }
    fn system_prompt(&self, _session: &Session, sections: &mut Vec<String>) {
        let found = self.found.read().unwrap();
        let mut text = String::from(
            "Skills hold instructions for particular tasks. When a task matches a skill's description, load it with the skill tool (view) before you start. \
             After you finish a task that took real effort or that the user will want again, save the procedure and its pitfalls as a skill (create), so next time is faster.",
        );
        if !found.is_empty() {
            text.push_str("\n\n<skills>");
            for s in found.iter() {
                text.push_str(&format!("\n- {}: {}", s.name, s.description));
            }
            text.push_str("\n</skills>");
        }
        sections.push(text);
    }
    fn command(&self, _ctx: &Ctx, name: &str, args: &str, _messages: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        if name == "skills" {
            let found = self.found.read().unwrap();
            let text = if found.is_empty() {
                format!("No skills yet. Put folders with a SKILL.md in {}, or ask bla to save one.", self.own.display())
            } else {
                found.iter().map(|s| format!("{:<24} {}", s.name, util::clip(&s.description, 90))).collect::<Vec<_>>().join("\n")
            };
            return Some(Ok(CommandResult::Output(text)));
        }
        let skill = self.get(name)?;
        let text = std::fs::read_to_string(skill.dir.join("SKILL.md")).unwrap_or_default();
        let (_, _, body) = front_matter(&text);
        let task = if args.trim().is_empty() { "Follow the skill.".to_string() } else { args.trim().to_string() };
        Some(Ok(CommandResult::Prompt(format!("Use the skill {name} (folder {}):\n\n{body}\n\nTask: {task}", skill.dir.display()))))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    #[test]
    fn front_matter_and_skills() {
        let (n, d, body) = front_matter("---\nname: pdf\ndescription: \"Work with PDFs\"\n---\n\n# Steps\nDo it.");
        assert_eq!((n.as_deref(), d.as_deref(), body), (Some("pdf"), Some("Work with PDFs"), "# Steps\nDo it."));
        assert!(valid_name("make-release") && !valid_name("../x") && !valid_name("Big"));

        let home = std::env::temp_dir().join(format!("bla-skills-{}", util::random_hex(8)));
        let other = home.join("other");
        std::fs::create_dir_all(other.join("deploy")).unwrap();
        std::fs::write(other.join("deploy/SKILL.md"), "---\nname: deploy\ndescription: Ship it\n---\nRun make.").unwrap();
        std::fs::write(other.join("deploy/notes.md"), "extra").unwrap();
        let skills = Skills::new(home.join("own"), vec![other]);
        let cwd = std::env::temp_dir();
        skills.session_start(&Session { id: "s", cwd: &cwd, interactive: false });
        let tool = &skills.tools()[0];
        let cancel = AtomicBool::new(false);
        let ctx = ToolCtx { cwd: &cwd, cancel: &cancel };
        let view = tool.run(&json!({"action": "view", "name": "deploy"}), &ctx);
        assert!(view.content.contains("Run make.") && view.content.contains("notes.md"));
        assert!(tool.run(&json!({"action": "view", "name": "deploy", "file": "../../x"}), &ctx).is_error);
        let made = tool.run(&json!({"action": "create", "name": "tidy", "content": "---\nname: tidy\ndescription: Clean up\n---\nSteps."}), &ctx);
        assert!(!made.is_error, "{}", made.content);
        assert!(home.join("own/tidy/SKILL.md").exists());
        assert!(tool.run(&json!({"action": "create", "name": "bad", "content": "no front matter"}), &ctx).is_error);
        assert!(tool.run(&json!({"action": "update", "name": "deploy", "content": "---\nname: deploy\ndescription: x\n---\ny"}), &ctx).is_error);
        let _ = std::fs::remove_dir_all(home);
    }
}
