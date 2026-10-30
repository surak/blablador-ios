package de.fz_juelich.blablador.data

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.math.sqrt

/** A document indexed in a knowledge base. */
@Serializable
data class KnowledgeDocument(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val pageCount: Int,
    val ocrPageCount: Int = 0,
    val chunkCount: Int = 0,
    val addedAt: Long = System.currentTimeMillis(),
)

/** A named collection of documents that chats can search, like Open WebUI's knowledge. */
@Serializable
data class KnowledgeBase(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val documents: List<KnowledgeDocument> = emptyList(),
    val embeddingModel: String = BlabladorApi.EMBEDDING_MODEL,
    val createdAt: Long = System.currentTimeMillis(),
)

/** An excerpt used to answer, shown under the reply. */
@Serializable
data class KnowledgeCitation(val document: String, val page: Int? = null, val text: String)

/** A passage of a document; its embedding sits at the same position in vectors.bin. */
@Serializable
private data class Chunk(val document: String, val page: Int? = null, val text: String)

private class VectorStore(val chunks: List<Chunk>, val vectors: FloatArray, val dimension: Int)

/** Knowledge bases (RAG): chunks and normalized vectors stored per base on the device. */
class KnowledgeLibrary(private val context: Context, private val scope: CoroutineScope, private val pdf: PdfExtractor) {
    companion object {
        /** Passages retrieved per question, before and after re-ranking. */
        const val CANDIDATE_COUNT = 24
        const val RESULT_COUNT = 6
        const val CHUNK_LENGTH = 1_200
        const val CHUNK_OVERLAP = 200

        /** Context block for the system prompt, numbered [K1], [K2]… to match the citations. */
        fun context(citations: List<KnowledgeCitation>): String {
            val passages = citations.mapIndexed { index, citation ->
                val page = citation.page?.let { ", page $it" }.orEmpty()
                "[K${index + 1}] ${citation.document}$page:\n${citation.text}"
            }
            return "Excerpts from the user's knowledge base that may be relevant to the latest message. " +
                "Use them to answer and cite them inline as [K1], [K2]. If they don't contain the answer, say so instead of guessing.\n\n" +
                passages.joinToString("\n\n")
        }

        /** Splits text into overlapping chunks, preferring paragraph and sentence boundaries. */
        fun split(text: String): List<String> {
            val clean = text.replace(Regex("[ \t]+"), " ").trim()
            if (clean.isEmpty()) return emptyList()
            val chunks = mutableListOf<String>()
            var start = 0
            while (start < clean.length) {
                var end = minOf(start + CHUNK_LENGTH, clean.length)
                if (end < clean.length) {
                    val windowStart = start + CHUNK_LENGTH / 2
                    val cut = listOf("\n\n", ". ", "\n").firstNotNullOfOrNull { separator ->
                        clean.lastIndexOf(separator, end - separator.length).takeIf { it >= windowStart }?.plus(separator.length)
                    }
                    if (cut != null) end = cut
                }
                val chunk = clean.substring(start, end).trim()
                if (chunk.length > 20) chunks += chunk
                if (end >= clean.length) break
                val next = maxOf(end - CHUNK_OVERLAP, start)
                start = if (next > start) next else end
            }
            return chunks
        }

        /** Undoes PdfExtractor's "[Page n]" markers. */
        private fun pages(text: String): List<Pair<Int?, String>> {
            val matches = Regex("""^\[Page (\d+)]\n""", RegexOption.MULTILINE).findAll(text).toList()
            if (matches.isEmpty()) return listOf(null to text)
            return matches.mapIndexed { index, match ->
                val end = if (index + 1 < matches.size) matches[index + 1].range.first else text.length
                match.groupValues[1].toIntOrNull() to text.substring(match.range.last + 1, end)
            }
        }

        private fun normalized(vector: FloatArray): FloatArray {
            val norm = sqrt(vector.fold(0f) { sum, value -> sum + value * value })
            return if (norm > 0) FloatArray(vector.size) { vector[it] / norm } else vector
        }

        /** The embedding service is down or overloaded, as opposed to a dropped connection. */
        private fun isServerFailure(error: Throwable) =
            (error is BlabladorException && error.status >= 500) || error is InterruptedIOException

        /** The network is flaky; retry dropped connections a few times, but not a server that doesn't answer. */
        private suspend fun <T> retrying(operation: suspend () -> T): T {
            var attempt = 0
            while (true) {
                try {
                    return operation()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    attempt++
                    if (attempt >= 3 || isServerFailure(e) || e !is IOException) throw e
                    delay(attempt * 1000L)
                }
            }
        }

        /** Blablador answers 500 when a request carries too many tokens, so halve the batch until it fits. */
        private suspend fun embed(texts: List<String>, model: String, api: BlabladorApi): List<FloatArray> = try {
            retrying { api.embeddings(texts, model) }
        } catch (e: BlabladorException) {
            if (e.status < 500 || texts.size < 2) throw e
            val middle = texts.size / 2
            embed(texts.subList(0, middle), model, api) + embed(texts.subList(middle, texts.size), model, api)
        }
    }

