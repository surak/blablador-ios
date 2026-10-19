import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Lets images in the chat start an edit in the composer.
struct ImageEditAction {
    var edit: ((String) -> Void)?
}

private struct ImageEditKey: EnvironmentKey {
    static let defaultValue = ImageEditAction()
}

extension EnvironmentValues {
    var editImage: ImageEditAction {
        get { self[ImageEditKey.self] }
        set { self[ImageEditKey.self] = newValue }
    }
}

/// Small "Edit" button laid over an image.
private struct EditImageButton: View {
    let name: String
    @Environment(\.editImage) private var editImage

    var body: some View {
        if let edit = editImage.edit {
            Button {
                edit(name)
            } label: {
                Label("Edit", systemImage: "paintbrush.pointed.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel("Edit image")
        }
    }
}

struct MessageView: View {
    let message: ChatMessage
    let isLast: Bool
    let isStreaming: Bool
    @ObservedObject var synthesizer: SpeechSynthesizer
    let onRegenerate: () -> Void

    @State private var copied = false
    @State private var selectingText = false

    var body: some View {
        content
            .sheet(isPresented: $selectingText) {
                SelectTextView(text: message.content)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.images, id: \.self) { name in
                                ImageThumbnail(name: name, size: message.images.count == 1 ? 180 : 100)
                            }
                        }
                    }
                    ForEach(message.documents) { document in
                        DocumentChip(document: document)
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
        case .assistant, .system:
            HStack(alignment: .top, spacing: 12) {
                AvatarView(isActive: isLast && isStreaming)
                VStack(alignment: .leading, spacing: 10) {
                    if let status = message.status {
                        Label(status, systemImage: status.hasPrefix("Search") ? "globe" : status.contains("image") ? "paintbrush.pointed" : status.hasPrefix("Speaking") ? "waveform" : status.contains("nowledge") ? "books.vertical" : "ellipsis")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .symbolEffect(.pulse)
                    }
                    ForEach(message.images, id: \.self) { name in
                        GeneratedImage(name: name)
                    }
                    ForEach(message.audio, id: \.self) { name in
                        SpeechClip(name: name)
                    }
                    if message.content.isEmpty {
                        if message.status == nil && message.images.isEmpty && message.audio.isEmpty { TypingIndicator() }
                    } else if message.isError {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(message.content)
                                .textSelection(.enabled)
                        }
                        .foregroundStyle(.red)
                    } else {
                        MarkdownText(text: message.content)
                    }
                    if !message.citations.isEmpty {
                        CitationsView(citations: message.citations)
                    }
                    if !message.sources.isEmpty {
                        SourcesView(sources: message.sources)
                    }
                    if !(isLast && isStreaming) && (!message.content.isEmpty || !message.images.isEmpty || !message.audio.isEmpty) {
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

            Button {
                selectingText = true
            } label: {
                Image(systemName: "selection.pin.in.out")
            }
            .accessibilityLabel("Select text")

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

/// The Blablador dog from the app icon.
private struct AvatarView: View {
    let isActive: Bool
    @State private var pulse = false

    var body: some View {
        Image("Avatar")
            .resizable()
            .interpolation(.high)
            .frame(width: 28, height: 28)
            .opacity(isActive && pulse ? 0.45 : 1)
            .animation(isActive ? .easeInOut(duration: 0.7).repeatForever() : .default, value: pulse)
            .onChange(of: isActive, initial: true) { _, active in pulse = active }
            .accessibilityHidden(true)
    }
}

private struct ImageThumbnail: View {
    let name: String
    let size: CGFloat
    @State private var showViewer = false
    @Environment(\.editImage) private var editImage

    var body: some View {
        StoredImage(name: name, maxPixelSize: 600)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
            .onTapGesture { showViewer = true }
            .overlay(alignment: .bottomTrailing) { EditImageButton(name: name) }
            .sheet(isPresented: $showViewer) { ImageViewer(name: name).environment(\.editImage, editImage) }
    }
}

private struct GeneratedImage: View {
    let name: String
    @State private var showViewer = false
    @Environment(\.editImage) private var editImage

    var body: some View {
        StoredImage(name: name)
            .frame(maxWidth: 420)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { showViewer = true }
            .overlay(alignment: .bottomTrailing) { EditImageButton(name: name) }
            .sheet(isPresented: $showViewer) { ImageViewer(name: name).environment(\.editImage, editImage) }
    }
}

/// Full-size image with share and save.
struct ImageViewer: View {
    let name: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.editImage) private var editImage
    @State private var saved = false

    var body: some View {
        NavigationStack {
            StoredImage(name: name, maxPixelSize: nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let edit = editImage.edit {
                            Button {
                                dismiss()
                                edit(name)
                            } label: {
                                Label("Edit", systemImage: "paintbrush.pointed")
                            }
                        }
#if os(iOS)
                        Button {
                            if let data = ImageStore.data(for: name), let image = UIImage(data: data) {
                                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                                saved = true
                            }
                        } label: {
                            Label(saved ? "Saved" : "Save to Photos", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        }
#endif
                        ShareLink(item: ImageStore.url(for: name)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
        }
#if os(macOS)
        .frame(minWidth: 600, minHeight: 600)
#endif
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

    private enum Block {
        case text(String)
        case code(language: String, body: String)
        case table(header: [String], alignments: [HorizontalAlignment], rows: [[String]])
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }
        // Split on pipes that aren't escaped as \|.
        var cells: [String] = [], current = "", previous: Character = " "
        for character in row {
            if character == "|" && previous != "\\" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        cells.append(current)
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    /// `|---|:--:|` style separator line; returns column alignments.
    private static func separator(_ line: String) -> [HorizontalAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-"),
              trimmed.range(of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$"#, options: .regularExpression) != nil
        else { return nil }
        return cells(trimmed).map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
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

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                if !inCode { language = String(trimmed.dropFirst(3)) }
                inCode.toggle()
            } else if !inCode, trimmed.contains("|"), index + 1 < lines.count,
                      let alignments = Self.separator(lines[index + 1]) {
                // Table: header, separator, then rows until a line without a pipe.
                flush()
                let header = Self.cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(Self.cells(lines[index]))
                    index += 1
                }
                let columns = max(header.count, alignments.count)
                func pad(_ row: [String]) -> [String] { Array((row + Array(repeating: "", count: columns)).prefix(columns)) }
                result.append(.table(header: pad(header), alignments: Array((alignments + Array(repeating: .leading, count: columns)).prefix(columns)), rows: rows.map(pad)))
                continue
            } else {
                buffer.append(line)
            }
            index += 1
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .text(body):
                    // One Text per block so a selection can span lines.
                    Text(attributed(body))
                case let .code(language, body):
                    CodeBlock(language: language, code: body)
                case let .table(header, alignments, rows):
                    table(header: header, alignments: alignments, rows: rows)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func table(header: [String], alignments: [HorizontalAlignment], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], alignment: alignments[column]).bold()
                    }
                }
                .background(Theme.surface)
                ForEach(rows.indices, id: \.self) { row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(rows[row][column], alignment: alignments[column])
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.3)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func cell(_ markdown: String, alignment: HorizontalAlignment) -> some View {
        // Models put <br> in cells for line breaks.
        let text = markdown.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        return Text(inline(text))
            .font(.subheadline)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .frame(minWidth: 40, maxWidth: 320, alignment: Alignment(horizontal: alignment, vertical: .top))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .gridColumnAlignment(alignment)
    }

    private func attributed(_ body: String) -> AttributedString {
        let lines = body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var result = AttributedString()
        for (index, raw) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += line(raw)
        }
        return result
    }

    private func line(_ raw: String) -> AttributedString {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let heading = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            let level = trimmed[heading].filter { $0 == "#" }.count
            var text = inline(String(trimmed[heading.upperBound...]))
            text.font = level <= 2 ? .title3.bold() : .headline
            return text
        }
        if let bullet = trimmed.range(of: #"^([-*+]|\d+\.)\s+"#, options: .regularExpression) {
            let marker = trimmed[bullet].trimmingCharacters(in: .whitespaces)
            let indent = String(repeating: "    ", count: raw.prefix { $0 == " " }.count / 2)
            var prefix = AttributedString(indent + (marker.first?.isNumber == true ? marker : "•") + " ")
            prefix.foregroundColor = .secondary
            return prefix + inline(String(trimmed[bullet.upperBound...]))
        }
        return inline(trimmed)
    }

    private func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
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

/// Full answer in a text view where any range can be selected, like Gemini's "Select text".
private struct SelectTextView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: .constant(text))
                .padding(.horizontal)
                .navigationTitle("Select text")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy all") {
                            Clipboard.copy(text)
                            dismiss()
                        }
                    }
                }
        }
#if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
#endif
    }
}
