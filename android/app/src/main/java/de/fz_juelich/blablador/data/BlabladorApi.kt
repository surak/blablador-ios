package de.fz_juelich.blablador.data

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class BlabladorException(val status: Int, val body: String) :
    Exception(if (status == 0) body else "Server returned $status. $body")

/** Client for Blablador's OpenAI-compatible API. */
class BlabladorApi(private val apiKey: String) {
    companion object {
        const val DEFAULT_ENDPOINT = "https://api.blablador.fz-juelich.de/v1"
        /** The OpenAI-compatible endpoint, Blablador unless changed in Settings. */
        @Volatile var endpoint = DEFAULT_ENDPOINT
        const val DEFAULT_MODEL = "deepseek-v4.1-flash-at-hzdr"
        /** Blablador's quick model for small jobs: chat titles, picking out memories. */
        const val FAST_MODEL = "alias-fast"

        /** The model for small jobs: alias-fast on Blablador, the chat's own model on other endpoints. */
        fun helperModel(chatModel: String) = if (endpoint.trim().trimEnd('/') == DEFAULT_ENDPOINT) FAST_MODEL else chatModel
        const val IMAGE_EDIT_MODEL = "alias-image"
        const val DEFAULT_IMAGE_MODEL = "alias-flux2"
        const val OCR_MODEL = "alias-ocr"
        const val SPEECH_MODEL = "alias-voice-drama3"
        const val TRANSCRIPTION_MODEL = "faster-whisper-large-v3"
        const val EMBEDDING_MODEL = "alias-qwen3-4b-embeddings"
        /** Used for a new knowledge base when the default embedding model doesn't respond. */
        const val FALLBACK_EMBEDDING_MODEL = "alias-embeddings"
        const val RERANK_MODEL = "alias-qwen3-4b-reranker"
        const val DECISION_MODEL = "alias-clef"
        /** MiniMax-H3: text to video with sound, at 24 fps. A 4-second clip takes about 3–4 minutes. */
        const val VIDEO_MODEL = "alias-video"
        val VIDEO_DURATIONS = listOf(4, 6, 8, 10)
        val VIDEO_ASPECTS = listOf("16:9" to "Landscape", "9:16" to "Portrait", "1:1" to "Square")
        val IMAGE_MODELS = listOf("alias-flux2" to "FLUX.2-dev", "alias-image" to "Qwen-Image 2.1")

        /** Minutes to wait for a reply to start or continue; 0 waits as long as it takes. Set in Settings. */
        @Volatile var responseTimeoutMinutes = 10
        val RESPONSE_TIMEOUT_CHOICES = listOf(2, 5, 10, 30, 0)
        fun timeoutLabel(minutes: Int) = if (minutes == 0) "No limit" else "$minutes minutes"

        /** Refuses replies too big to hold in memory, from a broken or hostile server. */
        private const val MAX_MEDIA_BYTES = 100L * 1024 * 1024
        private const val MAX_VIDEO_BYTES = 1024L * 1024 * 1024

        private fun checkSize(response: Response, limit: Long) {
            val length = response.body?.contentLength() ?: -1
            if (length > limit) throw BlabladorException(0, "The server's reply is too large (${length / (1024 * 1024)} MB).")
        }

        val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

        val client: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(300, TimeUnit.SECONDS)
            .writeTimeout(120, TimeUnit.SECONDS)
            .build()

        private val JSON_TYPE = "application/json".toMediaType()
    }

    sealed interface StreamEvent {
        data class Content(val text: String) : StreamEvent
        data class Reasoning(val text: String) : StreamEvent
        data class ToolCalls(val calls: List<ToolCall>) : StreamEvent
    }

    data class ToolCall(var id: String = "", var name: String = "", var arguments: String = "") {
        val wire: JsonObject
            get() = buildJsonObject {
                put("id", id)
                put("type", "function")
                put("function", buildJsonObject { put("name", name); put("arguments", arguments) })
            }
    }

    internal fun authorized(path: String) = request(path)

    /** Sends a request with its own timeout and returns the body bytes. */
    internal suspend fun send(request: Request, timeoutSeconds: Long): ByteArray = withContext(Dispatchers.IO) {
        client.newBuilder().callTimeout(timeoutSeconds, TimeUnit.SECONDS).build().newCall(request).await().use { response ->
            checkSize(response, MAX_MEDIA_BYTES)
            val bytes = response.body?.bytes() ?: ByteArray(0)
            if (!response.isSuccessful) throw BlabladorException(response.code, bytes.decodeToString().take(500))
            bytes
        }
    }

