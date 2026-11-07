//! Tools the model can call: web search and page reading, memory, earlier chats and shell commands.

use crate::extract;
use crate::model::{words, Conversation};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;

const SEARCH_URL: &str = "https://search.blablador.fz-juelich.de/search";
const MAX_RESULTS: usize = 6;
/// Characters of page text handed to the model.
const MAX_PAGE: usize = 24_000;
const MAX_COMMAND_OUTPUT: usize = 20_000;

fn function(name: &str, description: &str, properties: Value, required: &[&str]) -> Value {
    json!({
        "type": "function",
        "function": { "name": name, "description": description, "parameters": { "type": "object", "properties": properties, "required": required } }
    })
}

pub fn web_search_tool() -> Value {
    function(
        "web_search",
        "Search the web for current information, news, facts or anything you are unsure about. Returns titles, URLs and snippets.",
        json!({
            "query": { "type": "string", "description": "The search query. Use specific keywords, not dates." },
            "category": { "type": "string", "enum": ["general", "news", "science", "it"], "description": "Use news for current events and headlines, science for papers, it for programming. Defaults to general." },
            "time_range": { "type": "string", "enum": ["day", "week", "month", "year"], "description": "Only return results from this period, e.g. day for today's news." }
        }),
        &["query"],
    )
}

pub fn read_page_tool() -> Value {
    function(
        "read_page",
        "Read the text of a web page or online PDF. Use it for links the user gives you and to read search results in full when the snippet is not enough.",
        json!({ "url": { "type": "string", "description": "The full http(s) address." } }),
        &["url"],
    )
}

pub const WEB_PROMPT: &str = " You can use the web_search tool for current or uncertain information, and read_page to read a link the user gives you or a search result in full. Cite sources inline as [1], [2] matching the search results. When asked about a person, place or thing you don't know well, search the web first instead of saying you don't know.";

pub fn remember_tool() -> Value {
    function(
        "remember",
        "Save a lasting fact about the user to long-term memory, available in future chats.",
        json!({ "fact": { "type": "string", "description": "One short fact in the third person, e.g. \"Works as a chemist in Jülich.\"" } }),
        &["fact"],
    )
}

pub fn forget_tool() -> Value {
    function(
        "forget",
        "Delete a memory that is wrong or that the user wants forgotten.",
        json!({ "number": { "type": "integer", "description": "The memory's number in the list of what you remember." } }),
        &["number"],
    )
}

pub fn search_chats_tool() -> Value {
    function(
        "search_chats",
        "Search the user's earlier chats in this app, e.g. when they refer to something discussed before (\"what did we say about…\", \"like last time\").",
        json!({ "query": { "type": "string", "description": "Keywords to look for." } }),
        &["query"],
    )
}

pub fn run_command_tool() -> Value {
    let shell = if cfg!(windows) { "cmd.exe" } else { "sh" };
    function(
        "run_command",
        &format!("Run a shell command ({shell}) in the user's chosen folder and get its output. The user approves each command first."),
        json!({ "command": { "type": "string", "description": "The command line to run." } }),
        &["command"],
    )
}

pub async fn web_search(arguments: &Value) -> Result<String> {
    let query = arguments["query"].as_str().unwrap_or_default();
    let mut parameters = vec![("q", query.to_string()), ("format", "json".into())];
    if let Some(category) = arguments["category"].as_str().filter(|c| ["general", "news", "science", "it"].contains(c)) {
        parameters.push(("categories", category.into()));
    }
    if let Some(range) = arguments["time_range"].as_str().filter(|r| ["day", "week", "month", "year"].contains(r)) {
        parameters.push(("time_range", range.into()));
    }
    let response = reqwest::Client::new().get(SEARCH_URL).query(&parameters).timeout(Duration::from_secs(30)).send().await?;
    if !response.status().is_success() {
        return Err(anyhow!("Web search failed ({}).", response.status()));
    }
    let value: Value = response.json().await?;
    let results: Vec<String> = value["results"]
        .as_array()
        .into_iter()
        .flatten()
        .take(MAX_RESULTS)
        .enumerate()
        .map(|(i, r)| format!("[{}] {}\nURL: {}\n{}", i + 1, r["title"].as_str().unwrap_or(""), r["url"].as_str().unwrap_or(""), r["content"].as_str().unwrap_or("")))
        .collect();
    Ok(if results.is_empty() { format!("No results for \"{query}\".") } else { results.join("\n\n") })
}

