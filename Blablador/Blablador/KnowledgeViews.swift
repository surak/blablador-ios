import SwiftUI
import UniformTypeIdentifiers

/// All knowledge bases, with create and delete.
struct KnowledgeListView: View {
    @ObservedObject private var library = KnowledgeLibrary.shared
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                ForEach(library.bases) { base in
                    NavigationLink {
                        KnowledgeBaseView(baseID: base.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(base.name)
                            Text(library.progress[base.id] ?? summary(base))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { library.bases[$0].id }.forEach(library.delete)
                }
                Button {
                    newName = ""
                    naming = true
                } label: {
                    Label("New knowledge base", systemImage: "plus")
                }
            } footer: {
                Text("Collections of PDFs and text files that stay available. Turn one on for a chat with + → Knowledge, and Blablador answers from those documents with citations. Text is extracted and stored on this device; only the passages needed for a question are sent to Blablador.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Knowledge")
        .alert("New knowledge base", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { library.create(name: name) }
            }
        }
    }

    private func summary(_ base: KnowledgeBase) -> String {
        base.documents.count == 1 ? "1 document" : "\(base.documents.count) documents"
    }
}

/// Documents in one knowledge base.
struct KnowledgeBaseView: View {
    let baseID: UUID
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var library = KnowledgeLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        if let base = library.base(baseID) {
            Form {
                Section {
                    ForEach(base.documents) { document in
                        HStack(spacing: 10) {
                            Image(systemName: document.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.plaintext")
                                .foregroundStyle(Theme.gradient)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.name).lineLimit(1)
                                Text(detail(document)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
#if os(macOS)
                        .contextMenu {
                            Button("Remove", role: .destructive) { library.remove(document, from: baseID) }
                        }
#endif
                    }
                    .onDelete { offsets in
                        offsets.map { base.documents[$0] }.forEach { library.remove($0, from: baseID) }
                    }
                    if let progress = library.progress[baseID] {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(progress).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Add documents", systemImage: "plus")
                    }
                    .disabled(library.progress[baseID] != nil)
                } header: {
                    Text("Documents")
                } footer: {
                    Text("PDFs (scanned pages are read with on-device OCR), text and Markdown files.")
                }
                Section {
                    Button("Rename") {
                        newName = base.name
                        renaming = true
                    }
                    Button("Delete knowledge base", role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(base.name)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                library.add(urls, to: baseID, api: store.api)
            }
            .alert("Rename", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { library.rename(baseID, to: name) }
                }
            }
            .confirmationDialog("Delete \(base.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    library.delete(baseID)
                    dismiss()
                }
            }
            .alert("Couldn't add document", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
                Button("OK") {}
            } message: {
                Text(library.lastError ?? "")
            }
        }
    }

    private func detail(_ document: KnowledgeDocument) -> String {
        var parts = [document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages", "\(document.chunkCount) passages"]
        if document.ocrPageCount > 0 { parts.append("OCR") }
        return parts.joined(separator: " · ")
    }
}

/// Knowledge bases switched on for the current chat, shown above the input.
struct ActiveKnowledgeStrip: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var library = KnowledgeLibrary.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.activeKnowledge, id: \.self) { id in
                    if let base = library.base(id) {
                        HStack(spacing: 4) {
                            Image(systemName: "books.vertical.fill")
                            Text(base.name)
                            Button {
                                store.toggleKnowledge(id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Stop using \(base.name)")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.gradient, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }
}

/// Knowledge submenu for the composer's + menu.
struct KnowledgeMenu: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var library = KnowledgeLibrary.shared
    let onManage: () -> Void

    var body: some View {
        Menu {
            ForEach(library.bases) { base in
                Toggle(isOn: Binding(
                    get: { store.activeKnowledge.contains(base.id) },
                    set: { _ in store.toggleKnowledge(base.id) }
                )) {
                    Text(base.name)
                }
            }
            if !library.bases.isEmpty { Divider() }
            Button(action: onManage) {
                Label("Manage knowledge…", systemImage: "gearshape")
            }
        } label: {
            Label("Knowledge", systemImage: "books.vertical")
        }
    }
}

/// Excerpts a reply was based on; tap one to read it.
struct CitationsView: View {
    let citations: [KnowledgeCitation]
    @State private var shown: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(citations.indices, id: \.self) { index in
                    let citation = citations[index]
                    Button {
                        shown = index
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(citation.text)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Text("K\(index + 1) · \(citation.document)\(citation.page.map { " · p. \($0)" } ?? "")")
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(width: 190, height: 72, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: Binding(get: { shown.map(Shown.init) }, set: { shown = $0?.id })) { item in
            let citation = citations[item.id]
            NavigationStack {
                ScrollView {
                    Text(citation.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("K\(item.id + 1) · \(citation.document)\(citation.page.map { ", p. \($0)" } ?? "")")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { shown = nil }
                    }
                }
            }
#if os(macOS)
            .frame(minWidth: 480, minHeight: 360)
#endif
        }
    }

    private struct Shown: Identifiable { let id: Int }
}

/// Knowledge bases matching a "#name" typed in the composer.
struct KnowledgeSuggestions: View {
    let query: String
    let onPick: (KnowledgeBase) -> Void
    @ObservedObject private var library = KnowledgeLibrary.shared

    private var matches: [KnowledgeBase] {
        let words = query.lowercased()
        return library.bases.filter { words.isEmpty || $0.name.lowercased().contains(words) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if matches.isEmpty {
                Text(library.bases.isEmpty ? "No knowledge bases yet. Create one with the books button at the top."
                                           : "No knowledge base matches “\(query)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            ForEach(matches.prefix(6)) { base in
                Button {
                    onPick(base)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "books.vertical")
                            .foregroundStyle(Theme.gradient)
                        Text(base.name)
                        Spacer()
                        Text(base.documents.count == 1 ? "1 document" : "\(base.documents.count) documents")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}
