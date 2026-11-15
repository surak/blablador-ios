//! Onboarding: a key the user pastes is tried against the endpoint before it is trusted, so that a mistyped or
//! expired token says so at once instead of on the first question. The answer also says what the key can do
//! (how many chat models) and which other keys the machine already has, so nobody has to hunt for a token first.

use serde_json::Value;
use std::time::Duration;

/// What a key turned out to be.
#[derive(Debug)]
pub struct Probe {
    /// Chat models the key can see, by the rule the apps use: embeddings, image and job models are not chat.
    pub chat_models: usize,
    /// The first chat model, the one to switch to when the key is new.
    pub first_model: Option<String>,
}

/// Models in `/v1/models` that can hold a conversation. Embedders, image models and the protein job APIs are all in
/// the same list and none of them answers a question, so counting them would promise more than the key delivers.
fn is_chat(id: &str) -> bool {
    let id = id.to_lowercase();
    !(id.contains("embed") || id.contains("rerank") || id.contains("whisper") || id.contains("flux")
        || id.contains("image") || id.contains("esmfold") || id.contains("rfdiffusion") || id.contains("bindcraft")
        || id.contains("bioemu") || id.contains("proteina") || id.contains("vggt"))
}

fn normalize(endpoint: &str) -> String {
    endpoint.trim().trim_end_matches('/').to_string()
}

/// Tries `key` against `endpoint`: `Ok(Probe)` when the endpoint answers, `Err` with a sentence to show otherwise.
/// A wrong key and an unreachable server are told apart, because only one of them is the user's to fix.
pub fn probe(endpoint: &str, key: &str, timeout: Duration) -> Result<Probe, String> {
    let key = key.trim();
    if key.is_empty() {
        return Err("There is no key to try.".into());
    }
    let url = format!("{}/models", normalize(endpoint));
    let agent = ureq::AgentBuilder::new().timeout(timeout).build();
    let response = match agent.get(&url).set("Authorization", &format!("Bearer {key}")).call() {
        Ok(r) => r,
        Err(ureq::Error::Status(code, r)) => {
            let body = r.into_string().unwrap_or_default();
            return Err(match code {
                401 | 403 => "The endpoint refused this key. Make a new one and paste it again.".to_string(),
                404 => format!("{url} is not an OpenAI-compatible endpoint (404). Check the address."),
                other => format!("The endpoint answered {other}: {}", body.trim().chars().take(200).collect::<String>()),
            });
        }
        Err(e) => return Err(format!("Could not reach {url}: {e}")),
    };
    let body: Value = response.into_json().map_err(|e| format!("The endpoint sent something unreadable: {e}"))?;
    let ids: Vec<String> = body["data"].as_array().into_iter().flatten().filter_map(|m| m["id"].as_str().map(String::from)).collect();
    let chat: Vec<String> = ids.iter().filter(|id| is_chat(id)).cloned().collect();
    if chat.is_empty() {
        return Err(format!("The key works, but sees no chat models at {url} ({} models, none able to chat).", ids.len()));
    }
    Ok(Probe { chat_models: chat.len(), first_model: chat.first().cloned() })
}

/// One key found in another program on this machine.
pub struct Found {
    /// Where it is, for the user to recognise: "Hermes (blablador)", "OpenAI (OPENAI_API_KEY)".
    pub label: String,
    pub base_url: String,
    pub key: String,
}

/// Keys the machine already has, so onboarding can offer them instead of asking for a new one. Read only, and
/// nothing is copied or sent anywhere: the caller tries each one as if it had been pasted.
///
/// Hermes keeps its providers in `~/.hermes/config.yaml`, one `api_key` per provider under `providers:`. Only keys
/// written out in full are useful here (an `env:` reference is not a key). Other editors keep keys in their own
/// form, which is why this stays to the ones whose files are plain and documented.
pub fn found_keys() -> Vec<Found> {
    let mut found = Vec::new();
    let home = crate::util::home();
    for dir in [home.join(".hermes"), home.join(".config/hermes")] {
        let file = dir.join("config.yaml");
        let Ok(text) = std::fs::read_to_string(&file) else { continue };
        found.extend(hermes_keys(&text));
        break;
    }
    if let Ok(key) = std::env::var("OPENAI_API_KEY") {
        let key = key.trim().to_string();
        // Tried where it will be used, not where the variable name says: `OPENAI_API_KEY` often holds a Helmholtz
        // Codebase token (the Blablador key is one), and on this machine it does. A `glpat-` token is that shape, so
        // Blablador is where it is worth trying first; the caller still confirms before anything is saved.
        if let Some((label, base_url)) = env_key(&key, crate::config::DEFAULT_ENDPOINT) {
            found.push(Found { label, base_url, key });
        }
    }
    found
}

/// What a value in `OPENAI_API_KEY` looks like and where it should be tried, or nothing when it is no key at all.
fn env_key(key: &str, blablador: &str) -> Option<(String, String)> {
    if key.is_empty() {
        return None;
    }
    if key.starts_with("glpat-") {
        return Some(("Helmholtz token in OPENAI_API_KEY".into(), blablador.to_string()));
    }
    if key.starts_with("sk-") {
        return Some(("OpenAI key in OPENAI_API_KEY".into(), "https://api.openai.com/v1".into()));
    }
    if key.len() < 8 {
        return None;
    }
    Some(("Key in OPENAI_API_KEY".into(), "https://api.openai.com/v1".into()))
}

