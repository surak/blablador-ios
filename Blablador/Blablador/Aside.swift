import SwiftUI

/// A question asked aside with /btw while a reply is being written: it is answered in a chat of its own,
/// reading the open chat up to the point where the long reply started, so the reply itself is not disturbed.
struct Aside: Identifiable, Hashable {
    var id = UUID()
    var question: String
    /// The chat the aside was asked in.
    var chat: UUID
    var answer = ""
    /// Shows it is still being answered: a potato verb, "Searching the web…".
    var status: String?
    var isError = false
    /// The chat the answer is kept in, once it has one.
    var answerChat: UUID?
    var date = Date()

    /// The answer as shown in the card, without what only matters while streaming.
    var shown: String { answer.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum AsideTools {
    /// Tool rounds for one aside: a question asked aside wants an answer quickly.
    static let maxRounds = 4

    /// The question in "/btw <text>"; "" for a bare /btw; nil when the text isn't the command.
    static func command(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower == "/btw" || lower.hasPrefix("/btw ") || lower.hasPrefix("/btw\n") else { return nil }
        return String(trimmed.dropFirst("/btw".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How the model is asked, with what was said in the chat before: the aside shares the chat up to the
    /// question the long reply is answering, and never sees that reply, which is only half written.
    static func prompt(question: String, context: [[String: Any]]) -> [[String: Any]] {
        let system = """
        The user asks you something aside (/btw) while you are writing a longer answer in the chat; the question \
        is answered on its own, so it must not be about finishing that answer. Answer briefly and directly, in the \
        user's language, with a tool only when the question really needs one. What was said in the chat before is \
        below for context; the answer you are writing there is not part of it.
        """
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        messages += context
        messages.append(["role": "user", "content": question])
        return messages
    }

    /// What the reply that keeps running is told, so the aside doesn't pull it off its task.
    static let resume = """
    While you were writing, the user asked something aside (in a separate window): "{{question}}". That is \
    answered separately and is not part of this answer. Don't answer it here; continue your answer where it \
    stopped and finish it.
    """

    /// The note is needed the other way round too: the long reply must not answer the question asked aside,
    /// and must not drift off because a tap on the screen raced ahead of it.
    static func resumeNote(_ question: String) -> String {
        resume.replacingOccurrences(of: "{{question}}", with: String(question.prefix(500)))
    }
}

/// Above the composer while an aside is answered, and after: the question, the answer and where it went.
struct AsideCard: View {
    let aside: Aside
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(Theme.gradient)
                Text(aside.question)
                    .scaledFont(.subheadline, weight: .semibold)
                    .lineLimit(expanded ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                if aside.answerChat != nil {
                    Button(action: onOpen) {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open it as a chat of its own")
                    .accessibilityLabel("Open the aside as a chat of its own")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss the aside")
            }
            if expanded {
                if let status = aside.status, aside.shown.isEmpty {
                    Text(status)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if !aside.shown.isEmpty {
                    MarkdownText(text: aside.shown)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if aside.isError {
                    Text("It couldn't be answered.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.gradient, lineWidth: 1).opacity(0.4)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
