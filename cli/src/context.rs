//! How many tokens a model can hold, worked out the way Hermes does (`agent/model_metadata.py`,
//! `get_model_context_length`): what the endpoint's `/models` says about the model first, then the
//! longest matching name in Hermes' table of known windows, then 256K.

use serde_json::Value;

/// Hermes' `DEFAULT_FALLBACK_CONTEXT`.
pub const FALLBACK: u64 = 256_000;

/// Hermes' `_CONTEXT_LENGTH_KEYS`: where OpenAI-compatible servers put the window (vLLM: `max_model_len`).
const KEYS: [&str; 12] = [
    "context_length", "context_window", "context_size", "max_context_length", "max_position_embeddings",
    "max_model_len", "max_input_tokens", "max_sequence_length", "max_seq_len", "n_ctx_train", "n_ctx", "ctx_size",
];

/// Hermes' `DEFAULT_CONTEXT_LENGTHS`, copied as it is.
const TABLE: &[(&str, u64)] = &[
    ("claude-fable-5", 1000000),
    ("claude-fable", 1000000),
    ("claude-mythos", 1000000),
    ("claude-opus-5", 1000000),
    ("claude-sonnet-5", 1000000),
    ("claude-haiku-5", 1000000),
    ("claude-opus-4-8", 1000000),
    ("claude-opus-4.8", 1000000),
    ("claude-opus-4-7", 1000000),
    ("claude-opus-4.7", 1000000),
    ("claude-opus-4-6", 1000000),
    ("claude-sonnet-4-6", 1000000),
    ("claude-opus-4.6", 1000000),
    ("claude-sonnet-4.6", 1000000),
    ("claude", 200000),
    ("gpt-6.2-astra", 1050000),
    ("gpt-6.2-sol", 1050000),
    ("gpt-6-astra", 1050000),
    ("gpt-6.1-sol", 1050000),
    ("gpt-6.1-terra", 1050000),
    ("gpt-6-sol", 1050000),
    ("gpt-6-luna", 1050000),
    ("gpt-5.6", 1050000),
    ("gpt-5.6-luna", 1050000),
    ("gpt-5.6-terra", 1050000),
    ("gpt-5.6-sol", 1050000),
    ("gpt-5.5", 1050000),
    ("gpt-5.4-nano", 400000),
    ("gpt-5.4-mini", 400000),
    ("gpt-5.4", 1050000),
    ("gpt-5.3-codex-spark", 128000),
    ("gpt-5.1-chat", 128000),
    ("gpt-5", 400000),
    ("gpt-4.1", 1047576),
    ("gpt-4", 128000),
    ("gemini", 1048576),
    ("gemma-4", 256000),
    ("gemma4", 256000),
    ("gemma-4-31b", 256000),
    ("gemma-3", 131072),
    ("gemma", 8192),
    ("deepseek-v4-pro", 1000000),
    ("deepseek-v4.1-flash", 1000000),
    ("deepseek-v4-flash", 1000000),
    ("deepseek-chat", 1000000),
    ("deepseek-reasoner", 1000000),
    ("deepseek-flash", 1000000),
    ("deepseek", 128000),
    ("llama", 131072),
    ("muse-spark-1.3", 1048576),
    ("muse-spark", 1048576),
    ("inkling", 1048576),
    ("qwen3.8-max", 1000000),
    ("qwen3.8-flash", 1000000),
    ("qwen3.6-plus", 1048576),
    ("qwen3.7-plus", 1048576),
    ("qwen3-coder-plus", 1000000),
    ("qwen3-coder", 262144),
    ("qwen3-max", 262144),
    ("qwen", 131072),
    ("minimax-m3", 1000000),
    ("minimax", 204800),
    ("glm-5.3", 1048576),
    ("glm-5.3-flash", 1048576),
    ("glm-5.3:batch", 1048576),
    ("glm-5.3:us", 1048576),
    ("glm-5.3-flash:batch", 1048576),
    ("glm-5.3-flash:us", 1048576),
    ("glm-5.3-flashx", 1048576),
    ("glm-5.2", 1048576),
    ("glm-5.2:free", 256000),
    ("glm-5.1", 204800),
    ("glm-5-turbo", 202752),
    ("glm-5v-turbo", 202752),
    ("glm-5", 204800),
    ("glm-4.7-flash", 202752),
    ("glm-4.7", 204800),
    ("glm-4.6v", 131072),
    ("glm-4.6", 204800),
    ("glm", 202752),
    ("grok-composer", 200000),
    ("grok-build-latest", 500000),
    ("grok-build", 256000),
    ("grok-code-fast", 256000),
    ("grok-2-vision", 8192),
    ("grok-4-fast", 2000000),
    ("grok-4.20", 1000000),
    ("grok-4.7", 500000),
    ("grok-4.6", 500000),
    ("grok-4.5", 500000),
    ("grok-4.3", 1000000),
    ("grok-4", 256000),
    ("grok-3", 131072),
    ("grok-2", 131072),
    ("grok", 131072),
    ("kimi-k3", 1048576),
    ("kimi", 262144),
    ("solar-open2", 262144),
    ("solar-pro3", 131072),
    ("solar-pro2", 65536),
    ("solar-mini", 32768),
    ("solar-", 524288),
    ("hy4-preview", 1048576),
    ("hy3-preview", 262144),
    ("hy3", 262144),
    ("x-preview-f", 1048576),
    ("ox-alpha", 1048576),
    ("union-alpha", 262144),
    ("nemotron-3.5-lightning", 1000000),
    ("nemotron-3.5-super-vl", 1000000),
    ("nemotron", 131072),
    ("laguna-s-2.1", 262144),
    ("laguna-xs-2.1", 262144),
    ("trinity", 262144),
    ("elephant", 262144),
    ("Qwen/Qwen3.5-397B-A17B", 131072),
    ("Qwen/Qwen3.5-35B-A3B", 131072),
    ("deepseek-ai/DeepSeek-V3.2", 65536),
    ("moonshotai/Kimi-K2.5", 262144),
    ("moonshotai/Kimi-K2.6", 262144),
    ("moonshotai/Kimi-K2-Thinking", 262144),
    ("MiniMaxAI/MiniMax-M2.5", 204800),
    ("XiaomiMiMo/MiMo-V2-Flash", 262144),
    ("mimo-v2.6-pro-ultraspeed", 1048576),
    ("mimo-v2.6-pro", 1048576),
    ("mimo-v2.6-flash", 1048576),
    ("mimo-v2-pro", 1048576),
    ("mimo-v2.5-pro", 1048576),
    ("mimo-v2.5", 1048576),
    ("mimo-v2-omni", 262144),
    ("mimo-v2-flash", 262144),
    ("zai-org/GLM-5", 202752),
];