/// Refuses local addresses, so a page or prompt can't make the app read from the user's own network.
pub fn is_public(url: &url::Url) -> bool {
    if !matches!(url.scheme(), "http" | "https") {
        return false;
    }
    match url.host() {
        Some(url::Host::Domain(host)) => {
            let host = host.to_lowercase();
            !(host == "localhost" || [".local", ".localhost", ".internal"].iter().any(|s| host.ends_with(s)) || !host.contains('.'))
        }
        Some(url::Host::Ipv4(ip)) => {
            let [a, b, ..] = ip.octets();
            !(ip.is_private() || ip.is_loopback() || ip.is_link_local() || ip.is_unspecified() || a == 0 || (a == 100 && (64..=127).contains(&b)))
        }
        _ => false,
    }
}

pub async fn read_page(arguments: &Value) -> Result<String> {
    let address = arguments["url"].as_str().unwrap_or_default().trim();
    let mut url = url::Url::parse(address).map_err(|_| anyhow!("Only public http(s) pages can be read."))?;
    if url.scheme() == "http" {
        let _ = url.set_scheme("https");
    }
    if !is_public(&url) {
        return Err(anyhow!("Only public http(s) pages can be read."));
    }
    // Every redirect is checked too.
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() > 8 || !is_public(attempt.url()) { attempt.stop() } else { attempt.follow() }
        }))
        .user_agent("Mozilla/5.0 (compatible; Blablador)")
        .timeout(Duration::from_secs(30))
        .build()?;
    let response = client.get(url).header("Accept", "text/html,application/xhtml+xml,application/pdf,text/plain;q=0.9,*/*;q=0.5").send().await?;
    let final_url = response.url().clone();
    if !response.status().is_success() {
        return Err(anyhow!("The page could not be loaded ({}).", response.status()));
    }
    let kind = response.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_lowercase();
    let bytes = response.bytes().await?;
    let cut = |text: String| text.chars().take(MAX_PAGE).collect::<String>();
    if kind.contains("application/pdf") || bytes.starts_with(b"%PDF") {
        return Ok(format!("{final_url}\n\n{}", cut(extract::pdf_text(&bytes)?)));
    }
    if !(kind.is_empty() || kind.starts_with("text/") || kind.contains("html") || kind.contains("xml") || kind.contains("json")) {
        return Err(anyhow!("This link is not a web page or PDF ({kind})."));
    }
    let html = String::from_utf8_lossy(&bytes[..bytes.len().min(3_000_000)]).into_owned();
    if !kind.contains("html") && !html.to_lowercase().contains("<html") {
        return Ok(format!("{final_url}\n\n{}", cut(html)));
    }
    let title = page_title(&html).unwrap_or_else(|| final_url.to_string());
    Ok(format!("{title}\n{final_url}\n\n{}", cut(readable_text(&html))))
}

fn page_title(html: &str) -> Option<String> {
    let title = regex::Regex::new(r"(?is)<title[^>]*>(.*?)</title>").unwrap().captures(html)?[1].to_string();
    let title = decode_entities(&regex::Regex::new(r"<[^>]+>").unwrap().replace_all(&title, "")).trim().to_string();
    (!title.is_empty()).then_some(title)
}

/// The page's main text, without scripts, menus and footers; headings, list items and paragraphs on their own lines.
pub fn readable_text(html: &str) -> String {
    let re = |pattern: &str| regex::Regex::new(pattern).unwrap();
    let mut body = html.to_string();
    for tag in ["article", "main"] {
        if let Some(found) = re(&format!(r"(?is)<{tag}[\s>].*</{tag}>")).find(html) {
            if found.as_str().len() > 500 {
                body = found.as_str().to_string();
                break;
            }
        }
    }
    // The regex crate has no backreferences, so each tag is removed with its own pattern.
    for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "aside", "form", "template", "iframe"] {
        body = re(&format!(r"(?is)<{tag}[\s>].*?</{tag}>")).replace_all(&body, " ").into_owned();
    }
    for (pattern, replacement) in [
        (r"(?s)<!--.*?-->", " "),
        (r"(?i)<h[1-6][^>]*>", "\n\n## "),
        (r"(?i)<li[^>]*>", "\n- "),
        (r"(?i)<(br|/p|/div|/h[1-6]|/tr|/li|/section|/table|p|div|tr)(\s[^>]*)?/?>", "\n"),
        (r"(?i)<(td|th)[^>]*>", " | "),
        (r"<[^>]+>", ""),
    ] {
        body = re(pattern).replace_all(&body, replacement).into_owned();
    }
    let body = decode_entities(&body);
    let spaces = re(r"[ \t\u{00A0}]+");
    let mut lines: Vec<String> = Vec::new();
    for line in body.lines().map(|l| spaces.replace_all(l, " ").trim().to_string()) {
        if line.is_empty() && lines.last().map_or(true, |l| l.is_empty()) {
            continue;
        }
        // A list marker whose text ended up on a later line: join them.
        if !line.is_empty() {
            if let Some(last) = lines.len().checked_sub(1) {
                let previous = if lines[last].is_empty() && last > 0 { last - 1 } else { last };
                if lines[previous] == "-" || lines[previous] == "##" {
                    lines[previous] = format!("{} {line}", lines[previous]);
                    lines.truncate(previous + 1);
                    continue;
                }
            }
        }
        lines.push(line);
    }
    lines.join("\n").trim().to_string()
}

