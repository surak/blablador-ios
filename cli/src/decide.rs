//! `/decide`: asks Blablador's decision model (`alias-clef`, `POST /v1/systemone`) a few typed questions about a
//! situation, the same requests as the apps' `DecisionView`. An assistant walks through it one simple question at
//! a time: the situation, then each question and its kind, until an empty line sends them all.

use serde_json::{json, Map, Value};
use std::time::Duration;

pub const MODEL: &str = "alias-clef";

#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    YesNo,
    Choice(Vec<String>),
    Score(Vec<String>),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Question {
    pub text: String,
    pub kind: Kind,
}

impl Question {
    fn id(i: usize) -> String {
        format!("q{}", i + 1)
    }

    /// Options get the keys a, b, c… as the apps' examples do.
    fn key(i: usize) -> String {
        ((b'a' + i as u8) as char).to_string()
    }

    fn wire(&self) -> Value {
        match &self.kind {
            Kind::YesNo => json!({"type": "noul", "instructions": self.text}),
            Kind::Choice(options) => {
                let criteria: Map<String, Value> = options.iter().enumerate().map(|(i, o)| (Self::key(i), json!(o))).collect();
                json!({"type": "choice", "instructions": self.text, "criteria": criteria})
            }
            Kind::Score(levels) => json!({"type": "score", "instructions": self.text, "criteria": levels}),
        }
    }
}

enum Step {
    Situation,
    Question,
    Kind(String),
    Options(String),
    Levels(String),
}

/// What the assistant says next, or the decision ready to be sent.
pub enum Next {
    Ask(String),
    Send { state: String, questions: Vec<Question> },
    Cancelled,
}

pub struct Wizard {
    step: Step,
    state: String,
    questions: Vec<Question>,
}

const DEFAULT_LEVELS: [&str; 3] = ["Low", "Medium", "High"];

fn list(line: &str) -> Vec<String> {
    line.split([',', '|', ';']).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}

impl Wizard {
    /// Starts the assistant; `args` after `/decide` is taken as the situation.
    pub fn start(args: &str) -> (Wizard, String) {
        let mut w = Wizard { step: Step::Situation, state: String::new(), questions: Vec::new() };
        if args.trim().is_empty() {
            (w, "Decision assistant (alias-clef). What's the situation? Describe it in a few sentences. (/cancel stops)".into())
        } else {
            w.state = args.trim().into();
            w.step = Step::Question;
            (w, "What do you want to ask about it? (one question)".into())
        }
    }

    pub fn feed(&mut self, line: &str) -> Next {
        let line = line.trim();
        if line == "/cancel" || line == "/stop" {
            return Next::Cancelled;
        }
        let step = std::mem::replace(&mut self.step, Step::Question);
        match step {
            Step::Situation if line.is_empty() => {
                self.step = Step::Situation;
                Next::Ask("Tell me the situation first.".into())
            }
            Step::Situation => {
                self.state = line.into();
                Next::Ask("What do you want to ask about it? (one question)".into())
            }
            Step::Question if line.is_empty() && self.questions.is_empty() => Next::Ask("Ask at least one question.".into()),
            Step::Question if line.is_empty() => {
                Next::Send { state: std::mem::take(&mut self.state), questions: std::mem::take(&mut self.questions) }
            }
            Step::Question => {
                self.step = Step::Kind(line.into());
                Next::Ask("What kind of answer? 1) yes or no  2) pick one of several options  3) a score on a scale".into())
            }
            Step::Kind(text) => match line.to_lowercase().as_str() {
                "1" | "y" | "yes" | "yes/no" | "yes or no" | "" => self.add(text, Kind::YesNo),
                "2" | "c" | "choice" | "pick" | "options" => {
                    self.step = Step::Options(text);
                    Next::Ask("Which options? Separate them with commas.".into())
                }
                "3" | "s" | "score" | "scale" => {
                    self.step = Step::Levels(text);
                    Next::Ask("Which levels, lowest first, separated by commas? (Enter for Low, Medium, High)".into())
                }
                _ => {
                    self.step = Step::Kind(text);
                    Next::Ask("Type 1, 2 or 3.".into())
                }
            },
            Step::Options(text) => {
                let options = list(line);
                if options.len() < 2 || options.len() > 26 {
                    self.step = Step::Options(text);
                    return Next::Ask("Give at least two options, separated by commas.".into());
                }
                self.add(text, Kind::Choice(options))
            }
            Step::Levels(text) => {
                let levels = if line.is_empty() { DEFAULT_LEVELS.iter().map(|s| s.to_string()).collect() } else { list(line) };
                if levels.len() < 2 {
                    self.step = Step::Levels(text);
                    return Next::Ask("Give at least two levels, separated by commas.".into());
                }
                self.add(text, Kind::Score(levels))
            }
        }
    }

    fn add(&mut self, text: String, kind: Kind) -> Next {
        self.questions.push(Question { text, kind });
        self.step = Step::Question;
        Next::Ask(format!("Got {}. Another question? (Enter to ask Clef now)", self.questions.len()))
    }
}

pub fn body(state: &str, questions: &[Question]) -> Value {
    let qs: Map<String, Value> = questions.iter().enumerate().map(|(i, q)| (Question::id(i), q.wire())).collect();
    json!({"model": MODEL, "state": state, "questions": qs})
}

