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
)

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
