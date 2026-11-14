//! Plans and goals. `update_plan` keeps a visible checklist for multi-step work. `/goal <text>` sets a goal the
//! agent keeps working on until it calls `goal_status` with done or blocked: when it stops before that, the turn is
//! kept going with a nudge (the core allows a few continuations per turn), as in the Blablador apps.

use crate::llm::Message;
use crate::plugin::{CommandResult, CommandSpec, Ctx, Kind, Plugin, Session, Tool, ToolCtx, ToolOutput};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct State {
    plan: Vec<(String, String)>,
    goal: Option<String>,
    /// done or blocked, with the summary.
    settled: Option<(String, String)>,
}

fn mark(status: &str) -> &'static str {
    match status {
        "done" | "completed" => "☑",
        "in_progress" => "◐",
        _ => "☐",
    }
}

fn checklist(plan: &[(String, String)]) -> String {
    plan.iter().map(|(step, status)| format!("{} {step}", mark(status))).collect::<Vec<_>>().join("\n")
}

struct UpdatePlan {
    state: Arc<Mutex<State>>,
}

impl Tool for UpdatePlan {
    fn name(&self) -> &str {
        "update_plan"
    }
    fn description(&self) -> &str {
        "Keep a short plan for work with several steps: send the whole list each time, each step with status pending, \
         in_progress (one at a time) or done. Update it as you go; skip it for simple one-step tasks."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {"plan": {"type": "array", "items": {"type": "object", "properties": {
            "step": {"type": "string"},
            "status": {"type": "string", "enum": ["pending", "in_progress", "done"]}
        }, "required": ["step", "status"]}}}, "required": ["plan"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Internal
    }
    fn summary(&self, args: &Value) -> String {
        let items = args["plan"].as_array().map(|a| a.len()).unwrap_or(0);
        let done = args["plan"].as_array().into_iter().flatten().filter(|i| i["status"] == "done").count();
        format!("{done}/{items} done")
    }
    fn run(&self, args: &Value, _ctx: &ToolCtx) -> ToolOutput {
        let Some(items) = args["plan"].as_array() else { return ToolOutput::err("Give plan: a list of {step, status}.") };
        let plan: Vec<(String, String)> =
            items.iter().filter_map(|i| Some((i["step"].as_str()?.trim().to_string(), i["status"].as_str().unwrap_or("pending").to_string()))).collect();
        if plan.is_empty() {
            return ToolOutput::err("The plan has no steps.");
        }
        let text = checklist(&plan);
        self.state.lock().unwrap().plan = plan;
        ToolOutput::ok(text)
    }
}

struct GoalStatus {
    state: Arc<Mutex<State>>,
}

impl Tool for GoalStatus {
    fn name(&self) -> &str {
        "goal_status"
    }
    fn description(&self) -> &str {
        "Only while a goal is set (/goal): report done when the goal is reached and verified, or blocked when you need the \
         user, with a short summary of what was done and what is left."
    }
    fn parameters(&self) -> Value {
        json!({"type": "object", "properties": {
            "status": {"type": "string", "enum": ["done", "blocked"]},
            "summary": {"type": "string"}
        }, "required": ["status", "summary"]})
    }
    fn kind(&self, _args: &Value) -> Kind {
        Kind::Internal
    }
    fn summary(&self, args: &Value) -> String {
        args["status"].as_str().unwrap_or_default().to_string()
    }
    fn run(&self, args: &Value, _ctx: &ToolCtx) -> ToolOutput {
        let mut state = self.state.lock().unwrap();
        if state.goal.is_none() {
            return ToolOutput::err("No goal is set.");
        }
        let status = if args["status"] == "done" { "done" } else { "blocked" };
        let summary = args["summary"].as_str().unwrap_or_default().to_string();
        state.settled = Some((status.into(), summary));
        ToolOutput::ok(if status == "done" { "Goal reached. Tell the user briefly what was done." } else { "Noted. Tell the user what you need from them." })
    }
}

pub struct Plan {
    state: Arc<Mutex<State>>,
}

impl Plan {
    pub fn new() -> Plan {
        Plan { state: Arc::default() }
    }
}

impl Plugin for Plan {
    fn name(&self) -> &str {
        "plan"
    }
    fn description(&self) -> &str {
        "update_plan checklists and /goal: keep working until a goal is reached"
    }
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        vec![Arc::new(UpdatePlan { state: self.state.clone() }), Arc::new(GoalStatus { state: self.state.clone() })]
    }
    fn commands(&self) -> Vec<CommandSpec> {
        vec![
            CommandSpec { name: "goal".into(), help: "TEXT: work until it is reached; /goal shows it, /goal clear ends it".into() },
            CommandSpec { name: "plan".into(), help: "show the current plan".into() },
        ]
    }
    fn system_prompt(&self, _session: &Session, sections: &mut Vec<String>) {
        sections.push(
            "For work with several steps, keep a plan with update_plan and mark steps done as you finish them. When a goal is set \
             (the user's message starts with GOAL:), keep working through it without asking for confirmation until it is \
             reached and verified (run the tests or check the result), then call goal_status done; call goal_status blocked only \
             when you truly need the user."
                .into(),
        );
    }
    fn command(&self, _ctx: &Ctx, name: &str, args: &str, _messages: &mut Vec<Message>) -> Option<Result<CommandResult, String>> {
        let mut state = self.state.lock().unwrap();
        match name {
            "plan" => Some(Ok(CommandResult::Output(if state.plan.is_empty() { "No plan yet.".into() } else { checklist(&state.plan) }))),
            "goal" if args.is_empty() => Some(Ok(CommandResult::Output(match (&state.goal, &state.settled) {
                (None, _) => "No goal. /goal TEXT sets one.".into(),
                (Some(g), None) => format!("Goal (working): {g}"),
                (Some(g), Some((s, summary))) => format!("Goal ({s}): {g}\n{summary}"),
            }))),
            "goal" if args == "clear" || args == "end" => {
                state.goal = None;
                state.settled = None;
                Some(Ok(CommandResult::Output("Goal cleared.".into())))
            }
            "goal" => {
                state.goal = Some(args.to_string());
                state.settled = None;
                state.plan.clear();
                Some(Ok(CommandResult::Prompt(format!(
                    "GOAL: {args}\n\nWork towards this goal on your own: plan it with update_plan, do the work, verify it, and call goal_status when it is done or you are blocked."
                ))))
            }
            _ => None,
        }
    }
    fn turn_end(&self, _session: &Session, _messages: &[Message]) -> Option<String> {
        let state = self.state.lock().unwrap();
        match (&state.goal, &state.settled) {
            (Some(goal), None) => Some(format!(
                "The goal is not settled yet: {goal}\nKeep going with the next step. If it is reached and verified, call goal_status done; if you need the user, call goal_status blocked."
            )),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    #[test]
    fn plan_and_goal() {
        let plugin = Plan::new();
        let tools = plugin.tools();
        let cancel = AtomicBool::new(false);
        let ctx = ToolCtx { cwd: std::path::Path::new("."), cancel: &cancel };
        let out = tools[0].run(&json!({"plan": [{"step": "read", "status": "done"}, {"step": "fix", "status": "in_progress"}]}), &ctx);
        assert_eq!(out.content, "☑ read\n◐ fix");
        let session = Session { id: "s", cwd: std::path::Path::new("."), interactive: true };
        assert!(plugin.turn_end(&session, &[]).is_none());
        plugin.state.lock().unwrap().goal = Some("tests pass".into());
        assert!(plugin.turn_end(&session, &[]).unwrap().contains("tests pass"));
        assert!(!tools[1].run(&json!({"status": "done", "summary": "ok"}), &ctx).is_error);
        assert!(plugin.turn_end(&session, &[]).is_none());
    }
}
