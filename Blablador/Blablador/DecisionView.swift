import SwiftUI

/// A ready-made decision for the Clef decision model (`alias-clef`), from decision-model-frontend.
struct DecisionExample: Decodable, Identifiable, Hashable {
    struct Option: Decodable, Hashable {
        let key: String
        let text: String
    }

    struct Question: Decodable, Hashable {
        let id: String
        /// "noul" (yes/no), "choice" or "score".
        let type: String
        let instructions: String
        let options: [Option]?
        let levels: [String]?

        var wire: [String: Any] {
            var question: [String: Any] = ["type": type, "instructions": instructions]
            if let options { question["criteria"] = Dictionary(uniqueKeysWithValues: options.map { ($0.key, $0.text) }) }
            if let levels { question["criteria"] = levels }
            return question
        }
    }

    var id: String { name }
    let name: String
    let category: String
    let description: String?
    let state: String
    let json: Bool
    let questions: [Question]

    static var categories: [String] {
        var seen: [String] = []
        for example in all where !seen.contains(example.category) { seen.append(example.category) }
        return seen
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

/// Pick an example, edit the situation, and see the decision model's answers with probabilities.
struct DecisionView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var example = DecisionExample.all.first
    @State private var state = DecisionExample.all.first?.state ?? ""
    @State private var answers: [String: DecisionAnswer] = [:]
    @State private var running = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Menu {
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
                                Text(example?.name ?? "Choose an example").foregroundStyle(.primary)
                                if let example {
                                    Text(example.category).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if let description = example?.description {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Example")
                } footer: {
                    Text("\(DecisionExample.all.count) examples in \(DecisionExample.categories.count) categories. The decision model answers typed questions with probabilities instead of text — for routing, triage and classification.")
                }

                Section {
                    TextField("Describe the situation", text: $state, axis: .vertical)
                        .lineLimit(3...12)
                        .font(example?.json == true ? .system(.callout, design: .monospaced) : .body)
                        .autocorrectionDisabled()
                } header: {
                    Text(example?.json == true ? "Situation (JSON)" : "Situation")
                } footer: {
                    Text("Edit it to see how the decisions change.")
                }

                if let example {
                    Section("Questions") {
                        ForEach(example.questions, id: \.id) { question in
                            QuestionRow(question: question, answer: answers[question.id])
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
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
                    .disabled(running || example == nil || state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
#endif
    }

    private func select(_ item: DecisionExample) {
        example = item
        state = item.state
        answers = [:]
        error = nil
    }

    private func run() async {
        guard let example else { return }
        running = true
        error = nil
        defer { running = false }
        do {
            answers = try await store.api.decide(state: state, questions: example.questions)
        } catch {
            self.error = error.localizedDescription
        }
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
