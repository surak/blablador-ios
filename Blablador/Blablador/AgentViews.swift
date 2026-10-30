import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Tool calls of an agent reply; tap one to see its output or diff.
struct AgentStepsView: View {
    let steps: [AgentStep]
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(steps) { step in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if expanded.contains(step.id) { expanded.remove(step.id) } else { expanded.insert(step.id) }
                    } label: {
                        HStack(spacing: 8) {
                            icon(step)
                                .frame(width: 16)
                            Text(step.title)
                                .scaledFont(.caption, design: .monospaced)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(step.state == .denied ? .secondary : .primary)
                            Spacer(minLength: 0)
                            if !step.detail.isEmpty {
                                Image(systemName: expanded.contains(step.id) ? "chevron.down" : "chevron.right")
                                    .scaledFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded.contains(step.id), !step.detail.isEmpty {
                        ScrollView([.horizontal, .vertical]) {
                            Text(highlighted(step.detail))
                                .scaledFont(.caption2, design: .monospaced)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 260)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(10)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func icon(_ step: AgentStep) -> some View {
        switch step.state {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: symbol(step.tool)).foregroundStyle(Theme.gradient)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(.red)
        case .denied: Image(systemName: "hand.raised").foregroundStyle(.secondary)
        }
    }

    private func symbol(_ tool: String) -> String {
        switch tool {
        case "list_files": "folder"
        case "read_file": "doc.text"
        case "search_files": "magnifyingglass"
        case "write_file": "doc.badge.plus"
        case "edit_file": "pencil"
        case "mcp": "puzzlepiece.extension"
        case "python": "chart.xyaxis.line"
        default: "terminal"
        }
    }

    /// Colors diff lines.
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            var part = AttributedString((index > 0 ? "\n" : "") + line)
            if line.hasPrefix("+ ") { part.foregroundColor = .green }
            if line.hasPrefix("- ") { part.foregroundColor = .red }
            result += part
        }
        return result
    }
}

/// Composer chip for the agent's folder.
struct WorkspaceChip: View {
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        if let folder = store.workspace {
            Menu {
                Toggle("Run commands without asking", isOn: Binding(
                    get: { store.allowsCommands },
                    set: { store.allowsCommands = $0 }
                ))
                .disabled(store.currentID == nil)
#if os(macOS)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                Button("Change folder…") { if let url = chooseWorkspace() { store.workspace = url } }
#endif
                Divider()
                Button("Stop working in this folder", role: .destructive) { store.workspace = nil }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                    Text("Agent · \(folder.lastPathComponent)")
                    Image(systemName: "chevron.down").imageScale(.small)
                }
                .scaledFont(.caption, weight: .medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.gradient, in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help(folder.path)
            .padding(.leading, 8)
            .padding(.top, 4)
        }
    }
}

/// Asks before the agent runs a shell command.
struct CommandApprovalCard: View {
    let approval: ChatStore.CommandApproval
    let onAnswer: (ChatStore.ApprovalChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.title, systemImage: approval.icon)
                .scaledFont(.subheadline, weight: .semibold)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(approval.detail)
                    .scaledFont(.callout, design: .monospaced)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Deny", role: .cancel) { onAnswer(.deny) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow for this chat") { onAnswer(.always) }
                Button(approval.confirm) { onAnswer(.once) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.gradient, lineWidth: 1.5))
        .padding(.horizontal)
        .frame(maxWidth: 800)
    }
}

#if os(macOS)
/// Folder picker for agent mode.
@MainActor
func chooseWorkspace() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Work Here"
    panel.message = "Choose the folder the agent may read, edit and run commands in."
    return panel.runModal() == .OK ? panel.url : nil
}
#endif
