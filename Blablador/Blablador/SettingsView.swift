import SwiftUI

struct SettingsView: View {
    @State private var responseTimeout = BlabladorAPI.responseTimeoutMinutes
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var endpoint = BlabladorAPI.endpoint
    @State private var confirmDelete = false
    @AppStorage("ocrEngine") private var ocrEngine: OCREngine = .onDevice

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Endpoint", text: $endpoint)
                            .autocorrectionDisabled()
#if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
#endif
                        if endpoint != BlabladorAPI.defaultEndpoint {
                            Button("Blablador") {
                                endpoint = BlabladorAPI.defaultEndpoint
                                save()
                            }
                            .help("Use Blablador again")
                        }
                    }
                    SecureField("API key", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                    Link("Get an API key (read_user scope)", destination: URL(string: "https://codebase.helmholtz.cloud/-/user_settings/personal_access_tokens/legacy/new")!)
                } header: {
                    Text("Blablador API")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let error = store.modelsError {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        } else if !store.models.isEmpty {
                            Text("Connected – \(store.chatModels.count) chat models available.")
                        }
                        Text("The endpoint is Blablador unless you change it. For Blablador, create a Helmholtz Codebase personal access token with the read_user scope and paste it as the API key.")
                    }
                }

                Section {
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
                    Picker("Wait for a reply", selection: $responseTimeout) {
                        ForEach(BlabladorAPI.responseTimeoutChoices, id: \.self) { minutes in
                            Text(BlabladorAPI.timeoutLabel(minutes)).tag(minutes)
                        }
                    }
                    .onChange(of: responseTimeout) { _, minutes in BlabladorAPI.responseTimeoutMinutes = minutes }
                } header: {
                    Text("Model")
                } footer: {
                    Text("How long to wait for a model that is slow to start or pauses while thinking, before giving up.")
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

                Section {
                    NavigationLink("Memory") { MemoryView() }
                } footer: {
                    Text("Facts about you the assistant remembers across chats.")
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

                Section("About") {
                    LabeledContent("Version", value: AppUpdater.currentVersion)
                    Button("Check for updates") { Task { await AppUpdater.shared.check(force: true) } }
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
        let newEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointChanged = newEndpoint != BlabladorAPI.endpoint
        if endpointChanged { BlabladorAPI.endpoint = newEndpoint.isEmpty ? BlabladorAPI.defaultEndpoint : newEndpoint }
        if trimmed != store.apiKey { store.apiKey = trimmed }
        else if endpointChanged { Task { await store.loadModels() } }
    }
}