    private val resolver = context.contentResolver
    private val root = File(context.filesDir, "knowledge").apply { mkdirs() }
    private val indexFile = File(root, "bases.json")
    private val serializer = ListSerializer(KnowledgeBase.serializer())
    private val cache = mutableMapOf<String, VectorStore>()

    val bases = mutableStateListOf<KnowledgeBase>().apply {
        addAll(runCatching { BlabladorApi.json.decodeFromString(serializer, EncryptedStorage.read(context, indexFile)!!) }.getOrDefault(emptyList()))
    }
    /** Indexing progress per base, e.g. "Indexing report.pdf · 40%". */
    val progress = mutableStateMapOf<String, String>()
    var lastError by mutableStateOf<String?>(null)

    fun base(id: String) = bases.firstOrNull { it.id == id }

    fun create(name: String): KnowledgeBase {
        val base = KnowledgeBase(name = name)
        bases += base
        persist()
        return base
    }

    fun rename(id: String, name: String) = change(id) { it.copy(name = name) }

    fun delete(id: String) {
        bases.removeAll { it.id == id }
        cache.remove(id)
        directory(id).deleteRecursively()
        persist()
    }

    fun remove(document: KnowledgeDocument, baseId: String) {
        val store = load(baseId)
        val keep = store.chunks.indices.filter { store.chunks[it].document != document.id }
        val vectors = FloatArray(keep.size * store.dimension)
        keep.forEachIndexed { to, from -> store.vectors.copyInto(vectors, to * store.dimension, from * store.dimension, (from + 1) * store.dimension) }
        save(baseId, VectorStore(keep.map { store.chunks[it] }, vectors, store.dimension))
        change(baseId) { base -> base.copy(documents = base.documents.filter { it.id != document.id }) }
    }

    // MARK: Indexing

    /** Extracts, chunks and embeds files one after another. */
    fun add(uris: List<Uri>, baseId: String, api: BlabladorApi) {
        scope.launch {
            uris.forEachIndexed { number, uri ->
                val fileName = pdf.displayName(uri) ?: "document"
                val label = if (uris.size > 1) "$fileName · ${number + 1}/${uris.size}" else fileName
                progress[baseId] = "Reading $label…"
                try {
                    index(uri, fileName, baseId, api, label)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    lastError = if (isServerFailure(e)) "$fileName: Blablador's embedding service isn't responding. Try again later."
                    else "$fileName: ${e.message}"
                }
            }
            progress.remove(baseId)
        }
    }

    private suspend fun index(uri: Uri, fileName: String, baseId: String, api: BlabladorApi, label: String) {
        val isPdf = fileName.endsWith(".pdf", ignoreCase = true) || contentType(uri) == "application/pdf"
        val pages: List<Pair<Int?, String>>
        var document: KnowledgeDocument
        if (isPdf) {
            val extracted = pdf.extract(uri, api)
            pages = pages(extracted.text)
            document = KnowledgeDocument(name = extracted.name, pageCount = extracted.pageCount, ocrPageCount = extracted.ocrPageCount)
        } else {
            val text = withContext(Dispatchers.IO) { resolver.openInputStream(uri)?.use { it.readBytes().decodeToString() } }
                ?: throw IOException("Couldn't open the file.")
            pages = listOf(null to text)
            document = KnowledgeDocument(name = fileName, pageCount = 1)
        }

        val chunks = withContext(Dispatchers.Default) { pages.flatMap { (page, text) -> split(text).map { Chunk(document.id, page, it) } } }
        if (chunks.isEmpty()) throw IOException("No text found in this document.")
        var model = base(baseId)?.embeddingModel ?: BlabladorApi.EMBEDDING_MODEL

        val vectors = mutableListOf<FloatArray>()
        val batch = 4
        for (start in chunks.indices step batch) {
            progress[baseId] = "Indexing $label · ${start * 100 / chunks.size}%"
            val texts = chunks.subList(start, minOf(start + batch, chunks.size)).map { "${document.name}\n${it.text}" }
            val embeddings = try {
                embed(texts, model, api)
            } catch (e: Exception) {
                // Nothing is indexed with this model yet, so switching models is safe.
                if (e is CancellationException || !isServerFailure(e) || vectors.isNotEmpty() || load(baseId).chunks.isNotEmpty()
                    || model == BlabladorApi.FALLBACK_EMBEDDING_MODEL) throw e
                model = BlabladorApi.FALLBACK_EMBEDDING_MODEL
                change(baseId) { it.copy(embeddingModel = model) }
                embed(texts, model, api)
            }
            embeddings.forEach { vectors += normalized(it) }
        }

        val dimension = vectors.first().size
        val store = load(baseId)
        if (store.dimension != 0 && store.dimension != dimension) throw IOException("Embedding size changed; create a new knowledge base.")
        val combined = FloatArray(store.vectors.size + vectors.size * dimension)
        store.vectors.copyInto(combined)
        vectors.forEachIndexed { index, vector -> vector.copyInto(combined, store.vectors.size + index * dimension) }
        save(baseId, VectorStore(store.chunks + chunks, combined, dimension))

        document = document.copy(chunkCount = chunks.size)
        change(baseId) { it.copy(documents = it.documents + document) }
    }

