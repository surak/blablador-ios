import SwiftUI

/// A Model Context Protocol server reached over HTTP ("Streamable HTTP" transport).
struct MCPServer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    /// Sent as "Authorization: Bearer …" when set.
    var token = ""
    var enabled = true
    /// Ask before each tool call; "Allow for this chat" skips it until the chat ends.
    var askBeforeCalls = true

    /// Prefix of this server's tool names as the model sees them, e.g. "gitlab".
    var slug: String {
        let words = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }).split(separator: "_")
        let slug = String(words.joined(separator: "_").prefix(20))
        return slug.isEmpty ? "mcp" : slug
    }
}

struct MCPTool: Hashable {
    let server: UUID
    /// The tool's own name on its server.
    let name: String
    /// The name the model sees: "<server>__<tool>", at most 64 characters.
    let qualifiedName: String
    let description: String
    /// The tool's JSON Schema for its arguments, as JSON.
    let schema: Data

    var definition: [String: Any] {
        let parameters = (try? JSONSerialization.jsonObject(with: schema)) ?? ["type": "object", "properties": [String: Any]()]
        return ["type": "function", "function": ["name": qualifiedName, "description": description, "parameters": parameters]]
    }
}

enum MCPError: LocalizedError {
    case badURL, http(Int, String), rpc(String), noResponse
    var errorDescription: String? {
        switch self {
        case .badURL: "The server address must start with https://."
        case let .http(status, body): "The server answered \(status). \(body.prefix(200))"
        case let .rpc(message): message
        case .noResponse: "The server sent no answer."
        }
    }
}

/// JSON-RPC over HTTP POST; answers come as JSON or as a server-sent event stream.
actor MCPClient {
    let server: MCPServer
    private var sessionID: String?
    private var initialized = false
    private var nextID = 1

    init(server: MCPServer) { self.server = server }

    func listTools() async throws -> [MCPTool] {
        try await initializeIfNeeded()
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            let result = try await call("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            for item in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String else { continue }
                let qualified = String((server.slug + "__" + name).map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.prefix(64))
                let schema = (item["inputSchema"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    ?? Data(#"{"type":"object","properties":{}}"#.utf8)
                let description = "[\(server.name)] " + ((item["description"] as? String) ?? (item["title"] as? String) ?? name)
                tools.append(MCPTool(server: server.id, name: name, qualifiedName: qualified, description: String(description.prefix(1_000)), schema: schema))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 500
        return tools
    }

    /// Runs a tool and returns its text output; `isError` when the tool reported a failure.
    func callTool(_ name: String, arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        try await initializeIfNeeded()
        let result = try await call("tools/call", ["name": name, "arguments": arguments])
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text": parts.append(item["text"] as? String ?? "")
            case "resource":
                let resource = item["resource"] as? [String: Any]
                parts.append(resource?["text"] as? String ?? "[Resource \(resource?["uri"] as? String ?? "")]")
            case "resource_link": parts.append("[Link: \(item["uri"] as? String ?? "")]")
            case let type?: parts.append("[\(type) content not shown]")
            default: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted]) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        return (parts.joined(separator: "\n\n"), result["isError"] as? Bool ?? false)
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        _ = try await call("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Blablador", "version": version]
        ])
        try await send(["jsonrpc": "2.0", "method": "notifications/initialized"], expectsAnswer: false)
        initialized = true
    }

    private func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        guard let answer = try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": params], expectsAnswer: true) else {
            throw MCPError.noResponse
        }
        if let error = answer["error"] as? [String: Any] {
            throw MCPError.rpc(error["message"] as? String ?? "The server reported an error.")
        }
        return answer["result"] as? [String: Any] ?? [:]
    }

    @discardableResult
    private func send(_ message: [String: Any], expectsAnswer: Bool) async throws -> [String: Any]? {
        guard let url = URL(string: server.url.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https"
                || (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1"].contains(url.host() ?? "")) else {
            throw MCPError.badURL
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if !server.token.isEmpty { request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        if let session = http?.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        if let status = http?.statusCode, !(200..<300).contains(status) {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 500 { break } }
            if status == 404, sessionID != nil { sessionID = nil; initialized = false }
            throw MCPError.http(status, body)
        }
        guard expectsAnswer else { return nil }
        let id = message["id"] as? Int
        if http?.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            // Read events until the one answering this request.
            var data = ""
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    data += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] {
                        data = ""
                        if object["id"] as? Int == id || (object["result"] != nil || object["error"] != nil) && object["id"] == nil { return object }
                    }
                } else if line.isEmpty {
                    data = ""
                }
            }
            return nil
        }
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        // Some servers answer a single request with a one-element batch.
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first
    }
}

/// The user's MCP servers, saved encrypted (tokens included), and the tools they offer.
@MainActor
final class MCPLibrary: ObservableObject {
    static let shared = MCPLibrary()

