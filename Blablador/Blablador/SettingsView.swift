import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                    Link("Get an API key", destination: URL(string: "https://sdlaml.pages.jsc.fz-juelich.de/ai/guides/blablador_api_access/")!)
                } header: {
                    Text("Blablador API")
                } footer: {
                    if let error = store.modelsError {
                        Text(error).foregroundStyle(.red)
                    } else if !store.models.isEmpty {
                        Text("Connected – \(store.chatModels.count) chat models available.")
                    }
                }

                Section("Model") {
                    Picker("Default model", selection: Binding(
                        get: { store.selectedModel },
                        set: { store.selectedModel = $0 }
                    )) {
                        if !store.chatModels.contains(where: { $0.id == store.selectedModel }) {
                            Text(store.selectedModelName).tag(store.selectedModel)
                        }
                        ForEach(store.chatModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    Button("Reset to \(BlabladorAPI.defaultModel)") {
                        store.selectedModel = BlabladorAPI.defaultModel
                    }
                }

                Section {
                    Toggle("Web search", isOn: Binding(
                        get: { store.webSearchEnabled },
                        set: { store.webSearchEnabled = $0 }
                    ))
                } footer: {
                    Text("Lets the model search the web via search.blablador.fz-juelich.de when it needs current information.")
                }

                Section {
                    TextField("e.g. Answer concisely.", text: Binding(
                        get: { store.systemPrompt },
                        set: { store.systemPrompt = $0 }
                    ), axis: .vertical)
                    .lineLimit(2...6)
                } header: {
                    Text("Custom instructions")
                } footer: {
                    Text("Sent as a system prompt with every chat.")
                }

                Section {
                    Button("Delete all chats", role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Delete all chats?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { store.deleteAll() }
            }
        }
        .onAppear { apiKey = store.apiKey }
        .onSubmit(save)
#if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
#endif
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != store.apiKey { store.apiKey = trimmed }
    }
}
