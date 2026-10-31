package de.fz_juelich.blablador.data

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
enum class ChatRole { system, user, assistant }

@Serializable
data class SearchResult(
    val title: String,
    val url: String,
    val content: String? = null,
)

/** A picture found online, shown next to the answer; [url] is the page it is on. */
@Serializable
data class WebImage(
    val title: String,
    val url: String,
    val image: String,
    val thumbnail: String? = null,
)

/** A PDF or photo attached to a message, reduced to its text on the device. */
@Serializable
data class DocumentAttachment(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val text: String,
    val pageCount: Int,
    /** Pages without a text layer that were read with OCR. */
    val ocrPageCount: Int = 0,
    /** For data files (CSV, Excel, JSON…): the original file in DataFiles, given to Python as /data/<name>. [text] then holds a description and the first lines. */
    val dataFile: String? = null,
)

@Serializable
data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: ChatRole,
    val content: String,
    val date: Long = System.currentTimeMillis(),
    val isError: Boolean = false,
    val sources: List<SearchResult> = emptyList(),
    /** Facts saved to and deleted from long-term memory while answering. */
    val remembered: List<String> = emptyList(),
    val forgotten: List<String> = emptyList(),
    /** Tools of connected MCP servers used for this reply, as "Server: tool". */
    val toolCalls: List<String> = emptyList(),
    /**
     * Earlier versions of the chat from this message on (after an edit or a regenerate), each starting with its
     * own version of this message; [version] numbers them in the order they were made.
     */
    val alternatives: List<List<ChatMessage>> = emptyList(),
    val version: Int = 1,
    /** Skills loaded with use_skill, and skills the model offered to save. */
    val skillsUsed: List<String> = emptyList(),
    val suggestedSkills: List<Skill> = emptyList(),
    /** Pictures found online with image_search. */
    val webImages: List<WebImage> = emptyList(),
    /** File names in ImageStore: attachments on user messages, generated images on replies. */
    val images: List<String> = emptyList(),
    val documents: List<DocumentAttachment> = emptyList(),
    /** Speech generated with Drama 3, as file names in AudioStore. */
    val audio: List<String> = emptyList(),
    /** Videos made with alias-video, as file names in VideoStore. */
    val videos: List<String> = emptyList(),
    /** Knowledge-base excerpts the reply was based on, cited as [K1], [K2]… */
    val citations: List<KnowledgeCitation> = emptyList(),
    /** The model's thinking trace, streamed separately from the answer. */
    val reasoning: String = "",
    /** The plan the model keeps with update_plan. */
    val plan: List<PlanItem> = emptyList(),
    /** Model, time, tokens and tool calls of a reply. */
    val trace: Trace? = null,
    /** Tools, skills, knowledge bases and servers the user mentioned with @ (user messages). */
    val mentions: List<Mention> = emptyList(),
    /** Transient status shown while tools run, e.g. "Searching the web…". Not saved. */
    @kotlinx.serialization.Transient val status: String? = null,
)

@Serializable
data class Conversation(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val model: String,
    val messages: List<ChatMessage> = emptyList(),
    /** Knowledge bases searched for this chat. */
    val knowledge: List<String> = emptyList(),
    val updatedAt: Long = System.currentTimeMillis(),
    /** Summary of the first [summaryCount] messages, sent instead of them once the chat got long. */
    val summary: String? = null,
    val summaryCount: Int? = null,
) {
    /** Messages of every version, for deleting their files. */
    val allMessages: List<ChatMessage>
        get() {
            fun expand(messages: List<ChatMessage>): List<ChatMessage> = messages.flatMap { listOf(it) + it.alternatives.flatMap(::expand) }
            return expand(messages)
        }
}

data class RemoteModel(val id: String) {
    /** Models that cannot be used for text chat. */
    val isChatCapable: Boolean
        get() {
            val lowered = id.lowercase()
            return listOf("embedding", "rerank", "whisper", "flux", "image", "video", "voice", "davinci", "anonymizer", "ocr", "clef")
                .none { lowered.contains(it) }
        }

    /** "15 - DeepSeek-V4.1-Flash on JUWELS Booster" -> "DeepSeek-V4.1-Flash on JUWELS Booster" */
    val displayName: String get() = id.replace(Regex("""^\d+\s*-\s*"""), "")
}