    internal suspend fun postBytes(path: String, body: JsonObject, timeoutSeconds: Long) = send(post(path, body), timeoutSeconds)

    internal suspend fun postJson(path: String, body: JsonObject, timeoutSeconds: Long) = postBytes(path, body, timeoutSeconds).decodeToString()

    private fun request(path: String): Request.Builder {
        if (apiKey.isEmpty()) throw BlabladorException(0, "No API key set. Add your Blablador API key in Settings.")
        return Request.Builder().url("${endpoint.trim().trimEnd('/')}/$path").header("Authorization", "Bearer $apiKey")
    }

    private suspend fun execute(request: Request): String = withContext(Dispatchers.IO) {
        client.newCall(request).await().use { response ->
            checkSize(response, MAX_MEDIA_BYTES)
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw BlabladorException(response.code, body.take(500))
            body
        }
    }

    private fun post(path: String, body: JsonObject): Request =
        request(path).post(body.toString().toRequestBody(JSON_TYPE)).build()

    suspend fun models(): List<RemoteModel> {
        val body = execute(request("models").build())
        return json.parseToJsonElement(body).jsonObject["data"]!!.jsonArray
            .map { RemoteModel(it.jsonObject["id"]!!.jsonPrimitive.content) }
    }

    /** Blablador keys are Helmholtz Codebase (GitLab) tokens, so the owner's name comes from GitLab. */
    suspend fun userName(): String {
        if (apiKey.isEmpty()) throw BlabladorException(0, "No API key")
        val request = Request.Builder().url("https://codebase.helmholtz.cloud/api/v4/user").header("PRIVATE-TOKEN", apiKey).build()
        return json.parseToJsonElement(execute(request)).jsonObject["name"]!!.jsonPrimitive.content
    }

    /** Streams a chat completion. `messages` are OpenAI wire-format objects. */
    fun streamChat(model: String, messages: List<JsonObject>, tools: List<JsonObject> = emptyList()): Flow<StreamEvent> = flow {
        val body = buildJsonObject {
            put("model", model)
            put("messages", JsonArray(messages))
            put("stream", true)
            if (tools.isNotEmpty()) put("tools", JsonArray(tools))
        }
        val request = post("chat/completions", body).newBuilder().header("Accept", "text/event-stream").build()
        // Slow models can take minutes before the first token.
        val call = client.newBuilder().readTimeout(responseTimeoutMinutes.toLong(), TimeUnit.MINUTES).build().newCall(request)
        val response = call.await()
        try {
            if (!response.isSuccessful) throw BlabladorException(response.code, response.body?.string().orEmpty().take(500))
            val source = response.body!!.source()
            val toolCalls = sortedMapOf<Int, ToolCall>()
            while (true) {
                currentCoroutineContext().ensureActive()
                val line = source.readUtf8Line() ?: break
                if (!line.startsWith("data:")) continue
                val payload = line.removePrefix("data:").trim()
                if (payload == "[DONE]") break
                val delta = runCatching {
                    json.parseToJsonElement(payload).jsonObject["choices"]?.jsonArray?.firstOrNull()?.jsonObject?.get("delta")?.jsonObject
                }.getOrNull() ?: continue
                // Thinking trace: vLLM and DeepSeek send reasoning_content, others reasoning.
                (jsonString(delta["reasoning_content"]) ?: jsonString(delta["reasoning"]))?.takeIf { it.isNotEmpty() }
                    ?.let { emit(StreamEvent.Reasoning(it)) }
                delta["content"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }?.let { emit(StreamEvent.Content(it)) }
                (delta["tool_calls"] as? JsonArray)?.forEach { element ->
                    val callDelta = element.jsonObject
                    val index = callDelta["index"]?.jsonPrimitive?.intOrNull ?: 0
                    val current = toolCalls.getOrPut(index) { ToolCall() }
                    callDelta["id"]?.jsonPrimitive?.contentOrNull?.let { current.id = it }
                    val function = callDelta["function"] as? JsonObject
                    function?.get("name")?.jsonPrimitive?.contentOrNull?.let { current.name += it }
                    function?.get("arguments")?.jsonPrimitive?.contentOrNull?.let { current.arguments += it }
                }
            }
            if (toolCalls.isNotEmpty()) emit(StreamEvent.ToolCalls(toolCalls.values.toList()))
        } finally {
            response.close()
            call.cancel()
        }
    }.flowOn(Dispatchers.IO)

