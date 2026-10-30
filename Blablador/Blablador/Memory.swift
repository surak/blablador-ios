import SwiftUI

/// Something the assistant remembers about the user across chats.
struct Memory: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var date = Date()
}

/// Long-term memory: facts saved on the device with the remember tool and sent with every chat.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()
    /// Most memories kept; the oldest are dropped first.
    static let maxMemories = 100

    @Published private(set) var memories: [Memory] = []

    @AppStorage("memoryEnabled") var enabled = true {
        willSet { objectWillChange.send() }
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let memories = try? JSONDecoder().decode([Memory].self, from: data) {
            self.memories = memories
        }
    }

    /// Saves a fact; returns false for an empty text or one already remembered.
    @discardableResult
    func add(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !memories.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { return false }
        memories.append(Memory(text: text))
        if memories.count > Self.maxMemories { memories.removeFirst(memories.count - Self.maxMemories) }
        persist()
        return true
    }

    func update(_ memory: Memory, text: String) {
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        memories[index].text = text
        persist()
    }

    func delete(_ ids: Set<UUID>) {
        memories.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Deletes memory number `number` as listed in the system prompt (1-based).
    func forget(number: Int) -> Memory? {
        guard memories.indices.contains(number - 1) else { return nil }
        let memory = memories.remove(at: number - 1)
        persist()
        return memory
    }

    func deleteAll() {
        memories = []
        persist()
    }

    /// Added to the system prompt when memory is on.
    var systemPrompt: String {
        var prompt = "You have a long-term memory of the user that lasts across chats. Call remember when the user shares something lasting about themselves (name, job, preferences, ongoing projects) or asks you to remember something; save one short fact per call, written in the third person. Call forget with a number when the user says a memory is wrong or asks you to forget it. Never save passwords, keys or other secrets."
        if memories.isEmpty {
            prompt += " You don't remember anything yet."
        } else {
            prompt += " What you remember:\n" + memories.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        }
        return prompt
    }

    private func persist() {
        try? JSONEncoder().encode(memories).write(to: Self.fileURL, options: .atomic)
    }

    private static var fileURL: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent("memories.json")
    }
}

enum MemoryTools {
    static let remember: [String: Any] = [
        "type": "function",
        "function": [
            "name": "remember",
            "description": "Save a lasting fact about the user to long-term memory, available in future chats.",
            "parameters": [
                "type": "object",
                "properties": [
                    "fact": ["type": "string", "description": "One short fact in the third person, e.g. \"Works as a chemist in Jülich.\""]
                ],
                "required": ["fact"]
            ]
        ]
    ]

    static let forget: [String: Any] = [
        "type": "function",
        "function": [
            "name": "forget",
            "description": "Delete a memory that is wrong or that the user wants forgotten.",
            "parameters": [
                "type": "object",
                "properties": [
                    "number": ["type": "integer", "description": "The memory's number in the list of what you remember."]
                ],
                "required": ["number"]
            ]
        ]
    ]
}

/// Settings screen listing what the assistant remembers.
struct MemoryView: View {
    @ObservedObject private var memory = MemoryStore.shared
    @State private var newFact = ""
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                Toggle("Remember things about me", isOn: $memory.enabled)
            } footer: {
                Text("The assistant saves facts you tell it, such as your name or what you work on, and uses them in every chat. Memories stay on this device and are sent to the model with each message.")
            }

            Section("Memories") {
                if memory.memories.isEmpty {
                    Text("Nothing remembered yet.").foregroundStyle(.secondary)
                }
                ForEach(memory.memories) { item in
                    MemoryRow(memory: item)
                }
                .onDelete { offsets in
                    memory.delete(Set(offsets.map { memory.memories[$0].id }))
                }
                HStack {
                    TextField("Add a memory", text: $newFact)
                        .onSubmit(addFact)
                    Button("Add", action: addFact)
                        .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !memory.memories.isEmpty {
                Section {
                    Button("Forget everything", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Memory")
        .confirmationDialog("Forget all memories?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Forget everything", role: .destructive) { memory.deleteAll() }
        }
    }

    private func addFact() {
        if memory.add(newFact) { newFact = "" }
    }
}

private struct MemoryRow: View {
    let memory: Memory
    @State private var text = ""

    var body: some View {
        HStack {
            TextField("Memory", text: $text, axis: .vertical)
                .onSubmit { save() }
                .onChange(of: text) { save() }
#if os(macOS)
            Button {
                MemoryStore.shared.delete([memory.id])
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget")
#endif
        }
        .onAppear { text = memory.text }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != memory.text { MemoryStore.shared.update(memory, text: trimmed) }
    }
}
