import Foundation

enum ChatRole: String, Codable {
    case system
    case user
    case assistant
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: ChatRole
    var content: String
    var date = Date()
    var isError = false
    var sources: [SearchResult] = []
    /// File names in ImageStore: attachments on user messages, generated images on replies.
    var images: [String] = []
    /// PDFs attached to user messages, as extracted text.
    var documents: [DocumentAttachment] = []
    /// Speech generated with Drama 3, as file names in AudioStore.
    var audio: [String] = []
    /// Knowledge base excerpts the reply was based on.
    var citations: [KnowledgeCitation] = []
    /// Transient status shown while tools run, e.g. "Searching the web…"
    var status: String?

    private enum CodingKeys: String, CodingKey { case id, role, content, date, isError, sources, images, documents, audio, citations }

    init(role: ChatRole, content: String, images: [String] = [], documents: [DocumentAttachment] = []) {
        self.role = role
        self.content = content
        self.images = images
        self.documents = documents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(ChatRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        date = try c.decode(Date.self, forKey: .date)
        isError = try c.decode(Bool.self, forKey: .isError)
        sources = try c.decodeIfPresent([SearchResult].self, forKey: .sources) ?? []
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        documents = try c.decodeIfPresent([DocumentAttachment].self, forKey: .documents) ?? []
        audio = try c.decodeIfPresent([String].self, forKey: .audio) ?? []
        citations = try c.decodeIfPresent([KnowledgeCitation].self, forKey: .citations) ?? []
    }
}

struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var model: String
    var messages: [ChatMessage] = []
    var updatedAt = Date()
    /// Knowledge bases searched for every message in this chat.
    var knowledge: [UUID]?

    static func new(model: String) -> Conversation {
        Conversation(title: "New chat", model: model)
    }
}

struct RemoteModel: Identifiable, Codable, Hashable {
    let id: String

    /// Models that cannot be used for text chat.
    var isChatCapable: Bool {
        let lowered = id.lowercased()
        let excluded = ["embedding", "rerank", "whisper", "flux", "image", "video", "voice", "davinci", "anonymizer"]
        return !excluded.contains { lowered.contains($0) }
    }

    var displayName: String {
        // "15 - DeepSeek-V4.1-Flash on JUWELS Booster" -> "DeepSeek-V4.1-Flash on JUWELS Booster"
        if let range = id.range(of: #"^\d+\s*-\s*"#, options: .regularExpression) {
            return String(id[range.upperBound...])
        }
        return id
    }
}