    // MARK: Retrieval

    /** Finds the passages most relevant to [query] across the given bases. */
    suspend fun search(query: String, baseIds: List<String>, api: BlabladorApi): List<KnowledgeCitation> {
        val candidates = mutableListOf<Pair<Float, KnowledgeCitation>>()
        for ((model, group) in baseIds.mapNotNull(::base).groupBy { it.embeddingModel }) {
            // Qwen3 embeddings expect an instruction on the query side only.
            val instruction = "Instruct: Given a question, retrieve passages from documents that answer it\nQuery: $query"
            val embedding = retrying { api.embeddings(listOf(instruction), model) }.firstOrNull() ?: continue
            val vector = normalized(embedding)
            for (base in group) {
                val store = withContext(Dispatchers.IO) { load(base.id) }
                if (store.dimension != vector.size || store.chunks.isEmpty()) continue
                val names = base.documents.associate { it.id to it.name }
                withContext(Dispatchers.Default) {
                    // Vectors are normalized, so the dot product is the cosine similarity.
                    store.chunks.forEachIndexed { position, chunk ->
                        var score = 0f
                        val offset = position * store.dimension
                        for (i in 0 until store.dimension) score += store.vectors[offset + i] * vector[i]
                        candidates += score to KnowledgeCitation(names[chunk.document] ?: "Document", chunk.page, chunk.text)
                    }
                }
            }
        }
        val top = candidates.sortedByDescending { it.first }.take(CANDIDATE_COUNT).map { it.second }
        if (top.size <= RESULT_COUNT) return top
        return try {
            retrying { api.rerank(query, top.map { it.text }) }.take(RESULT_COUNT).map { top[it] }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            top.take(RESULT_COUNT)
        }
    }

    // MARK: Storage

    private fun contentType(uri: Uri) = resolver.getType(uri)

    private fun change(id: String, transform: (KnowledgeBase) -> KnowledgeBase) {
        val index = bases.indexOfFirst { it.id == id }
        if (index < 0) return
        bases[index] = transform(bases[index])
        persist()
    }

    private fun directory(id: String) = File(root, id).apply { mkdirs() }

    private fun load(id: String): VectorStore = cache.getOrPut(id) {
        val directory = directory(id)
        val chunks = runCatching {
            BlabladorApi.json.decodeFromString(ListSerializer(Chunk.serializer()), EncryptedStorage.read(context, File(directory, "chunks.json"))!!)
        }.getOrDefault(emptyList())
        val bytes = EncryptedStorage.readBytes(context, File(directory, "vectors.bin")) { it.size % 4 == 0 } ?: ByteArray(0)
        val vectors = FloatArray(bytes.size / 4).also { ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(it) }
        VectorStore(chunks, vectors, if (chunks.isEmpty()) 0 else vectors.size / chunks.size)
    }

    private fun save(id: String, store: VectorStore) {
        cache[id] = store
        val directory = directory(id)
        writeAtomically(File(directory, "chunks.json"),
            BlabladorApi.json.encodeToString(ListSerializer(Chunk.serializer()), store.chunks).toByteArray())
        val buffer = ByteBuffer.allocate(store.vectors.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        buffer.asFloatBuffer().put(store.vectors)
        writeAtomically(File(directory, "vectors.bin"), buffer.array())
    }

    private fun persist() = writeAtomically(indexFile, BlabladorApi.json.encodeToString(serializer, bases.toList()).toByteArray())

    private fun writeAtomically(file: File, data: ByteArray) = EncryptedStorage.writeBytes(context, file, data)
}