/// The providers in Hermes' YAML, without a YAML parser: the file is a flat `providers:` map of `name:` blocks with
/// `api:` and `api_key:` two spaces in, and a key that happens to contain a colon (`env:FOO`) is not one.
fn hermes_keys(text: &str) -> Vec<Found> {
    let mut found = Vec::new();
    let mut in_providers = false;
    let mut name: Option<String> = None;
    let mut api: Option<String> = None;
    let mut key: Option<String> = None;
    let flush = |name: &Option<String>, api: &Option<String>, key: &Option<String>, found: &mut Vec<Found>| {
        if let (Some(n), Some(a), Some(k)) = (name, api, key) {
            if !k.is_empty() && !k.starts_with("env:") && !k.contains("${") {
                found.push(Found { label: format!("Hermes ({n})"), base_url: a.clone(), key: k.clone() });
            }
        }
    };
    for line in text.lines() {
        let raw = line.trim_end();
        if raw.trim_start().starts_with('#') || raw.trim().is_empty() {
            continue;
        }
        let indent = raw.len() - raw.trim_start().len();
        if indent == 0 {
            flush(&name, &api, &key, &mut found);
            name = None; api = None; key = None;
            in_providers = raw.trim_end().starts_with("providers:");
            continue;
        }
        if !in_providers {
            continue;
        }
        // A provider name is two spaces in; its settings are four.
        if indent == 2 {
            flush(&name, &api, &key, &mut found);
            api = None; key = None;
            name = raw.trim().trim_end_matches(':').trim().to_string().into();
        } else if indent >= 4 {
            let t = raw.trim();
            if let Some(v) = t.strip_prefix("api:") {
                api = Some(unquote(v));
            } else if let Some(v) = t.strip_prefix("api_key:") {
                key = Some(unquote(v));
            }
        }
    }
    flush(&name, &api, &key, &mut found);
    found
}

fn unquote(v: &str) -> String {
    v.trim().trim_matches('"').trim_matches('\'').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const HERMES: &str = "\
model:
  default: alias-large
  api_key: should-not-be-a-provider
providers:
  blablador:
    api: https://api.blablador.fz-juelich.de/v1
    api_key: abc123
    models:
      - alias-large
  elsewhere:
    api: https://example.org/v1
    api_key: \"quoted-key\"
  from-env:
    api: https://example.org/v1
    api_key: env:MY_KEY
  keyless:
    api: https://example.org/v1
other:
  api: https://nope/v1
  api_key: nope
";

    #[test]
    fn reads_providers_with_their_api_and_key() {
        let found = hermes_keys(HERMES);
        let labels: Vec<&str> = found.iter().map(|f| f.label.as_str()).collect();
        assert_eq!(labels, vec!["Hermes (blablador)", "Hermes (elsewhere)"]);
        assert_eq!(found[0].base_url, "https://api.blablador.fz-juelich.de/v1");
        assert_eq!(found[0].key, "abc123");
        assert_eq!(found[1].key, "quoted-key", "quotes around a key are not part of it");
    }

    #[test]
    fn skips_env_references_and_keys_outside_providers() {
        let found = hermes_keys(HERMES);
        assert!(found.iter().all(|f| f.key != "env:MY_KEY"), "an env: reference is not a key");
        assert!(found.iter().all(|f| f.key != "should-not-be-a-provider"), "the model block is not a provider");
        assert!(found.iter().all(|f| f.key != "nope"), "a key outside providers: is not a provider key");
    }

    #[test]
    fn a_missing_api_line_leaves_the_provider_out() {
        assert!(hermes_keys("providers:\n  broken:\n    api_key: k\n").is_empty());
    }

    #[test]
    fn a_helmholtz_token_is_offered_to_blablador() {
        let blablador = "https://api.blablador.fz-juelich.de/v1";
        let (label, url) = env_key("glpat-Gu3xYz", blablador).unwrap();
        assert_eq!(label, "Helmholtz token in OPENAI_API_KEY");
        assert_eq!(url, blablador, "a glpat- token is the shape of a Blablador key, not an OpenAI one");
        assert_eq!(env_key("sk-proj-abc", blablador).unwrap().1, "https://api.openai.com/v1");
        assert!(env_key("", blablador).is_none());
        assert!(env_key("short", blablador).is_none(), "a short value is not a key");
    }

    #[test]
    fn separates_chat_models_from_the_rest() {
        assert!(is_chat("deepseek-v4.1-flash-at-hzdr"));
        assert!(is_chat("01 - GPT-OSS-120b"));
        assert!(!is_chat("alias-embeddings"));
        assert!(!is_chat("alias-qwen3-8b-reranking"));
        assert!(!is_chat("faster-whisper-large-v3"));
        assert!(!is_chat("999 - flux2"));
        assert!(!is_chat("alias-esmfold2"));
        assert!(!is_chat("alias-bindcraft"));
    }

    #[test]
    fn an_empty_key_is_refused_before_any_request() {
        let err = probe("https://example.org/v1", "  ", Duration::from_secs(1)).unwrap_err();
        assert!(err.contains("no key"), "{err}");
    }
}
