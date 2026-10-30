package de.fz_juelich.blablador.data

import android.content.Context
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64
import kotlin.math.sqrt

/**
 * Text embeddings for finding memories and earlier chats by meaning. Vectors are cut to their first 512
 * dimensions and normalised, so a dot product is the cosine similarity.
 */
object Embeddings {
    const val DIMENSION = 512
    private const val BATCH_SIZE = 32

    /** Tests set this to use a mock server instead of Blablador. */
    @Volatile var forceAvailable = false

    /** Only Blablador is known to offer the embedding model; other endpoints fall back to keywords. */
    val available: Boolean
        get() = forceAvailable || BlabladorApi.endpoint.trim().trimEnd('/') == BlabladorApi.DEFAULT_ENDPOINT

    suspend fun embed(texts: List<String>, api: BlabladorApi): List<FloatArray> =
        texts.chunked(BATCH_SIZE).flatMap { batch -> api.embeddings(batch.map { it.take(2_000) }).map(::shortened) }

    fun shortened(vector: FloatArray): FloatArray {
        val short = vector.copyOf(minOf(DIMENSION, vector.size))
        val norm = sqrt(short.fold(0f) { sum, x -> sum + x * x })
        if (norm > 0) for (i in short.indices) short[i] /= norm
        return short
    }

    fun similarity(a: FloatArray, b: FloatArray): Float {
        if (a.size != b.size || a.isEmpty()) return 0f
        var dot = 0f
        for (i in a.indices) dot += a[i] * b[i]
        return dot
    }

    fun encode(vector: FloatArray): String {
        val buffer = ByteBuffer.allocate(vector.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        buffer.asFloatBuffer().put(vector)
        return Base64.getEncoder().encodeToString(buffer.array())
    }

    fun decode(text: String): FloatArray {
        val bytes = Base64.getDecoder().decode(text)
        return FloatArray(bytes.size / 4).also { ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(it) }
    }
}

/** Embeddings of earlier chat messages, kept encrypted and filled in the background after replies. */
class ChatIndex(private val context: Context?) {
    companion object {
        /** Messages embedded per update, so a long history is filled in over several replies. */
        const val PER_UPDATE = 256

        fun indexable(message: ChatMessage) = !message.isError && message.role != ChatRole.system && message.content.length >= 20
    }

    private val file = context?.let { File(it.filesDir, "chat-index.json") }
    private val serializer = MapSerializer(String.serializer(), String.serializer())
    private var vectors: MutableMap<String, FloatArray>? = null
    private var updating = false

    @Synchronized
    private fun load(): MutableMap<String, FloatArray> {
        vectors?.let { return it }
        val loaded = mutableMapOf<String, FloatArray>()
        val context = context
        val file = file
        if (context != null && file != null) runCatching {
            BlabladorApi.json.decodeFromString(serializer, EncryptedStorage.read(context, file)!!).forEach { (id, v) -> loaded[id] = Embeddings.decode(v) }
        }
        vectors = loaded
        return loaded
    }

    private fun save() {
        if (context == null || file == null) return
        val snapshot = synchronized(this) { load().mapValues { Embeddings.encode(it.value) } }
        EncryptedStorage.write(context, file, BlabladorApi.json.encodeToString(serializer, snapshot))
    }

    /** Embeds messages not indexed yet and forgets deleted ones. */
    suspend fun update(conversations: List<Conversation>, api: BlabladorApi) {
        if (!Embeddings.available || updating) return
        updating = true
        try {
            val vectors = load()
            val messages = conversations.flatMap { it.messages }.filter(::indexable)
            val present = messages.map { it.id }.toSet()
            val removed = synchronized(this) { vectors.keys.filter { it !in present }.onEach { vectors.remove(it) } }
            val missing = messages.filter { vectors[it.id] == null }.takeLast(PER_UPDATE)
            if (missing.isNotEmpty()) runCatching { Embeddings.embed(missing.map { it.content }, api) }.getOrNull()?.let { embedded ->
                synchronized(this) { missing.zip(embedded).forEach { (message, vector) -> vectors[message.id] = vector } }
            }
            if (missing.isNotEmpty() || removed.isNotEmpty()) save()
        } finally {
            updating = false
        }
    }

    fun vector(id: String): FloatArray? = load()[id]
}

/** Finds earlier messages by meaning and keywords, reranked; falls back to keywords without embeddings. */
suspend fun ChatSearch.find(query: String, conversations: List<Conversation>, excluding: String?, api: BlabladorApi, index: ChatIndex): String {
    val queryVector = if (Embeddings.available) runCatching { Embeddings.embed(listOf(query), api).firstOrNull() }.getOrNull() else null
    if (queryVector == null) return search(query, conversations, excluding)
    index.update(conversations, api)
    val words = MemoryStore.words(query)
    data class Candidate(val score: Float, val conversation: Conversation, val message: ChatMessage)
    val candidates = conversations.filter { it.id != excluding }.flatMap { conversation ->
        conversation.messages.filter(ChatIndex::indexable).mapNotNull { message ->
            val vector = index.vector(message.id)
            val meaning = vector?.let { Embeddings.similarity(it, queryVector) } ?: 0f
            val keywords = (MemoryStore.words(message.content) intersect words).size.toFloat()
            // One shared common word isn't enough when the meaning is known; unrelated texts still score 0.3 to 0.5.
            val matches = if (vector == null) keywords > 0 else meaning > 0.5f || keywords >= 2
            if (matches) Candidate(meaning + 0.05f * keywords, conversation, message) else null
        }
    }
    var best = candidates.sortedByDescending { it.score }.take(20)
    if (best.isEmpty()) return "No earlier chats mention \"$query\"."
    if (best.size > 1) runCatching { api.rerank(query, best.map { it.message.content.take(1_500) }) }.getOrNull()?.let { order ->
        best = order.mapNotNull { best.getOrNull(it) }
    }
    val format = java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM)
    return best.take(6).joinToString("\n\n") { hit ->
        val who = if (hit.message.role == ChatRole.user) "User" else "Assistant"
        "[${hit.conversation.title}, ${format.format(java.util.Date(hit.message.date))}] $who: ${hit.message.content.take(600)}"
    }
}
