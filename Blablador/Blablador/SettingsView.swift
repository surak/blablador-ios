import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var confirmDelete = false
    @AppStorage("ocrEngine") private var ocrEngine: OCREngine = .onDevice

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
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
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
                    Picker("Image model", selection: Binding(
                        get: { store.imageModel },
                        set: { store.imageModel = $0 }
                    )) {
                        ForEach(BlabladorAPI.imageModels, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    Toggle("Let the assistant create images", isOn: Binding(
                        get: { store.imageToolsEnabled },
                        set: { store.imageToolsEnabled = $0 }
                    ))
                } header: {
                    Text("Images")
                } footer: {
                    Text("Used for new images. Editing photos always uses Qwen-Image 2.1, the model that supports editing.")
                }

                Section {
                    Picker("Text recognition", selection: $ocrEngine) {
                        ForEach(OCREngine.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Documents")
                } footer: {
                    Text("Reads scanned PDF pages and text from photos. On device is private and works offline; Blablador's LightOnOCR keeps tables and layout better. If Blablador fails, the app reads on device.")
                }

                Section {
                    NavigationLink("Knowledge bases") { KnowledgeListView() }
                } footer: {
                    Text("PDF and text collections that chats can answer from.")
                }

                VoiceSettingsSection()

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
