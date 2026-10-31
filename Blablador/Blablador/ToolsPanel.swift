import SwiftUI

/// Everything that can be mentioned with @ in the composer: tools, skills, knowledge bases and connected services.
@MainActor
enum MentionCatalog {
    static let tools: [Mention] = [
        Mention(kind: .tool, value: "web", name: "Web search", icon: "globe"),
        Mention(kind: .tool, value: "python", name: "Python", icon: "chevron.left.forwardslash.chevron.right"),
        Mention(kind: .tool, value: "device", name: "Calendar & contacts", icon: "calendar"),
        Mention(kind: .tool, value: "chats", name: "Earlier chats", icon: "text.magnifyingglass"),
        Mention(kind: .tool, value: "memory", name: "Memory", icon: "brain"),
        Mention(kind: .tool, value: "image", name: "Image", icon: "paintbrush.pointed"),
        Mention(kind: .tool, value: "schedule", name: "Schedule", icon: ToolIcon.schedule),
        Mention(kind: .tool, value: "plan", name: "Plan", icon: "checklist")
    ]

    static func all() -> [Mention] {
        tools
            + SkillLibrary.shared.skills.map { Mention(kind: .skill, value: $0.name, name: $0.name, icon: "wand.and.stars") }
            + KnowledgeLibrary.shared.bases.map { Mention(kind: .knowledge, value: $0.id.uuidString, name: $0.name, icon: "books.vertical") }
            + MCPLibrary.shared.servers.filter(\.enabled).map { Mention(kind: .server, value: $0.id.uuidString, name: $0.name, icon: "puzzlepiece.extension") }
    }

    static func matches(_ query: String) -> [Mention] {
        let query = query.lowercased()
        let all = all()
        guard !query.isEmpty else { return all }
        let starts = all.filter { $0.name.lowercased().hasPrefix(query) }
        return starts + all.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
    }

    static func kindName(_ kind: Mention.Kind) -> String {
        switch kind {
        case .tool: "Tool"
        case .skill: "Skill"
        case .knowledge: "Knowledge"
        case .server: "Connected"
        }
    }
}

/// Suggestions for an "@name" being typed.
struct MentionSuggestions: View {
    let query: String
    let onPick: (Mention) -> Void

