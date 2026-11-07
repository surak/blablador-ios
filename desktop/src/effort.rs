//! How hard a model thinks before it answers, mapped to the request fields each kind of model understands.
//! Mirrors `ReasoningEffort` in the Swift app's BlabladorAPI.swift.

use serde_json::{json, Map, Value};
use std::collections::HashMap;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Effort {
    Off,
    Low,
    Medium,
    High,
    Max,
}

impl Effort {
    pub const ALL: [Effort; 5] = [Effort::Off, Effort::Low, Effort::Medium, Effort::High, Effort::Max];

    pub fn raw(self) -> &'static str {
        match self {
            Effort::Off => "off",
            Effort::Low => "low",
            Effort::Medium => "medium",
            Effort::High => "high",
            Effort::Max => "max",
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Effort::Off => "Off",
            Effort::Low => "Low",
            Effort::Medium => "Medium",
            Effort::High => "High",
            Effort::Max => "Max",
        }
    }

    pub fn parse(raw: &str) -> Option<Effort> {
        Effort::ALL.into_iter().find(|level| level.raw() == raw)
    }
}

enum Family {
    OpenAi,
    DeepSeek,
    Toggle,
}

fn family(model: &str) -> Option<Family> {
    let id = model.to_lowercase();
    let o_series = regex::Regex::new(r"(^|[^a-z0-9])o[134](-|$)").unwrap();
    if id.contains("gpt-oss") || id.contains("gpt-5") || o_series.is_match(&id) {
        return Some(Family::OpenAi);
    }
    if id.contains("deepseek") && ["v3.1", "v3.2", "v4"].iter().any(|v| id.contains(v)) {
        return Some(Family::DeepSeek);
    }
    // Qwen3 and GLM switch thinking on or off; their instruct and coder versions don't think.
    let toggles = ["qwen3", "glm-4.5", "glm-4.6", "glm-4.7", "glm-5"].iter().any(|v| id.contains(v));
    if toggles && !["instruct", "coder", "thinking", "-vl"].iter().any(|v| id.contains(v)) {
        return Some(Family::Toggle);
    }
    None
}

/// The levels a model takes, or none when its thinking can't be set.
pub fn levels(model: &str) -> Vec<Effort> {
    use Effort::*;
    match family(model) {
        Some(Family::OpenAi) => vec![Low, Medium, High, Max],
        Some(Family::DeepSeek) => vec![Off, Low, Medium, High, Max],
        Some(Family::Toggle) => vec![Off, High],
        None => vec![],
    }
}

/// The level chosen for a model, or Medium (or the highest it has) when nothing was chosen.
pub fn level(model: &str, saved: &HashMap<String, String>) -> Option<Effort> {
    let levels = levels(model);
    if let Some(chosen) = saved.get(model).and_then(|raw| Effort::parse(raw)) {
        if levels.contains(&chosen) {
            return Some(chosen);
        }
    }
    if levels.contains(&Effort::Medium) {
        Some(Effort::Medium)
    } else {
        levels.last().copied()
    }
}

fn worked_key(model: &str, level: Effort) -> String {
    format!("{model}|{}", level.raw())
}

/// Every way of asking for `level`, best first; the last one sends nothing extra.
fn all_candidates(model: &str, level: Effort) -> Vec<Map<String, Value>> {
    let object = |value: Value| value.as_object().cloned().unwrap_or_default();
    let names: Vec<&str> = if level == Effort::Max { vec!["max", "xhigh", "high"] } else { vec![level.raw()] };
    let mut result: Vec<Map<String, Value>> = match family(model) {
        Some(Family::OpenAi) => {
            let names = if level == Effort::Off { vec!["minimal", "low"] } else { names };
            names.iter().map(|n| object(json!({ "reasoning_effort": n }))).collect()
        }
        Some(Family::DeepSeek) => {
            if level == Effort::Off {
                vec![
                    object(json!({ "chat_template_kwargs": { "thinking": false }, "thinking": { "type": "disabled" } })),
                    object(json!({ "chat_template_kwargs": { "thinking": false } })),
                ]
            } else {
                let mut list: Vec<_> = names
                    .iter()
                    .map(|n| object(json!({ "reasoning_effort": n, "chat_template_kwargs": { "thinking": true, "reasoning_effort": n } })))
                    .collect();
                list.extend(names.iter().map(|n| object(json!({ "reasoning_effort": n }))));
                list
            }
        }
        Some(Family::Toggle) => vec![object(json!({ "chat_template_kwargs": { "enable_thinking": level != Effort::Off } }))],
        None => return vec![Map::new()],
    };
    result.push(Map::new());
    result
}

/// Request fields to try, with the one the server accepted last time first.
pub fn candidates(model: &str, level: Effort, worked: &HashMap<String, usize>) -> Vec<Map<String, Value>> {
    let mut result = all_candidates(model, level);
    if let Some(&index) = worked.get(&worked_key(model, level)) {
        if index > 0 && index < result.len() {
            let item = result.remove(index);
            result.insert(0, item);
        }
    }
    result
}

/// Records which of `candidates` (by its index there) the server accepted.
pub fn remember(model: &str, level: Effort, tried_index: usize, worked: &mut HashMap<String, usize>) {
    let tried = candidates(model, level, worked);
    let Some(accepted) = tried.get(tried_index) else { return };
    if let Some(position) = all_candidates(model, level).iter().position(|c| c == accepted) {
        worked.insert(worked_key(model, level), position);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn families() {
        assert_eq!(levels("deepseek-v4.1-flash-at-hzdr").len(), 5);
        assert_eq!(levels("gpt-oss-120b"), vec![Effort::Low, Effort::Medium, Effort::High, Effort::Max]);
        assert_eq!(levels("Qwen3-32B"), vec![Effort::Off, Effort::High]);
        assert!(levels("Qwen3-Coder-30B").is_empty());
        assert!(levels("mistral-small").is_empty());
    }

    #[test]
    fn remembers_what_worked() {
        let mut worked = HashMap::new();
        let model = "gpt-oss-120b";
        assert_eq!(candidates(model, Effort::Max, &worked)[0]["reasoning_effort"], "max");
        remember(model, Effort::Max, 1, &mut worked);
        assert_eq!(candidates(model, Effort::Max, &worked)[0]["reasoning_effort"], "xhigh");
        assert!(candidates(model, Effort::Max, &worked).last().unwrap().is_empty());
    }
}
