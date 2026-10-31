import SwiftUI

/// One step of the plan the model keeps with update_plan for longer tasks.
struct PlanItem: Codable, Hashable, Identifiable {
    enum Status: String, Codable { case pending, active, done }
    var id = UUID()
    var text: String
    var status = Status.pending
}

/// A tool call as recorded for the trace under a reply: what ran, with which arguments, how long it took.
struct TraceCall: Codable, Hashable, Identifiable {
    var id = UUID()
    var tool: String
    /// Arguments as JSON, so the call can be run again.
    var arguments: String
    /// The start of what the tool returned to the model.
    var result = ""
    var seconds: Double = 0
    var state = AgentStep.State.running
}

/// How a reply came about: model, time, tokens and every tool call.
struct Trace: Codable, Hashable {
    var model: String
    var seconds: Double = 0
    var promptTokens = 0
    var completionTokens = 0
    var rounds = 0
    var calls: [TraceCall] = []
}

/// A mention in the composer (@web, @skill, @knowledge base…), sent with the message and kept on it.
struct Mention: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case tool, skill, knowledge, server }
    var kind: Kind
    /// Tool kind ("web", "python", "calendar"…), skill name, knowledge base or server id.
    var value: String
    var name: String
    var icon: String
    var id: String { kind.rawValue + ":" + value }
}

enum PlanTools {
    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "update_plan",
            "description": "Show the user your plan for a task that needs several steps, and update it as you go. Send the whole list every time, with each step's status.",
            "parameters": [
                "type": "object",
                "properties": [
                    "steps": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "step": ["type": "string", "description": "What this step does, in a few words."],
                                "status": ["type": "string", "enum": ["pending", "in_progress", "done"]]
                            ],
                            "required": ["step", "status"]
                        ]
                    ]
                ],
                "required": ["steps"]
            ]
        ]
    ]

    static let systemPrompt = "For a task that takes three or more steps or tool calls, first call update_plan with the steps, then call it again whenever a step is done or the plan changes (mark the current step in_progress). Work through the plan without stopping to ask unless you need the user's decision. Don't make a plan for simple questions."

    static func items(from arguments: [String: Any]) -> [PlanItem] {
        (arguments["steps"] as? [[String: Any]] ?? []).compactMap { step in
            guard let text = step["step"] as? String, !text.isEmpty else { return nil }
            let status: PlanItem.Status = switch step["status"] as? String {
            case "done", "completed": .done
            case "in_progress", "active": .active
            default: .pending
            }
            return PlanItem(text: text, status: status)
        }
    }

    static func summary(_ items: [PlanItem]) -> String {
        let done = items.filter { $0.status == .done }.count
        return "Plan updated (\(done) of \(items.count) done). Continue with the next step."
    }
}

/// After a task of several steps, drafts a skill from what was done so the user can save it with one tap.
@MainActor
enum SkillDrafter {
    /// Tool calls (not counting the plan, memory and skills) that make a task worth turning into a skill.
    static let minimumCalls = 3

    static func worthDrafting(_ trace: Trace?) -> Bool {
        guard let trace else { return false }
        let work = trace.calls.filter { !["update_plan", "remember", "forget", "use_skill", "suggest_skill"].contains($0.tool) && $0.state == .done }
        return work.count >= minimumCalls
    }

    /// Only the user's request, the tool names and arguments and the final answer are used, not what tools returned.
    static func draft(request: String, trace: Trace, answer: String, existing: [String], api: BlabladorAPI, model: String) async -> Skill? {
        let calls = trace.calls.map { "- \($0.tool) \($0.arguments.prefix(300))" }.joined(separator: "\n")
        var system = """
        You turn a task an assistant just completed into a reusable skill: instructions it can follow the next time \
        the user asks for something similar. Generalise from this one case (no specific names, dates or numbers \
        unless they always apply), list the steps and tools to use and what the result should look like. If the task \
        is a one-off that won't come back, reply with {}. Otherwise reply with only JSON: {"name": "Short name", \
        "description": "When to use it, one sentence", "instructions": "Markdown steps"}.
        """
        if !existing.isEmpty { system += "\n\nSkills that already exist (don't repeat them): " + existing.joined(separator: ", ") }
        let user = "Request:\n\(request.prefix(4_000))\n\nTool calls:\n\(calls.prefix(6_000))\n\nFinal answer (start):\n\(answer.prefix(2_000))"
        guard let text = try? await api.complete(model: BlabladorAPI.helperModel(else: model), system: system, user: user) else { return nil }
        let answer = ChatStore.splitThinking(text).answer
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any],
              let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let instructions = object["instructions"] as? String, !instructions.isEmpty,
              !existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return Skill(name: name, description: object["description"] as? String ?? "", instructions: instructions)
    }
}

