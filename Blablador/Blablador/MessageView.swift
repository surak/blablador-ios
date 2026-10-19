import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let isLast: Bool
    let isStreaming: Bool
    @ObservedObject var synthesizer: SpeechSynthesizer
    let onRegenerate: () -> Void

    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
            }
        case .assistant, .system:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkle")
                    .font(.title3)
                    .foregroundStyle(Theme.gradient)
                    .symbolEffect(.pulse, isActive: isLast && isStreaming)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 10) {
                    if let status = message.status {
                        Label(status, systemImage: "globe")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .symbolEffect(.pulse)
                    }
                    if message.content.isEmpty {
                        if message.status == nil { TypingIndicator() }
                    } else if message.isError {
                        Label(message.content, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    } else {
                        MarkdownText(text: message.content)
                    }
                    if !message.sources.isEmpty {
                        SourcesView(sources: message.sources)
                    }
                    if !(isLast && isStreaming) && !message.content.isEmpty {
                        actions
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 18) {
            Button {
                Clipboard.copy(message.content)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel("Copy")

            Button {
                synthesizer.toggle(message)
            } label: {
                Image(systemName: synthesizer.speakingID == message.id ? "stop.circle" : "speaker.wave.2")
            }
            .accessibilityLabel("Read aloud")

            ShareLink(item: message.content) {
                Image(systemName: "square.and.arrow.up")
            }

            if isLast {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Regenerate")
            }
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

private struct SourcesView: View {
    let sources: [SearchResult]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Text("\(index + 1) · \(url.host() ?? source.url)")
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(width: 170, height: 72, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }
}

private struct TypingIndicator: View {
    @State private var phase = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Theme.gradient)
            .frame(width: 180, height: 12)
            .opacity(phase ? 0.9 : 0.25)
            .animation(.easeInOut(duration: 0.8).repeatForever(), value: phase)
            .onAppear { phase = true }
    }
}

/// Lightweight markdown renderer: fenced code blocks, headings, bullets and inline styles.
struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case text(String)
        case code(language: String, body: String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var buffer: [String] = []
        var inCode = false
        var language = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined(separator: "\n")
            result.append(inCode ? .code(language: language, body: joined) : .text(joined))
            buffer.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                if !inCode { language = String(trimmed.dropFirst(3)) }
                inCode.toggle()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .text(body):
                    ForEach(Array(paragraphs(body).enumerated()), id: \.offset) { _, paragraph in
                        line(paragraph)
                    }
                case let .code(language, body):
                    CodeBlock(language: language, code: body)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func paragraphs(_ body: String) -> [String] {
        body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let heading = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            let level = trimmed[heading].filter { $0 == "#" }.count
            inline(String(trimmed[heading.upperBound...]))
                .font(level <= 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        } else if let bullet = trimmed.range(of: #"^([-*+]|\d+\.)\s+"#, options: .regularExpression) {
            let marker = trimmed[bullet].trimmingCharacters(in: .whitespaces)
            let indent = CGFloat(raw.prefix { $0 == " " }.count / 2) * 16
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker.first?.isNumber == true ? marker : "•")
                    .foregroundStyle(.secondary)
                inline(String(trimmed[bullet.upperBound...]))
            }
            .padding(.leading, indent)
        } else {
            inline(trimmed)
        }
    }

    private func inline(_ string: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return Text(attributed)
        }
        return Text(string)
    }
}

private struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(12)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
