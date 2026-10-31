import SwiftUI

/// What the assistant may do without asking: one rule per kind of tool, set in Settings → Permissions or with
/// "Always allow" on an approval card. "Never" also hides the tools from the model.
@MainActor
final class ToolPermissions: ObservableObject {
    static let shared = ToolPermissions()

    enum Rule: String, Codable, CaseIterable, Identifiable {
        case allow, ask, never
        var id: String { rawValue }
        var label: String {
            switch self {
            case .allow: "Allow"
            case .ask: "Ask"
            case .never: "Never"
            }
        }
    }

    /// A kind of tool with its own rule.
    struct Kind: Identifiable {
        let id: String
        let name: String
        let icon: String
        let detail: String
        let defaultRule: Rule
    }

    static let kinds: [Kind] = [
        Kind(id: "web", name: "Web search and pages", icon: "globe", detail: "Search the web, find pictures, read pages", defaultRule: .allow),
        Kind(id: "python", name: "Run Python", icon: "chevron.left.forwardslash.chevron.right", detail: "Code runs in a sandbox on this device", defaultRule: .allow),
        Kind(id: "memory", name: "Change memory", icon: "brain", detail: "Remember and forget facts", defaultRule: .allow),
        Kind(id: "chats", name: "Search earlier chats", icon: "text.magnifyingglass", detail: "Look up what was said before", defaultRule: .allow),
        Kind(id: "calendar", name: "Read calendar and reminders", icon: "calendar", detail: "Events and reminders on this device", defaultRule: .allow),
        Kind(id: "calendarWrite", name: "Add events and reminders", icon: "calendar.badge.plus", detail: "Create new events and reminders", defaultRule: .ask),
        Kind(id: "contacts", name: "Look up contacts", icon: "person.crop.circle", detail: "Names, phone numbers, emails", defaultRule: .allow),
        Kind(id: "location", name: "Current location", icon: "location", detail: "Where this device is, roughly", defaultRule: .ask),
        Kind(id: "schedule", name: "Schedule tasks", icon: ToolIcon.schedule, detail: "Create tasks that run at set times", defaultRule: .ask),
        Kind(id: "files", name: "Edit files (agent)", icon: "doc.badge.gearshape", detail: "Write and edit files in the agent's folder", defaultRule: .allow),
        Kind(id: "command", name: "Run commands (agent)", icon: "terminal", detail: "Shell commands in the agent's folder", defaultRule: .ask)
    ]

    @Published private var rules: [String: Rule]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: "toolPermissions") as? [String: String] ?? [:]
        rules = stored.compactMapValues(Rule.init(rawValue:))
    }

    /// The rule for a kind of tool, or for a connected server ("mcp:<id>"), whose default comes from its setting.
    func rule(_ id: String) -> Rule {
        if let rule = rules[id] { return rule }
        if id.hasPrefix("mcp:"), let server = MCPLibrary.shared.servers.first(where: { "mcp:\($0.id)" == id }) {
            return server.askBeforeCalls ? .ask : .allow
        }
        return Self.kinds.first { $0.id == id }?.defaultRule ?? .ask
    }

    func set(_ id: String, _ rule: Rule) {
        // A server's Allow or Ask is its own "Ask before each tool call" switch; only Never is kept here.
        rules[id] = id.hasPrefix("mcp:") && rule != .never ? nil : rule
        UserDefaults.standard.set(rules.mapValues(\.rawValue), forKey: "toolPermissions")
        if id.hasPrefix("mcp:"), rule != .never, var server = MCPLibrary.shared.servers.first(where: { "mcp:\($0.id)" == id }),
           server.askBeforeCalls != (rule != .allow) {
            server.askBeforeCalls = rule != .allow
            MCPLibrary.shared.save(server)
        }
    }

    func binding(_ id: String) -> Binding<Rule> {
        Binding(get: { self.rule(id) }, set: { self.set(id, $0) })
    }

    func resetAll() {
        rules = [:]
        UserDefaults.standard.removeObject(forKey: "toolPermissions")
    }

    /// The kind a tool belongs to.
    static func kind(of tool: String) -> String? {
        switch tool {
        case "web_search", "image_search", "read_page": "web"
        case "run_python": "python"
        case "remember", "forget": "memory"
        case "search_chats": "chats"
        case "calendar_events", "list_reminders": "calendar"
        case "create_event", "create_reminder": "calendarWrite"
        case "find_contacts": "contacts"
        case "current_location": "location"
        case "schedule_task": "schedule"
        case "write_file", "edit_file": "files"
        case "run_command": "command"
        default: nil
        }
    }

    /// Removes tools whose rule is Never.
    func filter(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.filter { tool in
            guard let name = (tool["function"] as? [String: Any])?["name"] as? String, let kind = Self.kind(of: name) else { return true }
            return rule(kind) != .never
        }
    }
}

struct PermissionsView: View {
    @ObservedObject private var permissions = ToolPermissions.shared
    @ObservedObject private var mcp = MCPLibrary.shared

    var body: some View {
        Form {
            Section {
                ForEach(ToolPermissions.kinds) { kind in
                    row(id: kind.id, name: kind.name, icon: kind.icon, detail: kind.detail)
                }
            } footer: {
                Text("Ask shows a card before each use, with Allow once, Allow for this chat and Always allow. Never hides the tool from the assistant. The system may still ask for access to your calendar, contacts or location the first time.")
            }
            if !mcp.servers.isEmpty {
                Section("Connected tools") {
                    ForEach(mcp.servers) { server in
                        row(id: "mcp:\(server.id)", name: server.name, icon: "puzzlepiece.extension", detail: server.url)
                    }
                }
            }
            Section {
                Button("Reset to defaults", role: .destructive) { permissions.resetAll() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
    }

    private func row(id: String, name: String, icon: String, detail: String) -> some View {
        Picker(selection: permissions.binding(id)) {
            ForEach(ToolPermissions.Rule.allCases) { Text($0.label).tag($0) }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(detail).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: {
                ToolIcon(name: icon)
            }
        }
    }
}