/// The plan as a checklist at the top of a reply.
struct PlanCard: View {
    let items: [PlanItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Plan", systemImage: "checklist").scaledFont(.caption, weight: .semibold)
                Spacer()
                Text("\(items.filter { $0.status == .done }.count)/\(items.count)")
                    .scaledFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        switch item.status {
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .active: Image(systemName: "circle.dotted").foregroundStyle(Theme.gradient)
                        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                        }
                    }
                    .scaledFont(.caption)
                    Text(item.text)
                        .scaledFont(.callout)
                        .strikethrough(item.status == .done, color: .secondary)
                        .foregroundStyle(item.status == .done ? .secondary : .primary)
                        .fontWeight(item.status == .active ? .semibold : .regular)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// "4 tools · 12 s · 3,210 tokens" under a reply; opens the full trace.
struct TraceLine: View {
    let trace: Trace
    let messageID: UUID
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                Text(Self.summary(trace))
            }
            .scaledFont(.caption2)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show how this reply was made")
        .sheet(isPresented: $showing) {
            NavigationStack { TraceView(messageID: messageID) }
#if os(macOS)
                .frame(minWidth: 520, minHeight: 480)
#endif
        }
    }

    static func summary(_ trace: Trace) -> String {
        var parts: [String] = []
        if !trace.calls.isEmpty { parts.append("\(trace.calls.count) tool\(trace.calls.count == 1 ? "" : "s")") }
        parts.append(Self.duration(trace.seconds))
        let tokens = trace.promptTokens + trace.completionTokens
        if tokens > 0 { parts.append("\(tokens.formatted()) tokens") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.1f s", seconds) : seconds < 120 ? "\(Int(seconds.rounded())) s" : "\(Int(seconds / 60)) min \(Int(seconds) % 60) s"
    }
}

/// Every step of a reply, with arguments, results and timings; a step can be run again.
struct TraceView: View {
    let messageID: UUID
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<UUID> = []

    private var trace: Trace? { store.message(messageID)?.trace }

    var body: some View {
        List {
            if let trace {
                Section {
                    LabeledContent("Model", value: RemoteModel(id: trace.model).displayName)
                    LabeledContent("Time", value: TraceLine.duration(trace.seconds))
                    LabeledContent("Model calls", value: "\(trace.rounds)")
                    if trace.promptTokens + trace.completionTokens > 0 {
                        LabeledContent("Tokens in", value: trace.promptTokens.formatted())
                        LabeledContent("Tokens out", value: trace.completionTokens.formatted())
                    }
                }
                Section(trace.calls.isEmpty ? "No tools used" : "Tools") {
                    ForEach(trace.calls) { call in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                if expanded.contains(call.id) { expanded.remove(call.id) } else { expanded.insert(call.id) }
                            } label: {
                                HStack {
                                    Image(systemName: icon(call.state)).foregroundStyle(color(call.state))
                                    Text(call.tool).scaledFont(.callout, design: .monospaced)
                                    Spacer()
                                    Text(call.state == .running ? "…" : TraceLine.duration(call.seconds))
                                        .scaledFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if expanded.contains(call.id) {
                                Text(call.arguments).scaledFont(.caption, design: .monospaced).textSelection(.enabled)
                                Divider()
                                Text(call.result.isEmpty ? "(no output)" : call.result)
                                    .scaledFont(.caption, design: .monospaced).foregroundStyle(.secondary).textSelection(.enabled)
                                if ChatStore.canRerun(call.tool) {
                                    Button {
                                        store.rerun(call.id, in: messageID)
                                    } label: {
                                        Label("Run again", systemImage: "arrow.clockwise")
                                    }
                                    .disabled(call.state == .running)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("How this reply was made")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private func icon(_ state: AgentStep.State) -> String {
        switch state {
        case .running: "circle.dotted"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .denied: "hand.raised"
        }
    }

    private func color(_ state: AgentStep.State) -> Color {
        switch state {
        case .running: .secondary
        case .done: .green
        case .failed: .orange
        case .denied: .secondary
        }
    }
}
