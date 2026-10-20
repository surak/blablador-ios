import SwiftUI

/// A decision for the Clef decision model (`alias-clef`): a situation and typed questions.
/// The examples come from decision-model-frontend; the user's own are saved with `SavedDecisions`.
struct DecisionExample: Codable, Identifiable, Hashable {
    struct Option: Codable, Hashable {
        var key: String
        var text: String
    }

    struct Question: Codable, Hashable, Identifiable {
        var id: String
        /// "noul" (yes/no), "choice" or "score".
        var type: String
        var instructions: String
        var options: [Option]?
        var levels: [String]?

        var wire: [String: Any] {
            var question: [String: Any] = ["type": type, "instructions": instructions]
            if let options { question["criteria"] = Dictionary(uniqueKeysWithValues: options.map { ($0.key, $0.text) }) }
            if let levels { question["criteria"] = levels }
            return question
        }

        static func new(_ type: String) -> Question {
            Question(
                id: "q" + UUID().uuidString.prefix(8).lowercased(),
                type: type,
                instructions: "",
                options: type == "choice" ? [Option(key: "", text: ""), Option(key: "", text: "")] : nil,
                levels: type == "score" ? ["Low", "Medium", "High"] : nil
            )
        }

        /// Ready to send: an instruction, and at least two options or levels where needed.
        var isComplete: Bool {
            guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            switch type {
            case "choice": return (options ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
            case "score": return (levels ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
            default: return true
            }
        }

        /// Drops empty options and levels and gives choice options short unique keys.
        func cleaned() -> Question {
            var copy = self
            copy.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if let options {
                var used = Set<String>()
                copy.options = options.compactMap { option in
                    let text = option.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    var key = option.key.isEmpty ? Self.key(for: text) : option.key
                    var n = 2
                    let base = key
                    while used.contains(key) { key = "\(base)_\(n)"; n += 1 }
                    used.insert(key)
                    return Option(key: key, text: text)
                }
            }
            if let levels {
                copy.levels = levels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            return copy
        }

        private static func key(for text: String) -> String {
            let words = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .prefix(4)
            return words.isEmpty ? "option" : words.joined(separator: "_")
        }
    }

    var id: String { category + "/" + name }
    var name: String
    var category: String
    var description: String?
    var state: String
    var json: Bool
    var questions: [Question]

    static let myCategory = "My decisions"

    static var blank: DecisionExample {
        DecisionExample(name: "New decision", category: myCategory, description: nil, state: "", json: false, questions: [.new("noul")])
    }

    static var categories: [String] {
        var seen: [String] = []
        for example in all where !seen.contains(example.category) { seen.append(example.category) }
        return seen
    }
}

/// The user's own decisions, kept in UserDefaults.
enum SavedDecisions {
    private static let key = "savedDecisions"

    static func load() -> [DecisionExample] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DecisionExample].self, from: data)) ?? []
    }

    static func save(_ decisions: [DecisionExample]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(decisions), forKey: key)
    }
}

/// One answer from `/v1/systemone`.
struct DecisionAnswer: Decodable {
    let type: String
    /// Probability of yes, for "noul".
    let noul: Double?
    let choice: String?
    /// Probability-weighted level, for "score".
    let score: Double?
    let confidence: Double?
    let probabilities: [String: Double]?
    let legend: [String: String]?
}

extension BlabladorAPI {
    static let decisionModel = "alias-clef"

    /// Asks the decision model typed questions about a state; returns answers by question id.
    func decide(state: String, questions: [DecisionExample.Question]) async throws -> [String: DecisionAnswer] {
        struct Response: Decodable { let answers: [String: DecisionAnswer] }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("systemone"))
        guard !apiKey.isEmpty else { throw BlabladorAPIError.missingAPIKey }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.decisionModel,
            "state": state,
            "questions": Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0.wire) })
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BlabladorAPIError.http(status: http.statusCode, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Response.self, from: data).answers
    }
}

