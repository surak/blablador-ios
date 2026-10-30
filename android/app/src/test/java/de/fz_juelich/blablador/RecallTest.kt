package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.BlabladorApi
import de.fz_juelich.blablador.data.ChatIndex
import de.fz_juelich.blablador.data.ChatMessage
import de.fz_juelich.blablador.data.ChatRole
import de.fz_juelich.blablador.data.ChatSearch
import de.fz_juelich.blablador.data.Conversation
import de.fz_juelich.blablador.data.Embeddings
import de.fz_juelich.blablador.data.Memory
import de.fz_juelich.blablador.data.MemoryStore
import de.fz_juelich.blablador.data.find
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import kotlin.math.sqrt

/** A unit vector along one axis, standing in for the embedding of a topic. */
private fun axis(index: Int) = FloatArray(Embeddings.DIMENSION).also { it[index] = 1f }

class EmbeddingTest {
    @Test fun shortenedAndNormalised() {
        val short = Embeddings.shortened(FloatArray(1024) { (it % 7) - 3f })
        assertEquals(Embeddings.DIMENSION, short.size)
        assertEquals(1f, Embeddings.similarity(short, short), 0.0001f)
        assertTrue(Embeddings.decode(Embeddings.encode(short)).contentEquals(short))
    }

    @Test fun memoriesChosenByMeaningWithoutSharedWords() {
        val memories = (1..60).map { Memory(text = "Unrelated fact number $it", vector = Embeddings.encode(axis(1))) }.toMutableList()
        memories[3] = Memory(text = "The user's cluster is JUPITER", vector = Embeddings.encode(axis(0)))
        val prompt = MemoryStore.systemPrompt(memories, "How busy is my supercomputer?", axis(0))
        assertTrue(prompt.contains("4. The user's cluster is JUPITER"))
        assertFalse(prompt.contains("5. Unrelated fact number 5\n"))
    }

    /** Scores like real Qwen3 embeddings: unrelated memories still around 0.4 to 0.5. */
    @Test fun onlyMemoriesCloseToTheBestMatchAreSent() {
        fun vector(similarity: Float) = Embeddings.encode(FloatArray(Embeddings.DIMENSION).also {
            it[0] = similarity; it[1] = sqrt(1 - similarity * similarity)
        })
        val memories = (1..40).map { Memory(text = "Filler $it", vector = vector(0.3f)) }.toMutableList()
        memories[0] = Memory(text = "Team runs JUPITER", vector = vector(0.75f))
        memories[1] = Memory(text = "Nodes move to JUPITER in January", vector = vector(0.56f))
        memories[2] = Memory(text = "Prefers short answers", vector = vector(0.505f))
        val prompt = MemoryStore.systemPrompt(memories, "Which supercomputer?", axis(0))
        assertTrue(prompt.contains("1. Team runs JUPITER"))
        assertTrue(prompt.contains("2. Nodes move to JUPITER in January"))
        assertFalse(prompt.contains("3. Prefers short answers"))
    }
}

/** search_chats by meaning, against a fake embeddings and rerank server. */
class ChatFindTest {
    private val server = MockWebServer()
    private val endpoint = BlabladorApi.endpoint

    @Before fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val body = BlabladorApi.json.parseToJsonElement(request.body.readUtf8()).jsonObject
                if (request.path!!.endsWith("/embeddings")) {
                    // "compute"-ish texts point one way, everything else another.
                    val inputs = body["input"]!!.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() }
                    val data = buildJsonArray {
                        inputs.forEachIndexed { index, text ->
                            val topic = if (listOf("GPU", "nodes", "supercomputer", "compute").any { it in text }) 0 else 1
                            add(buildJsonObject {
                                put("index", index)
                                put("embedding", buildJsonArray { axis(topic).forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } })
                            })
                        }
                    }
                    return MockResponse().setBody(buildJsonObject { put("data", data) }.toString())
                }
                // Rerank: put the document mentioning December first.
                val documents = body["documents"]!!.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() }
                val results = buildJsonArray {
                    documents.forEachIndexed { index, text ->
                        add(buildJsonObject { put("index", index); put("relevance_score", if ("December" in text) 0.9 else 0.1) })
                    }
                }
                return MockResponse().setBody(buildJsonObject { put("results", results) }.toString())
            }
        }
        server.start()
        BlabladorApi.endpoint = server.url("/v1").toString()
        Embeddings.forceAvailable = true
    }

    @After fun stop() {
        Embeddings.forceAvailable = false
        BlabladorApi.endpoint = endpoint
        server.shutdown()
    }

    @Test fun findsByMeaningAndReranks() = runTest {
        val gpu = Conversation(title = "Cluster planning", model = "m", messages = listOf(
            ChatMessage(role = ChatRole.user, content = "We agreed on 40 GPU nodes for the new project."),
            ChatMessage(role = ChatRole.assistant, content = "Noted: 40 nodes, starting in December after the upgrade."),
        ))
        val cooking = Conversation(title = "Dinner", model = "m", messages = listOf(
            ChatMessage(role = ChatRole.user, content = "How long do I boil pasta for al dente results?"),
        ))
        val result = ChatSearch.find("How much supercomputer time did we plan?", listOf(gpu, cooking), null, BlabladorApi("test"), ChatIndex(null))
        assertTrue(result, result.startsWith("[Cluster planning,"))
        assertTrue(result.split("\n\n").first().contains("December"))
        assertFalse(result.contains("pasta"))
    }
}
