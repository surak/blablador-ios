import SwiftUI

/// A goal set with /goal: Blablador keeps working on it until it's reached or it needs the user.
struct Goal: Codable, Hashable {
    enum Status: String, Codable { case active, done, blocked }
    var text: String
    var status: Status = .active
    /// What was done, or what the user needs to answer.
    var summary: String?
    var started = Date()
}

enum GoalTools {
    /// Tool rounds for one reply that works on a goal.
    static let maxRounds = 60
    /// How often a reply that stops without settling the goal is told to keep going.
    static let maxNudges = 3

    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "goal_status",
            "description": "Report the chat's goal as reached (done) or say you can't go on without the user (blocked).",
            "parameters": [
                "type": "object",
                "properties": [
                    "status": ["type": "string", "enum": ["done", "blocked"]],
                    "summary": ["type": "string", "description": "done: what was achieved, in one or two sentences. blocked: the question or decision the user has to answer."]
                ],
                "required": ["status", "summary"]
            ]
        ]
    ]

    static func systemPrompt(_ goal: Goal) -> String {
        "The user set a goal for this chat: \"\(goal.text)\". Work towards it on your own, step by step, with update_plan and any tools you need, without stopping to ask unless you can't go on. When the goal is fully reached, call goal_status with done; if you need the user's decision or information you can't find, call goal_status with blocked and your question."
    }

    static let nudge = "The goal isn't reached yet. Keep working on it now, without asking. If it is reached, call goal_status with done; if you can't go on without the user, call goal_status with blocked."

    /// The goal in "/goal <text>"; "" for a bare /goal; nil when the text isn't the command.
    static func command(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased() == "/goal" || trimmed.lowercased().hasPrefix("/goal ") || trimmed.lowercased().hasPrefix("/goal\n") else { return nil }
        return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let mention = Mention(kind: .tool, value: "goal", name: "Goal", icon: "flag")
}

/// A second look before a task's answer goes to the user.
enum SelfCheck {
    enum Result: String, Codable { case passed, corrected }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "selfCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "selfCheck") }
    }

    static let prompt = """
    Before this goes to the user, check your work against their request: is every part done, are numbers, names, dates and files right, did each tool really succeed, is anything claimed that a tool didn't confirm? \
    If the answer is complete and correct, reply with exactly CHECKED and nothing else. \
    Otherwise fix what's wrong (use tools if you need to) and then write the complete corrected answer, which replaces the previous one; don't mention this check.
    """

    /// Replies worth checking: a plan, a goal or at least two real tool calls.
    static func worthChecking(_ trace: Trace?, hasPlan: Bool, goal: Bool) -> Bool {
        let calls = trace?.calls.filter { !["update_plan", "goal_status", "remember", "forget"].contains($0.tool) }.count ?? 0
        return hasPlan || goal || calls >= 2
    }

    static func passed(_ answer: String) -> Bool {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
        return text.isEmpty || (text.hasPrefix("CHECKED") && text.count < 40)
    }
}

/// The open chat's goal above the composer: what it is, how it's going, and Continue or End.
struct GoalBanner: View {
    @EnvironmentObject private var store: ChatStore
    let goal: Goal

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .scaledFont(.body)
                .foregroundStyle(Theme.gradient)
                .symbolEffect(.pulse, isActive: store.isStreaming)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                Text(goal.text).scaledFont(.subheadline).lineLimit(2)
                if let summary = goal.summary, goal.status != .active {
                    Text(summary).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 4)
            if goal.status != .done, !store.isStreaming {
                Button("Continue") { store.continueGoal() }
                    .buttonStyle(.borderless)
                    .scaledFont(.caption, weight: .semibold)
            }
            Button { store.endGoal() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(goal.status == .done ? "Dismiss goal" : "End goal")
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var icon: String {
        switch goal.status {
        case .active: "flag"
        case .done: "flag.checkered"
        case .blocked: "questionmark.circle"
        }
    }

    private var statusText: String {
        switch goal.status {
        case .active: store.isStreaming ? "Working on the goal…" : "Goal · paused"
        case .done: "Goal reached"
        case .blocked: "Goal · needs you"
        }
    }
}

/// Commands offered while "/" is typed at the start of the draft.
struct SlashSuggestions: View {
    let query: String
    let onPick: (String) -> Void

    static let commands: [(name: String, icon: String, text: String)] = [
        ("goal", "flag", "Keep working until it's done")
    ]

    var body: some View {
        let matches = Self.commands.filter { query.isEmpty || $0.name.hasPrefix(query.lowercased()) }
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(matches, id: \.name) { command in
                    Button { onPick(command.name) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: command.icon).foregroundStyle(Theme.gradient).frame(width: 20)
                            Text("/" + command.name).bold()
                            Text(command.text).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                        }
                        .scaledFont(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
