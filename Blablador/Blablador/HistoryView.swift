import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var search = ""
    let onClose: () -> Void

    private var filtered: [Conversation] {
        let sorted = store.conversations.sorted { $0.updatedAt > $1.updatedAt }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(search)
                || conversation.messages.contains { $0.content.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Theme.surface, in: Capsule())

            Button {
                store.newChat()
                onClose()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(Theme.surface, in: Capsule())
            }
            .buttonStyle(.plain)

            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            List {
                ForEach(filtered) { conversation in
                    Button {
                        store.select(conversation)
                        onClose()
                    } label: {
                        Text(conversation.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(conversation.id == store.currentID ? Theme.surface : Color.clear)
                    .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
                    .swipeActions {
                        Button(role: .destructive) { store.delete(conversation) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) { store.delete(conversation) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if filtered.isEmpty {
                    Text(search.isEmpty ? "No chats yet" : "No results")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}