    suspend fun generateImage(model: String, prompt: String): ByteArray {
        val body = buildJsonObject {
            put("model", model); put("prompt", prompt); put("n", 1); put("size", "1024x1024")
        }
        return imageFrom(execute(post("images/generations", body)))
    }

    /** Makes a video with sound from a text prompt and returns the MP4. */
    suspend fun generateVideo(prompt: String, seconds: Int, aspect: String, firstFrame: ByteArray? = null): ByteArray {
        val (width, height) = when (aspect) { "9:16" -> 768 to 1344; "1:1" -> 768 to 768; else -> 1344 to 768 }
        val builder = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("model", VIDEO_MODEL)
            .addFormDataPart("prompt", prompt)
            .addFormDataPart("extra_params", "{\"duration\":$seconds}")
        // With a first frame, the clip opens on it and takes its shape from it.
        if (firstFrame == null) {
            builder.addFormDataPart("aspect_ratio", aspect).addFormDataPart("width", "$width").addFormDataPart("height", "$height")
        } else {
            val isPng = firstFrame.size > 4 && firstFrame[0] == 0x89.toByte() && firstFrame[1] == 0x50.toByte()
            builder.addFormDataPart("first_frame", if (isPng) "frame.png" else "frame.jpg",
                firstFrame.toRequestBody((if (isPng) "image/png" else "image/jpeg").toMediaType()))
        }
        val body = builder.build()
        val call = client.newBuilder().readTimeout(2, TimeUnit.HOURS).callTimeout(2, TimeUnit.HOURS).build()
            .newCall(request("videos/sync").post(body).build())
        return withContext(Dispatchers.IO) {
            call.await().use { response ->
                checkSize(response, MAX_VIDEO_BYTES)
                if (!response.isSuccessful) throw BlabladorException(response.code, response.body?.string().orEmpty().take(500))
                response.body?.bytes() ?: ByteArray(0)
            }
        }
    }

    suspend fun editImage(prompt: String, image: ByteArray): ByteArray {
        val isPng = image.size > 4 && image[0] == 0x89.toByte() && image[1] == 0x50.toByte()
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("model", IMAGE_EDIT_MODEL)
            .addFormDataPart("prompt", prompt)
            .addFormDataPart("image", if (isPng) "image.png" else "image.jpg",
                image.toRequestBody((if (isPng) "image/png" else "image/jpeg").toMediaType()))
            .build()
        return imageFrom(execute(request("images/edits").post(body).build()))
    }

    private fun imageFrom(body: String): ByteArray {
        val encoded = json.parseToJsonElement(body).jsonObject["data"]?.jsonArray?.firstOrNull()?.jsonObject
            ?.get("b64_json")?.jsonPrimitive?.contentOrNull ?: throw BlabladorException(200, "No image in response.")
        return Base64.decode(encoded, Base64.DEFAULT)
    }

    /** Reads a page image with LightOnOCR; returns Markdown (tables come back as HTML). */
    suspend fun ocr(jpeg: ByteArray): String {
        val image = "data:image/jpeg;base64," + Base64.encodeToString(jpeg, Base64.NO_WRAP)
        val body = buildJsonObject {
            put("model", OCR_MODEL)
            put("messages", buildJsonArray {
                add(buildJsonObject {
                    put("role", "user")
                    put("content", buildJsonArray {
                        add(buildJsonObject { put("type", "image_url"); put("image_url", buildJsonObject { put("url", image) }) })
                    })
                })
            })
            put("max_tokens", 4096)
            put("temperature", 0)
        }
        val response = json.parseToJsonElement(execute(post("chat/completions", body))).jsonObject
        return response["choices"]?.jsonArray?.firstOrNull()?.jsonObject?.get("message")?.jsonObject
            ?.get("content")?.jsonPrimitive?.contentOrNull.orEmpty()
    }
}

