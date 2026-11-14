//! End to end: the agent against a fake OpenAI-compatible server that streams scripted replies.

use crate::agent::Agent;
use crate::llm::Usage;
use crate::plugin::{Host, Plugin, ToolOutput};
use crate::plugins::{checkpoints::Checkpoints, core_tools::CoreTools, openai, permissions};
use crate::session::Session;
use crate::ui::{Approval, Ui};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

/// Serves one scripted SSE reply per request and keeps the request bodies.
fn fake_server(replies: Vec<Vec<Value>>) -> (String, Arc<Mutex<Vec<Value>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}/v1", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    std::thread::spawn(move || {
        for (stream, chunks) in listener.incoming().zip(replies) {
            let mut stream = stream.unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if let Some(v) = line.to_lowercase().strip_prefix("content-length:") {
                    length = v.trim().parse().unwrap();
                }
                if line == "\r\n" {
                    break;
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            log.lock().unwrap().push(serde_json::from_slice(&body).unwrap());
            let mut out = String::from("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n");
            for c in chunks {
                out.push_str(&format!("data: {c}\n\n"));
            }
            out.push_str("data: [DONE]\n\n");
            stream.write_all(out.as_bytes()).unwrap();
        }
    });
    (address, seen)
}

#[derive(Default)]
struct Recorder {
    text: String,
    tools: Vec<(String, ToolOutput)>,
    asked: Vec<String>,
    answer: Option<Approval>,
}

impl Ui for Recorder {
    fn text(&mut self, text: &str) {
        self.text.push_str(text);
    }
    fn thinking(&mut self, _text: &str) {}
    fn end_reply(&mut self) {}
    fn tool_start(&mut self, _name: &str, _summary: &str) {}
    fn tool_end(&mut self, name: &str, output: &ToolOutput) {
        self.tools.push((name.into(), output.clone()));
    }
    fn approve(&mut self, name: &str, _summary: &str, _reason: &str) -> Approval {
        self.asked.push(name.into());
        self.answer.unwrap_or(Approval::No)
    }
    fn notice(&mut self, _text: &str) {}
    fn error(&mut self, _text: &str) {}
    fn usage(&mut self, _usage: &Usage) {}
}

fn call(id: &str, name: &str, args: Value) -> Value {
    json!({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": id, "function": {"name": name, "arguments": args.to_string()}}]}, "finish_reason": "tool_calls"}]})
}

fn text(t: &str) -> Value {
    json!({"choices": [{"delta": {"content": t}, "finish_reason": "stop"}]})
}

fn agent(address: &str, dir: &std::path::Path, mode: permissions::Mode) -> Agent {
    let provider = openai::OpenAi::new(address, "test-key".into(), false).unwrap();
    let plugins: Vec<Arc<dyn Plugin>> = vec![
        Arc::new(openai::OpenAiPlugin::new(provider)),
        Arc::new(permissions::Permissions::new(mode, &[], &[], &[], false)),
        Arc::new(CoreTools::new()),
        Arc::new(Checkpoints::default()),
    ];
    let host = Host::new(plugins);
    let provider = host.provider("openai").unwrap();
    Agent::new(host, provider, Session::new(dir, "m"), "m".into())
}

fn temp() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("bla-e2e-{}", crate::util::random_hex(8)));
    std::fs::create_dir_all(&dir).unwrap();
    dir.canonicalize().unwrap()
}

#[test]
fn runs_tools_until_the_answer() {
    let dir = temp();
    let (address, seen) = fake_server(vec![
        vec![call("c1", "write", json!({"path": "hello.txt", "content": "hi\n"}))],
        vec![call("c2", "read", json!({"path": "hello.txt"}))],
        vec![text("Done: hello.txt says hi.")],
    ]);
    let mut agent = agent(&address, &dir, permissions::Mode::Default);
    let mut ui = Recorder::default();
    agent.turn("make hello.txt", &mut ui).unwrap();
    assert_eq!(std::fs::read_to_string(dir.join("hello.txt")).unwrap(), "hi\n");
    assert_eq!(ui.text, "Done: hello.txt says hi.");
    assert_eq!(ui.tools.len(), 2);
    assert!(ui.asked.is_empty());
    let requests = seen.lock().unwrap();
    assert_eq!(requests.len(), 3);
    // The last request carries the whole history: user, call, result, call, result.
    let messages = requests[2]["messages"].as_array().unwrap();
    assert_eq!(messages.iter().map(|m| m["role"].as_str().unwrap()).collect::<Vec<_>>(), ["system", "user", "assistant", "tool", "assistant", "tool"]);
    assert!(messages[5]["content"].as_str().unwrap().contains("1\thi"));
    assert_eq!(requests[0]["tools"].as_array().unwrap().len(), 4);
    // Everything is in the session log.
    let back = Session::open(&agent.session.id).unwrap();
    assert_eq!(back.messages.len(), 6);
    // /undo removes the file the turn created.
    assert!(matches!(agent.command("undo", ""), Some(Ok(_))));
    assert!(!dir.join("hello.txt").exists());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn asks_and_respects_no() {
    let dir = temp();
    let (address, _) = fake_server(vec![vec![call("c1", "bash", json!({"command": "touch made-it"}))], vec![text("ok")]]);
    let mut agent = agent(&address, &dir, permissions::Mode::Default);
    let mut ui = Recorder { answer: Some(Approval::No), ..Default::default() };
    agent.turn("run it", &mut ui).unwrap();
    assert_eq!(ui.asked, ["bash"]);
    assert!(!dir.join("made-it").exists());
    let result = agent.session.messages.iter().find(|m| m.role == "tool").unwrap();
    assert!(result.content.contains("declined"));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn bad_arguments_and_unknown_tools_are_answered() {
    let dir = temp();
    let broken = json!({"choices": [{"delta": {"tool_calls": [
        {"index": 0, "id": "a", "function": {"name": "read", "arguments": "{not json"}},
        {"index": 1, "id": "b", "function": {"name": "nope", "arguments": "{}"}}
    ]}, "finish_reason": "tool_calls"}]});
    let (address, _) = fake_server(vec![vec![broken], vec![text("sorry")]]);
    let mut agent = agent(&address, &dir, permissions::Mode::Default);
    let mut ui = Recorder::default();
    agent.turn("x", &mut ui).unwrap();
    let results: Vec<_> = agent.session.messages.iter().filter(|m| m.role == "tool").map(|m| m.content.clone()).collect();
    assert!(results[0].contains("not valid JSON"));
    assert!(results[1].contains("no tool called nope"));
    let _ = std::fs::remove_dir_all(dir);
}
