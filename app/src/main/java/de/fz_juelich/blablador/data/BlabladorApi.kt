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
        const val BASE_URL = "https://api.blablador.fz-juelich.de/v1"
        const val DEFAULT_MODEL = "deepseek-v4.1-flash-at-hzdr"
        const val IMAGE_EDIT_MODEL = "alias-image"
        const val DEFAULT_IMAGE_MODEL = "alias-flux2"
        const val OCR_MODEL = "alias-ocr"
        val IMAGE_MODELS = listOf("alias-flux2" to "FLUX.2-dev", "alias-image" to "Qwen-Image 2.1")

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

    private fun request(path: String): Request.Builder {
        if (apiKey.isEmpty()) throw BlabladorException(0, "No API key set. Add your Blablador API key in Settings.")
        return Request.Builder().url("$BASE_URL/$path").header("Authorization", "Bearer $apiKey")
    }

    private suspend fun execute(request: Request): String = withContext(Dispatchers.IO) {
        client.newCall(request).await().use { response ->
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
        val call = client.newCall(request)
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