fn decode_entities(text: &str) -> String {
    let mut text = text.to_string();
    for (entity, character) in [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“"),
    ] {
        text = text.replace(entity, character);
    }
    let numeric = regex::Regex::new(r"&#(x?)([0-9a-fA-F]+);").unwrap();
    let text = numeric.replace_all(&text, |c: &regex::Captures| {
        let radix = if &c[1] == "x" { 16 } else { 10 };
        u32::from_str_radix(&c[2], radix).ok().and_then(char::from_u32).map(String::from).unwrap_or_else(|| c[0].to_string())
    });
    text.replace("&amp;", "&")
}

/// Passages of earlier chats that share words with the query.
pub fn search_chats(query: &str, chats: &[Conversation]) -> String {
    let asked = words(query);
    let mut hits: Vec<(usize, String)> = Vec::new();
    for chat in chats {
        for message in &chat.messages {
            let score = words(&message.content).intersection(&asked).count();
            if score > 0 {
                let excerpt: String = message.content.chars().take(600).collect();
                hits.push((score, format!("Chat \"{}\" ({}):\n{excerpt}", chat.title, chat.updated.format("%Y-%m-%d"))));
            }
        }
    }
    hits.sort_by(|a, b| b.0.cmp(&a.0));
    if hits.is_empty() {
        return format!("No earlier chats mention \"{query}\".");
    }
    hits.into_iter().take(MAX_RESULTS).map(|(_, text)| text).collect::<Vec<_>>().join("\n\n")
}

/// Runs a command in `folder` with a two-minute limit; output and exit status go back to the model.
pub async fn run_command(command: &str, folder: &Path) -> Result<String> {
    let mut process = if cfg!(windows) {
        let mut p = tokio::process::Command::new("cmd");
        p.arg("/C").arg(command);
        p
    } else {
        let mut p = tokio::process::Command::new("sh");
        p.arg("-lc").arg(command);
        p
    };
    process.current_dir(folder).stdin(std::process::Stdio::null()).kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(120), process.output())
        .await
        .map_err(|_| anyhow!("The command didn't finish within two minutes and was stopped."))??;
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    let errors = String::from_utf8_lossy(&output.stderr);
    if !errors.trim().is_empty() {
        text += &format!("\n[stderr]\n{errors}");
    }
    if text.chars().count() > MAX_COMMAND_OUTPUT {
        text = text.chars().take(MAX_COMMAND_OUTPUT).collect::<String>() + "\n… (output cut)";
    }
    Ok(format!("Exit status: {}\n{}", output.status.code().map_or("killed".into(), |c| c.to_string()), text.trim()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_local_addresses() {
        for address in ["http://localhost/x", "https://192.168.1.1", "https://10.0.0.2", "file:///etc/passwd", "https://intranet/", "https://[::1]/"] {
            assert!(!is_public(&url::Url::parse(address).unwrap()), "{address}");
        }
        assert!(is_public(&url::Url::parse("https://fz-juelich.de/en").unwrap()));
    }

    #[test]
    fn reads_html() {
        let html = "<html><head><title>T &amp; U</title><script>x()</script></head><body><nav>menu</nav><h1>Hello</h1><p>One &#8212; two</p><ul><li>a</li></ul></body></html>";
        assert_eq!(page_title(html).unwrap(), "T & U");
        let text = readable_text(html);
        assert!(text.contains("## Hello") && text.contains("One — two") && text.contains("- a"), "{text}");
        assert!(!text.contains("menu") && !text.contains("x()"));
    }
}