/// Hermes' `_coerce_reasonable_int`.
fn reasonable(v: &Value) -> Option<u64> {
    let n = match v {
        Value::Number(n) => n.as_u64().or_else(|| n.as_f64().map(|f| f as u64))?,
        Value::String(s) => s.trim().replace(',', "").parse().ok()?,
        _ => return None,
    };
    (1024..=10_000_000).contains(&n).then_some(n)
}

/// Hermes' `_extract_first_int`: the first window key anywhere in the model's `/models` entry.
pub fn from_entry(entry: &Value) -> Option<u64> {
    match entry {
        Value::Object(map) => {
            for (k, v) in map {
                if KEYS.contains(&k.to_lowercase().as_str()) {
                    if let Some(n) = reasonable(v) {
                        return Some(n);
                    }
                }
            }
            map.values().find_map(from_entry)
        }
        _ => None,
    }
}

/// Hermes' `_catalog_key_matches` (dots and dashes alike; `solar-` keys only on an id boundary).
fn matches(key: &str, model: &str) -> bool {
    if key.starts_with("solar-") {
        if key.ends_with('-') {
            let last = model.rsplit('/').next().unwrap_or(model);
            return last.strip_prefix(key).is_some_and(|rest| rest.starts_with(|c: char| c.is_ascii_lowercase()));
        }
        return model.match_indices(key).any(|(i, _)| {
            model[i + key.len()..].chars().next().map_or(true, |c| "-:.@".contains(c))
        });
    }
    model.contains(key) || model.replace('.', "-").contains(&key.replace('.', "-"))
}

/// Hermes' step 8: the longest key in the table found in the id.
pub fn from_table(model: &str) -> Option<u64> {
    let model = model.to_lowercase();
    let mut keys: Vec<&(&str, u64)> = TABLE.iter().collect();
    keys.sort_by_key(|(k, _)| std::cmp::Reverse(k.len()));
    keys.into_iter().find(|(k, _)| matches(&k.to_lowercase(), &model)).map(|(_, v)| *v)
}

/// The window: the endpoint's word, else the table, else Hermes' 256K.
pub fn resolve(model: &str, reported: Option<u64>) -> u64 {
    reported.or_else(|| from_table(model)).unwrap_or(FALLBACK)
}

/// 1,000,000 → "1M", 131072 → "128K".
pub fn human(n: u64) -> String {
    if n >= 1_000_000 && n % 1_000_000 == 0 {
        format!("{}M", n / 1_000_000)
    } else if n >= 1_048_576 && n % 1_048_576 == 0 {
        format!("{}Mi", n / 1_048_576)
    } else if n % 1024 == 0 {
        format!("{}K", n / 1024)
    } else {
        format!("{}K", n / 1000)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_longest_key_wins() {
        assert_eq!(from_table("deepseek-v4.1-flash-at-hzdr"), Some(1_000_000));
        assert_eq!(from_table("gpt-5.4-mini"), Some(400_000));
        assert_eq!(from_table("z-ai-glm-5-3"), Some(1_048_576));
        assert_eq!(from_table("solar-mini"), Some(32768));
        assert_eq!(from_table("alias-fast"), None);
        assert_eq!(resolve("alias-fast", None), FALLBACK);
    }

    #[test]
    fn the_endpoint_comes_first() {
        let entry = json!({"id": "x", "max_model_len": 32768, "meta": {"context_length": 8}});
        assert_eq!(from_entry(&entry), Some(32768));
        assert_eq!(from_entry(&json!({"id": "x", "info": {"n_ctx": "65,536"}})), Some(65536));
        assert_eq!(from_entry(&json!({"id": "x", "max_tokens": 4096})), None);
        assert_eq!(human(131072), "128K");
    }
}