    var body: some View {
        let matches = MentionCatalog.matches(query)
        VStack(alignment: .leading, spacing: 2) {
            if matches.isEmpty {
                Text("Nothing called “\(query)”. Type @ for tools, skills, knowledge bases and connected services.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches.prefix(30)) { mention in
                        Button { onPick(mention) } label: {
                            HStack(spacing: 8) {
                                ToolIcon(name: mention.icon, size: 18)
                                    .foregroundStyle(Theme.gradient)
                                    .frame(width: 20)
                                Text(mention.name).lineLimit(1)
                                Spacer()
                                Text(MentionCatalog.kindName(mention.kind))
                                    .scaledFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(4)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

/// Mentions as chips: removable in the composer, plain on a sent message.
struct MentionChips: View {
    let mentions: [Mention]
    var onRemove: ((Mention) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(mentions) { mention in
                    HStack(spacing: 4) {
                        ToolIcon(name: mention.icon, size: 14)
                        Text("@" + mention.name).lineLimit(1)
                        if let onRemove {
                            Button { onRemove(mention) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(mention.name)")
                        }
                    }
                    .scaledFont(.caption, weight: .medium)
                    .foregroundStyle(onRemove == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(onRemove == nil ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(Theme.gradient), in: Capsule())
                }
            }
            .padding(.horizontal, onRemove == nil ? 0 : 8)
            .padding(.top, onRemove == nil ? 0 : 4)
        }
        .fixedSize(horizontal: onRemove == nil, vertical: false)
    }
}

/// What the + button opens: attach, the kind of reply, tools, knowledge, connected services and more, each with
/// its state visible instead of hidden in a menu.
struct ToolsPanel: View {
    enum Action { case camera, photos, files, paste, scanText, decide, workspace, newKnowledge }

    @Binding var imageMode: Bool
    @Binding var videoMode: Bool
    @Binding var speechMode: Bool
    let onAction: (Action) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ToolsPanelContent(imageMode: $imageMode, videoMode: $videoMode, speechMode: $speechMode, onAction: onAction)
                    .padding()
            }
            .background(Theme.background)
            .navigationTitle("Add and tools")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// The sections of the panel (separate so they can be rendered in tests).
struct ToolsPanelContent: View {
    typealias Action = ToolsPanel.Action

    @Binding var imageMode: Bool
    @Binding var videoMode: Bool
    @Binding var speechMode: Bool
    let onAction: (Action) -> Void

    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var knowledge = KnowledgeLibrary.shared
    @ObservedObject private var mcp = MCPLibrary.shared
    @ObservedObject private var memory = MemoryStore.shared
    @ObservedObject private var skills = SkillLibrary.shared
    @ObservedObject private var scheduler = TaskScheduler.shared
    @AppStorage("deviceToolsEnabled") private var deviceTools = false

    var body: some View {
                VStack(alignment: .leading, spacing: 22) {
                    section("Add") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 10)], spacing: 10) {
                            if CameraPicker.isAvailable { tile("Camera", "camera") { onAction(.camera) } }
                            tile("Photos", "photo.on.rectangle") { onAction(.photos) }
                            tile("Files", "doc") { onAction(.files) }
                            tile("Paste", "doc.on.clipboard") { onAction(.paste) }
                            tile("Scan text", "text.viewfinder") { onAction(.scanText) }
                        }
                    }

                    section("Reply with") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 10)], spacing: 10) {
                            mode("Text", "text.bubble", selected: !imageMode && !videoMode && !speechMode) {
                                imageMode = false; videoMode = false; speechMode = false
                            }
                            mode("Image", "paintbrush.pointed", selected: imageMode) { imageMode = true }
                            mode("Video", "film", selected: videoMode) { videoMode = true }
                            mode("Speech", "waveform", selected: speechMode) { speechMode = true }
                        }
                    }

                    section("Tools") {
                        VStack(spacing: 0) {
                            toggle("Web search", "globe", "Search and read pages when needed", isOn: Binding(get: { store.webSearchEnabled }, set: { store.webSearchEnabled = $0 }))
                            Divider().padding(.leading, 44)
                            toggle("Run Python", "chevron.left.forwardslash.chevron.right", "Calculations, data and plots on this device", isOn: Binding(get: { store.pythonEnabled }, set: { store.pythonEnabled = $0 }))
                            Divider().padding(.leading, 44)
                            toggle("Calendar & contacts", "calendar", "Events, reminders, contacts, location", isOn: $deviceTools)
                            Divider().padding(.leading, 44)
                            toggle("Create images", "paintbrush.pointed", "The assistant may make and edit images", isOn: Binding(get: { store.imageToolsEnabled }, set: { store.imageToolsEnabled = $0 }))
                            Divider().padding(.leading, 44)
                            toggle("Memory", "brain", "\(memory.memories.count) memories", isOn: Binding(get: { memory.enabled }, set: { memory.enabled = $0 }))
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }

                    section("Knowledge") {
                        VStack(spacing: 0) {
                            ForEach(knowledge.bases) { base in
                                let on = store.activeKnowledge.contains(base.id)
                                Button { store.toggleKnowledge(base.id) } label: {
                                    row(base.name, "books.vertical", base.documents.count == 1 ? "1 document" : "\(base.documents.count) documents") {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.secondary))
                                    }
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 44)
                            }
                            NavigationLink { KnowledgeListView() } label: {
                                row(knowledge.bases.isEmpty ? "Create a knowledge base" : "Manage knowledge bases", "plus.rectangle.on.folder", "Answer from your PDFs and notes") {
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }

                    section("Connected tools") {
                        VStack(spacing: 0) {
                            ForEach(mcp.servers) { server in
                                toggle(server.name, "puzzlepiece.extension", mcp.tools[server.id].map { "\($0.count) tools" } ?? server.url,
                                       isOn: Binding(get: { server.enabled }, set: { on in
                                           var changed = server
                                           changed.enabled = on
                                           mcp.save(changed)
                                       }))
                                Divider().padding(.leading, 44)
                            }
                            link(mcp.servers.isEmpty ? "Connect a service (MCP)" : "Manage connected tools", "link", "GitLab, calendars, your own servers…") { MCPServersView() }
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }

                    section("More") {
                        VStack(spacing: 0) {
                            link("Skills", "wand.and.stars", skills.skills.isEmpty ? "Instructions for tasks you repeat" : "\(skills.skills.count) skills · use one with @") { SkillsView() }
                            Divider().padding(.leading, 44)
                            link("Scheduled tasks", ToolIcon.schedule, scheduler.tasks.isEmpty ? "Run prompts at set times" : "\(scheduler.tasks.filter(\.enabled).count) active") { TasksView() }
                            Divider().padding(.leading, 44)
                            link("Permissions", "hand.raised", "What the assistant may do without asking") { PermissionsView() }
                            Divider().padding(.leading, 44)
#if os(macOS)
                            Button { onAction(.workspace) } label: {
                                row("Work in a folder…", "terminal", store.workspace?.lastPathComponent ?? "Let the agent read, edit and run code") {
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 44)
#endif
                            Button { onAction(.decide) } label: {
                                row("Decide…", "arrow.triangle.branch", "Weigh options with the Clef decision model") {
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }

                    Label("Type @ in a message to use a tool, skill, knowledge base or connected service just for that message.", systemImage: "at")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).scaledFont(.subheadline, weight: .semibold).foregroundStyle(.secondary)
            content()
        }
    }

    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).scaledFont(.title3)
                Text(title).scaledFont(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mode(_ title: String, _ icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).scaledFont(.title3)
                Text(title).scaledFont(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(selected ? .white : .primary)
            .background(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.surface), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row<Trailing: View>(_ title: String, _ icon: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            ToolIcon(name: icon)
                .foregroundStyle(Theme.gradient)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                Text(detail).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func toggle(_ title: String, _ icon: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        row(title, icon, detail) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private func link<Destination: View>(_ title: String, _ icon: String, _ detail: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            row(title, icon, detail) {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
