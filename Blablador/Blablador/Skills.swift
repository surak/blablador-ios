import SwiftUI
import UniformTypeIdentifiers

/// Instructions for one kind of task, written once and loaded by the model when the task comes up.
struct Skill: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// When to use it; this line is what the model sees in every chat.
    var description: String
    var instructions: String
    var date = Date()

    /// The skill as Markdown with a front matter, for sharing and importing.
    var markdown: String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\n\(instructions)\n"
    }

    /// Reads a skill file: a front matter with name and description, then the instructions.
    /// Without a front matter the file name is the name and the first line the description.
    init?(markdown: String, fileName: String) {
        var name = (fileName as NSString).deletingPathExtension
        var description = ""
        var body = markdown
        if markdown.hasPrefix("---"), let end = markdown.range(of: "\n---", range: markdown.index(markdown.startIndex, offsetBy: 3)..<markdown.endIndex) {
            for line in markdown[markdown.index(markdown.startIndex, offsetBy: 3)..<end.lowerBound].split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "name" { name = parts[1] }
                if parts[0] == "description" { description = parts[1] }
            }
            body = String(markdown[end.upperBound...])
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty { description = body.split(separator: "\n").first.map(String.init) ?? "" }
        guard !name.isEmpty, !body.isEmpty else { return nil }
        self.init(name: name, description: description, instructions: body)
    }

    init(name: String, description: String, instructions: String) {
        self.name = name
        self.description = description
        self.instructions = instructions
    }
}

/// The user's skills, saved encrypted on the device.
@MainActor
final class SkillLibrary: ObservableObject {
    static let shared = SkillLibrary()

    @Published private(set) var skills: [Skill] = []

    /// After a task of several steps, draft a skill from it for the user to save (Settings → Skills).
    @AppStorage("skillsDraftAutomatically") var draftsAutomatically = true {
        willSet { objectWillChange.send() }
    }

    private init() {
        if let data = EncryptedStorage.read(Self.fileURL),
           let skills = try? JSONDecoder().decode([Skill].self, from: data) {
            self.skills = skills
        }
    }

    func skill(named name: String) -> Skill? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return skills.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Adds a skill, or replaces the one with the same id or name.
    func save(_ skill: Skill) {
        if let index = skills.firstIndex(where: { $0.id == skill.id || $0.name.caseInsensitiveCompare(skill.name) == .orderedSame }) {
            var updated = skill
            updated.id = skills[index].id
            skills[index] = updated
        } else {
            skills.append(skill)
        }
        skills.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func delete(_ ids: Set<UUID>) {
        skills.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Added to the system prompt when there are skills.
    var systemPrompt: String? {
        guard !skills.isEmpty else { return nil }
        return "The user has saved skills: instructions for particular tasks. Before doing a task that matches one, call use_skill with its name and follow the instructions it returns.\n"
            + skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        EncryptedStorage.write(data, to: Self.fileURL)
    }

    private static var fileURL: URL { AppFolder.url.appendingPathComponent("skills.json") }
}

enum SkillTools {
    static let use: [String: Any] = [
        "type": "function",
        "function": [
            "name": "use_skill",
            "description": "Load the full instructions of one of the user's saved skills.",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The skill's name as listed."]
                ],
                "required": ["name"]
            ]
        ]
    ]

    static let suggest: [String: Any] = [
        "type": "function",
        "function": [
            "name": "suggest_skill",
            "description": "Offer to save a reusable procedure as a skill, when the user asks for it or after finishing a task they will likely repeat the same way. The user decides whether to save it.",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Short name, e.g. \"Meeting notes\"."],
                    "description": ["type": "string", "description": "One line saying when to use it."],
                    "instructions": ["type": "string", "description": "Step-by-step instructions in Markdown, written so they work without this chat."]
                ],
                "required": ["name", "description", "instructions"]
            ]
        ]
    ]

    static let systemPrompt = "When the user asks you to remember how to do a task, or after a task they will likely repeat, you can call suggest_skill; the user then decides whether to save it."
}

// MARK: - Views

/// A skill the model offered to save, shown under its reply.
struct SuggestedSkillCard: View {
    let skill: Skill
    @ObservedObject private var library = SkillLibrary.shared
    @State private var editing = false

    var body: some View {
        let saved = library.skill(named: skill.name) != nil
        VStack(alignment: .leading, spacing: 6) {
            Label("Suggested skill: \(skill.name)", systemImage: "wand.and.stars")
                .scaledFont(.subheadline, weight: .semibold)
            Text(skill.description)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(saved ? "Saved" : "Save skill") { library.save(skill) }
                    .disabled(saved)
                Button("Review…") { editing = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $editing) {
            NavigationStack { SkillEditor(skill: library.skill(named: skill.name) ?? skill) }
        }
    }
}

/// Settings screen: the skill library.
struct SkillsView: View {
    @ObservedObject private var library = SkillLibrary.shared
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                if library.skills.isEmpty {
                    Text("No skills yet.").foregroundStyle(.secondary)
                }
                ForEach(library.skills) { skill in
                    NavigationLink {
                        SkillEditor(skill: skill)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                            Text(skill.description)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .onDelete { offsets in
                    library.delete(Set(offsets.map { library.skills[$0].id }))
                }
                NavigationLink("New skill") {
                    SkillEditor(skill: Skill(name: "", description: "", instructions: ""))
                }
                Button("Import…") { importing = true }
            } footer: {
                Text("A skill is a set of instructions for one kind of task, such as how you like meeting notes or press releases. The assistant sees each skill's name and description and loads the instructions when a task matches. Skills are Markdown files with a name and description at the top, so you can share and import them. The assistant can also suggest new skills for you to save.")
            }
            if let importError {
                Text(importError).foregroundStyle(.red)
            }
            Section {
                Toggle("Suggest skills after tasks", isOn: Binding(get: { library.draftsAutomatically }, set: { library.draftsAutomatically = $0 }))
            } footer: {
                Text("After the assistant finishes a task of several steps, it drafts a skill from what it did. Save it with one tap and the next similar task goes the same way.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Skills")
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText, .plainText],
                      allowsMultipleSelection: true) { result in
            importError = nil
            guard case let .success(urls) = result else { return }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8), let skill = Skill(markdown: text, fileName: url.lastPathComponent) {
                    library.save(skill)
                } else {
                    importError = "\(url.lastPathComponent) isn't a skill file."
                }
            }
        }
    }
}

struct SkillEditor: View {
    @State var skill: Skill
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    private let isNew: Bool

    init(skill: Skill) {
        _skill = State(initialValue: skill)
        isNew = SkillLibrary.shared.skills.first { $0.id == skill.id } == nil
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Meeting notes", text: $skill.name)
            }
            Section {
                TextField("e.g. When I paste a meeting transcript", text: $skill.description, axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text("When to use it")
            }
            Section("Instructions") {
                TextEditor(text: $skill.instructions)
                    .font(.body.monospaced())
                    .frame(minHeight: 220)
            }
            if !isNew {
                Section {
                    ShareLink(item: skill.markdown, preview: SharePreview(skill.name)) {
                        Label("Share as Markdown", systemImage: "square.and.arrow.up")
                    }
                    Button("Delete skill", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New skill" : skill.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    skill.name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    skill.description = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    SkillLibrary.shared.save(skill)
                    dismiss()
                }
                .disabled(skill.name.trimmingCharacters(in: .whitespaces).isEmpty || skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .confirmationDialog("Delete \(skill.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                SkillLibrary.shared.delete([skill.id])
                dismiss()
            }
        }
    }
}