    @Published private(set) var servers: [MCPServer] = []
    /// Tools per server, loaded on first use and after edits.
    @Published private(set) var tools: [UUID: [MCPTool]] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var loading: Set<UUID> = []
    private var clients: [UUID: MCPClient] = [:]

    private init() {
        if let data = EncryptedStorage.read(Self.fileURL),
           let servers = try? JSONDecoder().decode([MCPServer].self, from: data) {
            self.servers = servers
        }
    }

    func save(_ server: MCPServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
        clients[server.id] = nil
        tools[server.id] = nil
        errors[server.id] = nil
        persist()
        Task { await load(server) }
    }

    func delete(_ ids: Set<UUID>) {
        servers.removeAll { ids.contains($0.id) }
        for id in ids { clients[id] = nil; tools[id] = nil; errors[id] = nil }
        persist()
    }

    func server(_ id: UUID) -> MCPServer? { servers.first { $0.id == id } }

    /// Connects and lists the server's tools.
    func load(_ server: MCPServer) async {
        guard server.enabled else { return }
        loading.insert(server.id)
        defer { loading.remove(server.id) }
        do {
            tools[server.id] = try await client(for: server).listTools()
            errors[server.id] = nil
        } catch {
            tools[server.id] = []
            errors[server.id] = error.localizedDescription
        }
    }

    /// Tools of all enabled servers, loading any not loaded yet.
    func availableTools() async -> [MCPTool] {
        let enabled = servers.filter(\.enabled)
        await withTaskGroup(of: Void.self) { group in
            for server in enabled where tools[server.id] == nil { group.addTask { await self.load(server) } }
        }
        return enabled.flatMap { tools[$0.id] ?? [] }
    }

    func call(_ tool: MCPTool, arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        guard let server = server(tool.server) else { throw MCPError.rpc("This server was removed.") }
        return try await client(for: server).callTool(tool.name, arguments: arguments)
    }

    private func client(for server: MCPServer) -> MCPClient {
        if let client = clients[server.id] { return client }
        let client = MCPClient(server: server)
        clients[server.id] = client
        return client
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        EncryptedStorage.write(data, to: Self.fileURL)
    }

    private static var fileURL: URL { AppFolder.url.appendingPathComponent("mcp.json") }
}

// MARK: - Views

/// Settings screen: connected MCP servers.
struct MCPServersView: View {
    @ObservedObject private var library = MCPLibrary.shared
    @State private var editing: MCPServer?

    var body: some View {
        Form {
            Section {
                if library.servers.isEmpty {
                    Text("No servers yet.").foregroundStyle(.secondary)
                }
                ForEach(library.servers) { server in
                    Button {
                        editing = server
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).foregroundStyle(.primary)
                                Text(status(server))
                                    .scaledFont(.caption)
                                    .foregroundStyle(library.errors[server.id] == nil ? Color.secondary : Color.red)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if library.loading.contains(server.id) { ProgressView().controlSize(.small) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in library.delete(Set(offsets.map { library.servers[$0].id })) }
                Button("Add server…") { editing = MCPServer(name: "", url: "https://") }
            } footer: {
                Text("Connect services that speak the Model Context Protocol (MCP), such as GitLab, a calendar or your own tools, and the assistant can use their tools in every chat. Blablador connects over HTTPS (\"Streamable HTTP\"). Tool calls wait for your OK unless you turn that off for a server. What a tool returns is treated like web content: it can't change the assistant's memory.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connected tools (MCP)")
        .task { for server in library.servers where library.tools[server.id] == nil { await library.load(server) } }
        .sheet(item: $editing) { server in
            NavigationStack { MCPServerEditor(server: server) }
        }
    }

    private func status(_ server: MCPServer) -> String {
        if !server.enabled { return "Off" }
        if let error = library.errors[server.id] { return error }
        guard let tools = library.tools[server.id] else { return "Connecting…" }
        return tools.count == 1 ? "1 tool" : "\(tools.count) tools: " + tools.prefix(4).map(\.name).joined(separator: ", ") + (tools.count > 4 ? "…" : "")
    }
}

private struct MCPServerEditor: View {
    @State var server: MCPServer
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. GitLab", text: $server.name)
                TextField("https://example.org/mcp", text: $server.url)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
#endif
                SecureField("Access token (optional)", text: $server.token)
            } footer: {
                Text("The token is sent as \"Authorization: Bearer …\" and stored encrypted on this device.")
            }
            Section {
                Toggle("On", isOn: $server.enabled)
                Toggle("Ask before each tool call", isOn: $server.askBeforeCalls)
            }
            if MCPLibrary.shared.server(server.id) != nil {
                Section {
                    Button("Remove server", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(server.name.isEmpty ? "New server" : server.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    server.url = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
                    MCPLibrary.shared.save(server)
                    dismiss()
                }
                .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: server.url)?.host() == nil)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .confirmationDialog("Remove \(server.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                MCPLibrary.shared.delete([server.id])
                dismiss()
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
#endif
    }
}
