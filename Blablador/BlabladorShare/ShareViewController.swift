import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The share sheet's "Blablador": collects the shared web page, text, photos or files, lets the user add a
/// question, and hands it all to the app, which opens a new chat with it.
@MainActor
final class ShareModel: ObservableObject {
    @Published var question = ""
    @Published var summary = "Reading…"
    @Published var ready = false
    @Published var error: String?
    private var text: [String] = []
    private var files: [(name: String, data: Data)] = []
    var done: (Bool) -> Void = { _ in }

    func load(_ items: [NSExtensionItem]) async {
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            do {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                    files.append((url.lastPathComponent, try Data(contentsOf: url)))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                          let url = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    text.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    let data = try await loadData(provider, UTType.image.identifier)
                    files.append(("Photo \(files.count + 1).\(provider.registeredContentTypes.first(where: { $0.conforms(to: .image) })?.preferredFilenameExtension ?? "jpg")", data))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    files.append((provider.suggestedName.map { $0.hasSuffix(".pdf") ? $0 : $0 + ".pdf" } ?? "Document.pdf",
                                  try await loadData(provider, UTType.pdf.identifier)))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let string = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    text.append(string)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
        var parts: [String] = []
        if !files.isEmpty { parts.append(files.count == 1 ? files[0].name : "\(files.count) files") }
        if let link = text.first(where: { $0.hasPrefix("http") }) { parts.append(URL(string: link)?.host() ?? link) }
        else if !text.isEmpty { parts.append("text") }
        summary = parts.isEmpty ? "Nothing Blablador can use was shared." : parts.joined(separator: " · ")
        ready = !parts.isEmpty
    }

    private func loadData(_ provider: NSItemProvider, _ type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    func send() {
        let combined = ([question.trimmingCharacters(in: .whitespacesAndNewlines)] + text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        do {
            try ShareInbox.put(text: combined, files: files)
            done(true)
        } catch {
            self.error = "Couldn't hand this to Blablador: \(error.localizedDescription)"
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Blablador").font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
            }
            Label(model.summary, systemImage: "paperclip")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField("Ask about it (optional)", text: $model.question, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if model.ready { model.send() } }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button {
                model.send()
            } label: {
                Text("Open in Blablador").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.ready)
#if os(iOS)
            Text("Then open Blablador: a new chat with this is waiting.")
                .font(.caption)
                .foregroundStyle(.secondary)
#endif
        }
        .padding()
#if os(macOS)
        .frame(width: 380)
#endif
    }
}

#if os(macOS)
final class ShareViewController: NSViewController {
    private let model = ShareModel()

    override func loadView() {
        model.done = { [weak self] _ in
            NSWorkspace.shared.open(ShareInbox.openURL)
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let hosting = NSHostingView(rootView: ShareView(model: model) { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        hosting.frame.size = hosting.fittingSize
        view = hosting
        Task { await model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }
}
#else
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.done = { [weak self] _ in self?.extensionContext?.completeRequest(returningItems: nil) }
        let hosting = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        Task { await model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }
}
#endif