/// Sends the decision; returns the answers by question id.
pub fn ask(endpoint: &str, key: &str, state: &str, questions: &[Question]) -> Result<Value, String> {
    let url = format!("{}/systemone", endpoint.trim_end_matches('/'));
    let response = ureq::post(&url)
        .timeout(Duration::from_secs(90))
        .set("Authorization", &format!("Bearer {key}"))
        .send_json(body(state, questions));
    match response {
        Ok(r) => {
            let v: Value = r.into_json().map_err(|e| e.to_string())?;
            Ok(v["answers"].clone())
        }
        Err(ureq::Error::Status(code, r)) => {
            let text = r.into_string().unwrap_or_default();
            Err(format!("Clef answered {code}: {}", text.chars().take(300).collect::<String>()))
        }
        Err(e) => Err(e.to_string()),
    }
}

fn percent(p: f64) -> String {
    format!("{}%", (p * 100.0).round() as i64)
}

fn bar(p: f64) -> String {
    let n = (p.clamp(0.0, 1.0) * 20.0).round() as usize;
    format!("{}{}", "█".repeat(n), "░".repeat(20 - n))
}

/// The answers as text, like the apps' `DecisionAnswer.summary`, with a bar per probability.
pub fn summary(questions: &[Question], answers: &Value) -> String {
    let mut out = Vec::new();
    for (i, q) in questions.iter().enumerate() {
        let a = &answers[Question::id(i)];
        let mut lines = vec![format!("{}", q.text)];
        if a.is_null() {
            lines.push("  no answer".into());
            out.push(lines.join("\n"));
            continue;
        }
        match &q.kind {
            Kind::YesNo => {
                let yes = a["noul"].as_f64().unwrap_or(0.0);
                let verdict = if yes >= 0.5 { format!("Yes ({})", percent(yes)) } else { format!("No ({} sure)", percent(1.0 - yes)) };
                lines.push(format!("  → {verdict}"));
                lines.push(format!("  yes {} {}", bar(yes), percent(yes)));
            }
            Kind::Choice(options) => {
                let picked = a["choice"].as_str().unwrap_or_default();
                for (j, o) in options.iter().enumerate() {
                    let key = Question::key(j);
                    let p = a["probabilities"][&key].as_f64().unwrap_or(0.0);
                    let mark = if key == picked { "→" } else { " " };
                    lines.push(format!("  {mark} {} {} {o}", bar(p), percent(p)));
                }
            }
            Kind::Score(levels) => {
                let score = a["score"].as_f64().map(|s| format!("{s:.2}")).unwrap_or("?".into());
                lines.push(format!("  → {score} on {}", levels.join(" → ")));
                for (j, l) in levels.iter().enumerate() {
                    let p = a["probabilities"][j.to_string()].as_f64().or_else(|| a["probabilities"][l].as_f64());
                    if let Some(p) = p {
                        lines.push(format!("    {} {} {l}", bar(p), percent(p)));
                    }
                }
            }
        }
        if let Some(c) = a["confidence"].as_f64() {
            lines.push(format!("  confidence {}", percent(c)));
        }
        out.push(lines.join("\n"));
    }
    out.join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(w: &mut Wizard, lines: &[&str]) -> Next {
        let mut last = Next::Cancelled;
        for l in lines {
            last = w.feed(l);
        }
        last
    }

    #[test]
    fn the_assistant_builds_the_request() {
        let (mut w, _) = Wizard::start("");
        let next = run(&mut w, &["Release on Friday, two tests fail.", "Delay it?", "1", "Fix first?", "2", "flaky test, regression", "Risk?", "3", "", ""]);
        let Next::Send { state, questions } = next else { panic!("not sent") };
        let b = body(&state, &questions);
        assert_eq!(b["model"], "alias-clef");
        assert_eq!(b["state"], "Release on Friday, two tests fail.");
        assert_eq!(b["questions"]["q1"], json!({"type": "noul", "instructions": "Delay it?"}));
        assert_eq!(b["questions"]["q2"]["criteria"], json!({"a": "flaky test", "b": "regression"}));
        assert_eq!(b["questions"]["q3"]["criteria"], json!(["Low", "Medium", "High"]));
    }

    #[test]
    fn it_insists_on_what_it_needs() {
        let (mut w, _) = Wizard::start("A situation");
        assert!(matches!(w.feed(""), Next::Ask(_)));
        assert!(matches!(run(&mut w, &["Which?", "2", "only one"]), Next::Ask(s) if s.contains("two")));
        assert!(matches!(w.feed("/cancel"), Next::Cancelled));
    }

    #[test]
    fn answers_read_as_text() {
        let qs = vec![
            Question { text: "Delay?".into(), kind: Kind::YesNo },
            Question { text: "First?".into(), kind: Kind::Choice(vec!["x".into(), "y".into()]) },
        ];
        let answers = json!({"q1": {"type": "noul", "noul": 0.2}, "q2": {"type": "choice", "choice": "b", "probabilities": {"a": 0.3, "b": 0.7}}});
        let text = summary(&qs, &answers);
        assert!(text.contains("No (80% sure)"));
        assert!(text.contains("→ ██████████████░░░░░░ 70% y"));
    }
}
