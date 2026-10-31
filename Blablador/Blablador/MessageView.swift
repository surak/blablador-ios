import UniformTypeIdentifiers
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Lets images in the chat start an edit in the composer.
struct ImageEditAction {
    var edit: ((String) -> Void)?
    /// Starts a new video from this video's last frame.
    var continueVideo: ((String) -> Void)?
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
                    .scaledFont(.caption, weight: .semibold)
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
    var models: [RemoteModel] = []
    /// Regenerates the reply, with another model when one is given.
    let onRegenerate: (String?) -> Void
    var onEdit: (String) -> Void = { _ in }
    var onShowVersion: (Int) -> Void = { _ in }

    @State private var copied = false
    @State private var selectingText = false
    @State private var editing = false
    @State private var exportingWord = false

    private func copyForDocs() {
        DocumentExport.copyFormatted(message.content)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    var body: some View {
        content
            .sheet(isPresented: $selectingText) {
                SelectTextView(text: message.content)
            }
            .sheet(isPresented: $editing) {
                EditMessageView(text: message.content) { onEdit($0) }
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
                    if !message.mentions.isEmpty {
                        MentionChips(mentions: message.mentions)
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .scaledFont(.body)
                            .textSelection(.enabled)
                            .contextMenu {
                                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                                    .disabled(isStreaming)
                                Button { Clipboard.copy(message.content) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                    }
                    HStack(spacing: 14) {
                        if !message.alternatives.isEmpty {
                            VersionSwitcher(message: message, onShow: onShowVersion)
                        }
                        if !message.content.isEmpty {
                            Button { editing = true } label: { Image(systemName: "pencil") }
                                .buttonStyle(.plain)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Edit")
                        }
                    }
                    .disabled(isStreaming)
                }
            }
        case .assistant, .system:
            HStack(alignment: .top, spacing: 12) {
                AvatarView(isActive: isLast && isStreaming)
                VStack(alignment: .leading, spacing: 10) {
                    if let status = message.status {
                        Label(status, systemImage: status.hasPrefix("Search") ? "globe" : status.contains("image") ? "paintbrush.pointed" : status.hasPrefix("Speaking") ? "waveform" : status.contains("nowledge") ? "books.vertical" : status.hasPrefix("Running") || status.hasPrefix("Waiting") ? "terminal" : "ellipsis")
                            .scaledFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .symbolEffect(.pulse)
                    }
                    if !message.plan.isEmpty {
                        PlanCard(items: message.plan)
                    }
                    if !message.reasoning.isEmpty {
                        ThinkingView(text: message.reasoning, isThinking: isLast && isStreaming && message.content.isEmpty)
                    }
                    if !message.webImages.isEmpty {
                        WebImagesView(images: message.webImages)
                    }
                    ForEach(message.images, id: \.self) { name in
                        GeneratedImage(name: name)
                    }
                    ForEach(message.audio, id: \.self) { name in
                        SpeechClip(name: name)
                    }
                    ForEach(message.videos, id: \.self) { name in
                        VideoClip(name: name)
                    }
                    if !message.steps.isEmpty {
                        AgentStepsView(steps: message.steps)
                    }
                    if message.content.isEmpty {
                        // Only while this reply is being written; a finished empty reply shows nothing moving.
                        if isLast && isStreaming && message.status == nil && message.images.isEmpty && message.audio.isEmpty && message.videos.isEmpty && message.steps.isEmpty && message.reasoning.isEmpty { TypingIndicator() }
                    } else if message.isError {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(message.content)
                                .scaledFont(.body)
                                .textSelection(.enabled)
                        }
                        .foregroundStyle(.red)
                    } else {
                        MarkdownText(text: message.content)
                    }
                    ForEach(message.skillsUsed, id: \.self) { name in
                        Label("Used skill: \(name)", systemImage: "wand.and.stars")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(message.remembered, id: \.self) { fact in
                        Label("Remembered: \(fact)", systemImage: "brain")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(message.forgotten, id: \.self) { fact in
                        Label("Forgot: \(fact)", systemImage: "brain")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(message.suggestedSkills) { skill in
                        SuggestedSkillCard(skill: skill)
                    }
                    if !message.citations.isEmpty {
                        CitationsView(citations: message.citations)
                    }
                    if !message.sources.isEmpty {
                        SourcesView(sources: message.sources)
                    }
                    if !(isLast && isStreaming) && (!message.content.isEmpty || !message.images.isEmpty || !message.audio.isEmpty || !message.videos.isEmpty) {
                        actions
                    }
                    if let trace = message.trace, !(isLast && isStreaming) {
                        TraceLine(trace: trace, messageID: message.id)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 18) {
            Button {
                if let audio = message.audio.last {
                    AudioStore.copyToClipboard(audio)
                } else {
                    Clipboard.copy(message.content)
                }
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel(message.audio.isEmpty ? "Copy" : "Copy audio")

            if message.audio.isEmpty {
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
            }

            if message.audio.isEmpty {
                ShareLink(item: message.content) {
                    Image(systemName: "square.and.arrow.up")
                }
                Menu {
                    Button { copyForDocs() } label: {
                        Label("Copy for Google Docs or Word", systemImage: "doc.on.clipboard")
                    }
                    Button { exportingWord = true } label: {
                        Label("Save as Word…", systemImage: "doc.richtext")
                    }
                } label: {
                    Image(systemName: "doc.richtext")
                } primaryAction: {
                    copyForDocs()
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Copy for Google Docs")
                .help("Copy with formatting, to paste into Google Docs or Word; or save as Word")
                .fileExporter(isPresented: $exportingWord, document: WordFile(markdown: message.content),
                              contentType: UTType(filenameExtension: "docx") ?? .data,
                              defaultFilename: DocumentExport.fileName(for: message.content)) { _ in }
            } else {
                #if os(iOS)
                Button {
                    AudioStore.presentShareSheet(message.audio)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share audio")
                #else
                ShareLink(items: message.audio.map(SpeechAudio.init),
                          preview: { _ in SharePreview("Blablador speech") }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share audio")
                #endif
            }

            if isLast {
                Menu {
                    Button { onRegenerate(nil) } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    if !models.isEmpty {
                        Section("Regenerate with") {
                            ForEach(models) { model in
                                Button(model.displayName) { onRegenerate(model.id) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                } primaryAction: {
                    onRegenerate(nil)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Regenerate")
            }

            if !message.alternatives.isEmpty {
                VersionSwitcher(message: message, onShow: onShowVersion)
                    .disabled(isStreaming)
            }
        }
        .buttonStyle(.plain)
        .scaledFont(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// "‹ 2/3 ›" for a message with earlier or later versions.
struct VersionSwitcher: View {
    let message: ChatMessage
    let onShow: (Int) -> Void

    var body: some View {
        let versions = (message.alternatives.map { $0[0].version } + [message.version]).sorted()
        let position = (versions.firstIndex(of: message.version) ?? 0) + 1
        HStack(spacing: 6) {
            Button { onShow(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(position == 1)
                .accessibilityLabel("Previous version")
            Text("\(position)/\(versions.count)")
                .monospacedDigit()
            Button { onShow(1) } label: { Image(systemName: "chevron.right") }
                .disabled(position == versions.count)
                .accessibilityLabel("Next version")
        }
        .buttonStyle(.plain)
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Changes a message and sends it again; the old version stays.
private struct EditMessageView: View {
    @State var text: String
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .scaledFont(.body)
                .padding(.horizontal)
                .navigationTitle("Edit message")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            onSend(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
#if os(macOS)
        .frame(minWidth: 500, minHeight: 300)
#endif
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
                    if let url = URL(string: source.url), SafeLinks.allows(url) {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.title)
                                    .scaledFont(.caption, weight: .medium)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Text("\(index + 1) · \(url.host() ?? source.url)")
                                    .scaledFont(.caption2)
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

/// Pictures found online, each linking to the page it is on.
private struct WebImagesView: View {
    let images: [WebImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images, id: \.image) { image in
                    if let page = URL(string: image.url), SafeLinks.allows(page),
                       let source = URL(string: image.thumbnail ?? image.image) {
                        Link(destination: page) {
                            AsyncImage(url: source) { phase in
                                if let picture = phase.image {
                                    picture.resizable().scaledToFill()
                                } else {
                                    Theme.surface
                                }
                            }
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .help(image.title)
                        .accessibilityLabel(image.title)
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
    @Environment(\.textScale) private var textScale
    let text: String

    private enum Block {
        case text(String)
        case code(language: String, body: String)
        /// Text with maths, typeset with KaTeX.
        case math(String)
        /// A finished mermaid, html or svg block, shown rendered.
        case artifact(language: String, body: String)
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

        func flush(closed: Bool = false) {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined(separator: "\n")
            let kind = language.lowercased().trimmingCharacters(in: .whitespaces)
            if inCode {
                result.append(closed && ["mermaid", "html", "svg"].contains(kind) ? .artifact(language: kind, body: joined) : .code(language: language, body: joined))
            } else {
                result.append(MathDetection.hasInlineMath(joined) ? .math(joined) : .text(joined))
            }
            buffer.removeAll()
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush(closed: inCode)
                if !inCode { language = String(trimmed.dropFirst(3)) }
                inCode.toggle()
            } else if !inCode, trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\["),
                      let end = Self.displayMathEnd(lines, from: index) {
                // Display maths, one or more lines, up to the closing $$ or \].
                flush()
                result.append(.math(lines[index...end].joined(separator: "\n")))
                index = end + 1
                continue
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
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(Self.parts(body).enumerated()), id: \.offset) { _, part in
                            partView(part)
                        }
                    }
                case let .code(language, body):
                    CodeBlock(language: language, code: body)
                case let .math(body):
                    WebBlock(kind: .markdown, content: body)
                case let .artifact(language, body):
                    ArtifactBlock(language: language, code: body)
                case let .table(header, alignments, rows):
                    table(header: header, alignments: alignments, rows: rows)
                }
            }
        }
        .textSelection(.enabled)
        // About 80 characters per line at most, like a printed page; tables and code may be wider.
        .frame(maxWidth: 680 * textScale, alignment: .leading)
    }

    /// Index of the line that closes display maths opened on `start`, or nil while it's still being written.
    private static func displayMathEnd(_ lines: [String], from start: Int) -> Int? {
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        let close = first.hasPrefix("$$") ? "$$" : "\\]"
        if first.count > 2, first.dropFirst(2).contains(close) { return start }
        for index in (start + 1)..<lines.count where lines[index].contains(close) { return index }
        return nil
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
            .scaledFont(.subheadline)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .frame(minWidth: 40, maxWidth: 320, alignment: Alignment(horizontal: alignment, vertical: .top))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .gridColumnAlignment(alignment)
    }

    /// A piece of a text block: a heading, a paragraph (or list), a quote or a rule.
    enum Part: Equatable {
        case heading(level: Int, text: String)
        case paragraph([String])
        /// List items: marker ("•" or "3."), text and nesting depth.
        case list([ListItem])
        case quote([String])
        case rule
    }

    struct ListItem: Equatable {
        let marker: String
        let text: String
        let depth: Int
    }

    /// Splits text into headings, paragraphs, lists and quotes at blank lines, headings and rules. A line that is
    /// all bold ("**Structure**") is a heading too: models often write section titles that way.
    static func parts(_ body: String) -> [Part] {
        var parts: [Part] = []
        var lines: [String] = []
        var items: [ListItem] = []
        var quoting = false
        func flush() {
            if !lines.isEmpty { parts.append(quoting ? .quote(lines) : .paragraph(lines)) }
            if !items.isEmpty { parts.append(.list(items)) }
            lines = []
            items = []
        }
        for raw in body.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // A blank line between list items keeps the list together.
                if items.isEmpty { flush() }
            } else if let bullet = trimmed.range(of: #"^([-*+•]|\d+[.)])\s+"#, options: .regularExpression) {
                if !lines.isEmpty || quoting {
                    let pending = items
                    items = []
                    flush()
                    items = pending
                }
                quoting = false
                let marker = trimmed[bullet].trimmingCharacters(in: .whitespaces)
                let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
                items.append(ListItem(marker: marker.first?.isNumber == true ? marker.replacingOccurrences(of: ")", with: ".") : "•",
                                      text: String(trimmed[bullet.upperBound...]), depth: min(indent / 2, 4)))
            } else if !items.isEmpty, raw.hasPrefix("  "), let last = items.indices.last {
                // A wrapped continuation line of the last list item.
                items[last] = ListItem(marker: items[last].marker, text: items[last].text + " " + trimmed, depth: items[last].depth)
            } else if let title = trimmed.range(of: #"^\*\*([^*]{1,80})\*\*:?$"#, options: .regularExpression), title.lowerBound == trimmed.startIndex {
                flush()
                parts.append(.heading(level: 4, text: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "*:"))))
            } else if let heading = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                parts.append(.heading(level: trimmed[heading].filter { $0 == "#" }.count, text: String(trimmed[heading.upperBound...])))
            } else if trimmed.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                flush()
                parts.append(.rule)
            } else if trimmed.hasPrefix(">") {
                if !quoting { flush() }
                quoting = true
                lines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                if quoting || !items.isEmpty { flush() }
                quoting = false
                lines.append(raw)
            }
        }
        flush()
        return parts
    }

    @ViewBuilder
    private func partView(_ part: Part) -> some View {
        switch part {
        case let .heading(level, text):
            Text(inline(text))
                .font(Self.headingFont(level: level, scale: textScale))
                .padding(.top, level <= 2 ? 12 : 8)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(lines):
            Text(attributed(lines))
                .scaledFont(.body)
                .lineSpacing(3)
        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .scaledFont(.body)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: item.marker == "•" ? 10 : 20, alignment: .trailing)
                        Text(inline(item.text))
                            .scaledFont(.body)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 20)
                }
            }
        case let .quote(lines):
            Text(attributed(lines))
                .scaledFont(.body)
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(Theme.gradient).frame(width: 3) }
        case .rule:
            Divider().padding(.vertical, 6)
        }
    }

    private static func headingFont(level: Int, scale: CGFloat) -> Font {
#if os(macOS)
        let size: CGFloat = level == 1 ? 21 : level == 2 ? 18 : level == 3 ? 16 : 15
        return .system(size: size * scale, weight: level <= 2 ? .bold : .semibold)
#else
        return .system(level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: level <= 2 ? .bold : .semibold)
#endif
    }

    private func attributed(_ lines: [String]) -> AttributedString {
        var result = AttributedString()
        for (index, raw) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += line(raw)
        }
        return result
    }

    private func line(_ raw: String) -> AttributedString {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
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
        var text = (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
        // Source numbers like [3] or [3][7] become small raised marks, so they don't break up the sentence.
        let plain = String(text.characters)
        guard let regex = try? NSRegularExpression(pattern: #"\s?(\[\d{1,3}\])+"#) else { return text }
        for match in regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).reversed() {
            guard let range = Range(match.range, in: plain) else { continue }
            let start = text.characters.index(text.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let end = text.characters.index(start, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
            let marks = plain[range].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "][", with: ",")
            var replacement = AttributedString(marks)
            replacement.font = .system(size: 10 * textScale, weight: .medium)
            replacement.foregroundColor = .secondary
            replacement.baselineOffset = 5
            text.replaceSubrange(start..<end, with: replacement)
        }
        return text
    }
}

private struct CodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                Spacer()
                CodeActions(language: language, code: code)
                    .buttonStyle(.plain)
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .scaledFont(.footnote, design: .monospaced)
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

/// The model's thinking trace: open and following along while it thinks, folded away once the answer starts.
private struct ThinkingView: View {
    let text: String
    let isThinking: Bool
    @State private var expanded: Bool?

    private var isExpanded: Bool { expanded ?? isThinking }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.25)) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .symbolEffect(.pulse, isActive: isThinking)
                    Text(isThinking ? "Thinking…" : "Thought process")
                    Image(systemName: "chevron.right")
                        .scaledFont(.caption, weight: .semibold)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the thinking" : "Shows the thinking")

            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxHeight: 260)
                    .onChange(of: text) { _, _ in
                        if isThinking { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.secondary.opacity(0.3)).frame(width: 2)
                }
            }
        }
    }
}

/// Links in replies and sources open only on the web or as email. Other schemes (file:, app URL schemes…)
/// could launch apps or files from text a model or search result wrote.
enum SafeLinks {
    static func allows(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    static let action = OpenURLAction { url in allows(url) ? .systemAction : .discarded }
}