/// Write a situation and typed questions, or start from an example, and see the decision model's answers with probabilities.
struct DecisionView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var decision = DecisionExample.all.first ?? .blank
    @State private var saved = SavedDecisions.load()
    @State private var answers: [String: DecisionAnswer] = [:]
    @State private var running = false
    @State private var error: String?
    @State private var editing: DecisionExample.Question?
    @State private var naming = false
    @State private var name = ""

    private var isSaved: Bool { saved.contains { $0.name == decision.name } && decision.category == DecisionExample.myCategory }

    private var canRun: Bool {
        !running && !decision.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !decision.questions.isEmpty && decision.questions.allSatisfy(\.isComplete)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    picker
                    if let description = decision.description {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Decision")
                } footer: {
                    Text("Start a new decision, open one you saved, or try one of \(DecisionExample.all.count) examples. The decision model answers typed questions with probabilities instead of text — for routing, triage and classification.")
                }

                Section {
                    TextField("Describe the situation: a message, a record, a request…", text: $decision.state, axis: .vertical)
                        .lineLimit(3...12)
                        .font(decision.json ? .system(.callout, design: .monospaced) : .body)
                        .autocorrectionDisabled()
                        .onChange(of: decision.state) { _, _ in answers = [:] }
                } header: {
                    Text(decision.json ? "Situation (JSON)" : "Situation")
                } footer: {
                    Text("Plain text or JSON. Edit it to see how the decisions change.")
                }

                Section {
                    ForEach(decision.questions) { question in
                        Button { editing = question } label: {
                            QuestionRow(question: question, answer: answers[question.id])
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit…") { editing = question }
                            Button("Delete", role: .destructive) { remove(question) }
                        }
                    }
                    .onDelete { offsets in
                        decision.questions.remove(atOffsets: offsets)
                        answers = [:]
                    }
                    Menu {
                        Button { add("noul") } label: { Label("Yes or no", systemImage: "checkmark.circle") }
                        Button { add("choice") } label: { Label("Choice between options", systemImage: "list.bullet") }
                        Button { add("score") } label: { Label("Score on a scale", systemImage: "gauge.medium") }
                    } label: {
                        Label("Add question", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Questions")
                } footer: {
                    Text("Tap a question to edit it. Yes/no gives the probability of yes; choice picks one option; score rates on your levels from lowest to highest.")
                }

                Section {
                    Button {
                        Task { await run() }
                    } label: {
                        HStack {
                            Spacer()
                            if running { ProgressView().controlSize(.small) } else { Text("Decide").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
                }

                Section {
                    Button(isSaved ? "Save changes" : "Save as my decision…") {
                        if isSaved { save(as: decision.name) } else { name = decision.category == DecisionExample.myCategory && decision.name != "New decision" ? decision.name : ""; naming = true }
                    }
                    if isSaved {
                        Button("Delete this decision", role: .destructive) { deleteSaved() }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Decide")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await run() }
                    } label: {
                        if running { ProgressView().controlSize(.small) } else { Text("Decide") }
                    }
                    .disabled(!canRun)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .sheet(item: $editing) { question in
                QuestionEditor(question: question) { updated in
                    if let index = decision.questions.firstIndex(where: { $0.id == updated.id }) {
                        decision.questions[index] = updated
                    } else {
                        decision.questions.append(updated)
                    }
                    answers[updated.id] = nil
                }
            }
            .alert("Save decision", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") { save(as: name) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("It appears under My decisions.")
            }
        }
#if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 360, idealHeight: 640)
#endif
    }

    private var picker: some View {
        Menu {
            Button { select(.blank) } label: { Label("New decision", systemImage: "plus") }
            if !saved.isEmpty {
                Menu(DecisionExample.myCategory) {
                    ForEach(saved) { item in Button(item.name) { select(item) } }
                }
            }
            Divider()
            ForEach(DecisionExample.categories, id: \.self) { category in
                Menu(category) {
                    ForEach(DecisionExample.all.filter { $0.category == category }) { item in
                        Button(item.name) { select(item) }
                    }
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(decision.name).foregroundStyle(.primary)
                    Text(decision.category).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ item: DecisionExample) {
        decision = item
        answers = [:]
        error = nil
    }

    private func add(_ type: String) {
        editing = .new(type)
    }

    private func remove(_ question: DecisionExample.Question) {
        decision.questions.removeAll { $0.id == question.id }
        answers[question.id] = nil
    }

    private func save(as name: String) {
        var copy = decision
        copy.name = name.trimmingCharacters(in: .whitespaces)
        copy.category = DecisionExample.myCategory
        copy.questions = copy.questions.map { $0.cleaned() }
        saved.removeAll { $0.name == copy.name }
        saved.append(copy)
        saved.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        SavedDecisions.save(saved)
        decision = copy
    }

    private func deleteSaved() {
        saved.removeAll { $0.name == decision.name }
        SavedDecisions.save(saved)
        select(.blank)
    }

    private func run() async {
        running = true
        error = nil
        defer { running = false }
        let questions = decision.questions.map { $0.cleaned() }
        decision.questions = questions
        do {
            answers = try await store.api.decide(state: decision.state, questions: questions)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Edits one question: its type, wording, and the options or levels.
private struct QuestionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DecisionExample.Question
    let onSave: (DecisionExample.Question) -> Void

    init(question: DecisionExample.Question, onSave: @escaping (DecisionExample.Question) -> Void) {
        _draft = State(initialValue: question)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: Binding(get: { draft.type }, set: setType)) {
                        Text("Yes or no").tag("noul")
                        Text("Choice").tag("choice")
                        Text("Score").tag("score")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    TextField(placeholder, text: $draft.instructions, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Question")
                }
                if draft.type == "choice" {
                    Section {
                        ForEach(Array((draft.options ?? []).indices), id: \.self) { index in
                            HStack {
                                TextField("Option \(index + 1)", text: Binding(
                                    get: { draft.options?[index].text ?? "" },
                                    set: { draft.options?[index] = .init(key: "", text: $0) }
                                ))
                                removeButton { draft.options?.remove(at: index) }
                            }
                        }
                        Button { draft.options?.append(.init(key: "", text: "")) } label: { Label("Add option", systemImage: "plus.circle") }
                    } header: {
                        Text("Options")
                    } footer: {
                        Text("The model picks one and gives each a probability. Describe each option in a few words.")
                    }
                }
                if draft.type == "score" {
                    Section {
                        ForEach(Array((draft.levels ?? []).indices), id: \.self) { index in
                            HStack {
                                TextField("Level \(index)", text: Binding(
                                    get: { draft.levels?[index] ?? "" },
                                    set: { draft.levels?[index] = $0 }
                                ))
                                removeButton { draft.levels?.remove(at: index) }
                            }
                        }
                        Button { draft.levels?.append("") } label: { Label("Add level", systemImage: "plus.circle") }
                    } header: {
                        Text("Levels, lowest first")
                    } footer: {
                        Text("The answer is a score between the first and the last level.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.instructions.isEmpty ? "New question" : "Edit question")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(draft.cleaned())
                        dismiss()
                    }
                    .disabled(!draft.isComplete)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 320, idealHeight: 460)
#endif
    }

    private var placeholder: String {
        switch draft.type {
        case "choice": "Which option fits best?"
        case "score": "How urgent is this?"
        default: "Is this spam?"
        }
    }

    private func setType(_ type: String) {
        draft.type = type
        draft.options = type == "choice" ? (draft.options ?? [.init(key: "", text: ""), .init(key: "", text: "")]) : nil
        draft.levels = type == "score" ? (draft.levels ?? ["Low", "Medium", "High"]) : nil
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
            .buttonStyle(.borderless)
            .help("Remove")
    }
}

private struct QuestionRow: View {
    let question: DecisionExample.Question
    let answer: DecisionAnswer?

    /// Option labels with their probabilities, in the question's order.
    private var bars: [(label: String, probability: Double, winner: Bool)] {
        guard let answer else { return [] }
        switch question.type {
        case "noul":
            let yes = answer.noul ?? 0
            return [("Yes", yes, yes >= 0.5), ("No", 1 - yes, yes < 0.5)]
        case "choice":
            return (question.options ?? []).map { option in
                (option.key.replacingOccurrences(of: "_", with: " "), answer.probabilities?[option.key] ?? 0, option.key == answer.choice)
            }
        default:
            let best = answer.probabilities?.max { $0.value < $1.value }?.key
            return (question.levels ?? []).enumerated().map { index, level in
                (level, answer.probabilities?[String(index)] ?? 0, String(index) == best)
            }
        }
    }

    private var summary: String? {
        guard let answer else { return nil }
        switch question.type {
        case "noul":
            let yes = answer.noul ?? 0
            return yes >= 0.5 ? "Yes · \(percent(yes))" : "No · \(percent(1 - yes))"
        case "choice":
            return answer.choice.map { "\($0.replacingOccurrences(of: "_", with: " ")) · \(percent(answer.confidence ?? 0))" }
        default:
            guard let score = answer.score, let levels = question.levels, !levels.isEmpty else { return nil }
            let level = levels[min(levels.count - 1, max(0, Int(score.rounded())))]
            return "\(level) · \(String(format: "%.2f", score)) of \(levels.count - 1)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: question.type == "noul" ? "checkmark.circle" : question.type == "choice" ? "list.bullet" : "gauge.medium")
                    .foregroundStyle(Theme.gradient)
                Text(question.instructions).font(.subheadline.weight(.medium))
            }
            if let summary {
                Text(summary).font(.headline).foregroundStyle(Theme.gradient)
                ForEach(bars, id: \.label) { bar in
                    ProbabilityBar(label: bar.label, probability: bar.probability, highlighted: bar.winner)
                }
            } else {
                Text(optionsText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var optionsText: String {
        switch question.type {
        case "noul": "Yes or no"
        case "choice": (question.options ?? []).map { $0.key.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · ")
        default: (question.levels ?? []).joined(separator: " → ")
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

private struct ProbabilityBar: View {
    let label: String
    let probability: Double
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                    Capsule()
                        .fill(highlighted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                        .frame(width: max(4, proxy.size.width * probability))
                }
            }
            .frame(height: 8)
            Text("\(Int((probability * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