/** Returns one embedding per text, in order. */
suspend fun BlabladorApi.embeddings(texts: List<String>, model: String = BlabladorApi.EMBEDDING_MODEL): List<FloatArray> {
    val body = buildJsonObject {
        put("model", model)
        put("input", buildJsonArray { texts.forEach { add(JsonPrimitive(it)) } })
    }
    val data = BlabladorApi.json.parseToJsonElement(postJson("embeddings", body, 45)).jsonObject["data"]!!.jsonArray
    return data.map { it.jsonObject }
        .sortedBy { it["index"]?.jsonPrimitive?.intOrNull ?: 0 }
        .map { item -> item["embedding"]!!.jsonArray.map { it.jsonPrimitive.content.toFloat() }.toFloatArray() }
}

/** Returns document indices, most relevant first. */
suspend fun BlabladorApi.rerank(query: String, documents: List<String>): List<Int> {
    val body = buildJsonObject {
        put("model", BlabladorApi.RERANK_MODEL)
        put("query", query)
        put("documents", buildJsonArray { documents.forEach { add(JsonPrimitive(it)) } })
    }
    val results = BlabladorApi.json.parseToJsonElement(postJson("rerank", body, 60)).jsonObject["results"]!!.jsonArray
    return results.map { it.jsonObject }
        .sortedByDescending { it["relevance_score"]?.jsonPrimitive?.content?.toDoubleOrNull() ?: 0.0 }
        .map { it["index"]!!.jsonPrimitive.content.toInt() }
}

/** Speaks [text] with Drama 3, with a built-in voice or cloned from a reference recording. Returns MP3 audio. */
suspend fun BlabladorApi.speech(text: String, voice: Voice, sample: ByteArray?): ByteArray {
    val body = buildJsonObject {
        put("model", BlabladorApi.SPEECH_MODEL)
        put("input", text)
        put("response_format", "mp3")
        if (voice.referenceId != null) put("voice", voice.referenceId)
        else if (sample != null) put("references", buildJsonArray {
            add(buildJsonObject {
                put("audio_path", "data:audio/wav;base64," + Base64.encodeToString(sample, Base64.NO_WRAP))
                put("text", voice.transcript)
            })
        })
    }
    return postBytes("audio/speech", body, 300)
}

/** Transcribes a WAV file with Whisper; used for the transcript voice cloning needs. */
suspend fun BlabladorApi.transcribe(wav: ByteArray): String {
    val body = MultipartBody.Builder().setType(MultipartBody.FORM)
        .addFormDataPart("model", BlabladorApi.TRANSCRIPTION_MODEL)
        .addFormDataPart("file", "sample.wav", wav.toRequestBody("audio/wav".toMediaType()))
        .build()
    val response = send(authorized("audio/transcriptions").post(body).build(), 300)
    return BlabladorApi.json.parseToJsonElement(response.decodeToString()).jsonObject["text"]?.jsonPrimitive?.content.orEmpty().trim()
}

/** Asks the Clef decision model typed questions about a state; returns answers by question id. */
suspend fun BlabladorApi.decide(state: String, questions: List<DecisionQuestion>): Map<String, DecisionAnswer> {
    val body = buildJsonObject {
        put("model", BlabladorApi.DECISION_MODEL)
        put("state", state)
        put("questions", buildJsonObject { questions.forEach { put(it.id, it.wire) } })
    }
    val answers = BlabladorApi.json.parseToJsonElement(postJson("systemone", body, 60)).jsonObject["answers"]!!.jsonObject
    return answers.mapValues { BlabladorApi.json.decodeFromJsonElement(DecisionAnswer.serializer(), it.value) }
}

/** Suspends until OkHttp has the response headers; cancelling the coroutine cancels the call. */
suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) = continuation.resume(response)
        override fun onFailure(call: Call, e: IOException) {
            if (!continuation.isCancelled) continuation.resumeWithException(e)
        }
    })
    continuation.invokeOnCancellation { cancel() }
}

fun jsonString(element: JsonElement?): String? = (element as? JsonPrimitive)?.contentOrNull

/** One reply without tools, as plain text with any `<think>` block removed. */
suspend fun BlabladorApi.complete(model: String, system: String, user: String): String {
    val text = StringBuilder()
    streamChat(model, listOf(
        kotlinx.serialization.json.buildJsonObject { put("role", "system"); put("content", system) },
        kotlinx.serialization.json.buildJsonObject { put("role", "user"); put("content", user) },
    )).collect { if (it is BlabladorApi.StreamEvent.Content) text.append(it.text) }
    return text.toString().substringAfterLast("</think>").trim()
}
