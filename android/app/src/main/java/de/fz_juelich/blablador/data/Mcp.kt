package de.fz_juelich.blablador.data

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/** A Model Context Protocol server reached over HTTP ("Streamable HTTP" transport). */
@Serializable
data class McpServer(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val url: String,
    /** Sent as "Authorization: Bearer …" when set. */
    val token: String = "",
    val enabled: Boolean = true,
    /** Ask before each tool call; "Allow for this chat" skips it until the app restarts. */
    val askBeforeCalls: Boolean = true,
) {
    /** Prefix of this server's tool names as the model sees them, e.g. "gitlab". */
    val slug: String
        get() = name.lowercase().map { if (it in 'a'..'z' || it in '0'..'9') it else '_' }.joinToString("")
            .split('_').filter { it.isNotEmpty() }.joinToString("_").take(20).ifEmpty { "mcp" }
}

data class McpTool(
    val server: String,
    /** The tool's own name on its server. */
    val name: String,
    /** The name the model sees: "<server>__<tool>", at most 64 characters. */
    val qualifiedName: String,
    val description: String,
    val schema: JsonObject,
) {
    val definition: JsonObject
        get() = buildJsonObject {
            put("type", "function")
            put("function", buildJsonObject {
                put("name", qualifiedName)
                put("description", description)
                put("parameters", schema)
            })
        }
}

class McpException(message: String) : Exception(message)

/** JSON-RPC over HTTP POST; answers come as JSON or as a server-sent event stream. */
class McpClient(private val server: McpServer) {
    private var sessionId: String? = null
    private var initialized = false
    private var nextId = 1
    private val lock = Mutex()
    private val http = BlabladorApi.client.newBuilder().readTimeout(120, TimeUnit.SECONDS).callTimeout(180, TimeUnit.SECONDS).build()

    suspend fun listTools(): List<McpTool> = lock.withLock {
        initializeIfNeeded()
        val tools = mutableListOf<McpTool>()
        var cursor: String? = null
        do {
            val result = call("tools/list", buildJsonObject { cursor?.let { put("cursor", it) } })
            for (item in (result["tools"] as? JsonArray).orEmpty()) {
                val tool = item as? JsonObject ?: continue
                val name = tool["name"]?.jsonPrimitive?.contentOrNull ?: continue
                val qualified = (server.slug + "__" + name).map { if (it.isLetterOrDigit() && it.code < 128 || it == '_' || it == '-') it else '_' }
                    .joinToString("").take(64)
                val schema = tool["inputSchema"] as? JsonObject ?: buildJsonObject { put("type", "object"); put("properties", buildJsonObject {}) }
                val description = "[${server.name}] " + (tool["description"]?.jsonPrimitive?.contentOrNull ?: tool["title"]?.jsonPrimitive?.contentOrNull ?: name)
                tools += McpTool(server.id, name, qualified, description.take(1_000), schema)
            }
            cursor = result["nextCursor"]?.jsonPrimitive?.contentOrNull
        } while (cursor != null && tools.size < 500)
        tools
    }

    /** Runs a tool and returns its text output and whether the tool reported a failure. */
    suspend fun callTool(name: String, arguments: JsonObject): Pair<String, Boolean> = lock.withLock {
        initializeIfNeeded()
        val result = call("tools/call", buildJsonObject { put("name", name); put("arguments", arguments) })
        val parts = mutableListOf<String>()
        for (item in (result["content"] as? JsonArray).orEmpty()) {
            val part = item as? JsonObject ?: continue
            when (val type = part["type"]?.jsonPrimitive?.contentOrNull) {
                "text" -> parts += part["text"]?.jsonPrimitive?.contentOrNull.orEmpty()
                "resource" -> {
                    val resource = part["resource"] as? JsonObject
                    parts += resource?.get("text")?.jsonPrimitive?.contentOrNull ?: "[Resource ${resource?.get("uri")?.jsonPrimitive?.contentOrNull.orEmpty()}]"
                }
                "resource_link" -> parts += "[Link: ${part["uri"]?.jsonPrimitive?.contentOrNull.orEmpty()}]"
                null -> {}
                else -> parts += "[$type content not shown]"
            }
        }
        if (parts.isEmpty()) result["structuredContent"]?.let { parts += it.toString() }
        parts.joinToString("\n\n") to ((result["isError"] as? JsonPrimitive)?.booleanOrNull ?: false)
    }

    private suspend fun initializeIfNeeded() {
        if (initialized) return
        call("initialize", buildJsonObject {
            put("protocolVersion", "2025-06-18")
            put("capabilities", buildJsonObject {})
            put("clientInfo", buildJsonObject { put("name", "Blablador"); put("version", "3") })
        })
        send(buildJsonObject { put("jsonrpc", "2.0"); put("method", "notifications/initialized") }, expectsAnswer = false)
        initialized = true
    }

    private suspend fun call(method: String, params: JsonObject): JsonObject {
        val id = nextId++
        val answer = send(buildJsonObject { put("jsonrpc", "2.0"); put("id", id); put("method", method); put("params", params) }, expectsAnswer = true)
            ?: throw McpException("The server sent no answer.")
        (answer["error"] as? JsonObject)?.let { throw McpException(it["message"]?.jsonPrimitive?.contentOrNull ?: "The server reported an error.") }
        return answer["result"] as? JsonObject ?: JsonObject(emptyMap())
    }

    private suspend fun send(message: JsonObject, expectsAnswer: Boolean): JsonObject? = withContext(Dispatchers.IO) {
        val url = server.url.trim().toHttpUrlOrNull()
        if (url == null || !(url.scheme == "https" || (url.scheme == "http" && url.host in setOf("localhost", "127.0.0.1")))) {
            throw McpException("The server address must start with https://.")
        }
        val request = Request.Builder().url(url)
            .header("Accept", "application/json, text/event-stream")
            .header("MCP-Protocol-Version", "2025-06-18")
            .apply {
                if (server.token.isNotEmpty()) header("Authorization", "Bearer ${server.token}")
                sessionId?.let { header("Mcp-Session-Id", it) }
            }
            .post(message.toString().toRequestBody("application/json".toMediaType()))
            .build()
        http.newCall(request).await().use { response ->
            response.header("Mcp-Session-Id")?.let { sessionId = it }
            if (!response.isSuccessful) {
                if (response.code == 404 && sessionId != null) { sessionId = null; initialized = false }
                throw McpException("The server answered ${response.code}. ${response.body?.string().orEmpty().take(200)}")
            }
            if (!expectsAnswer) return@use null
            val id = (message["id"] as? JsonPrimitive)?.intOrNull
            val body = response.body ?: return@use null
            if (response.header("Content-Type").orEmpty().contains("text/event-stream")) {
                // Read events until the one answering this request.
                val source = body.source()
                val data = StringBuilder()
                while (true) {
                    val line = source.readUtf8Line() ?: break
                    if (line.startsWith("data:")) {
                        data.append(line.removePrefix("data:").trim())
                        val parsed = runCatching { BlabladorApi.json.parseToJsonElement(data.toString()).jsonObject }.getOrNull()
                        if (parsed != null) {
                            data.clear()
                            if ((parsed["id"] as? JsonPrimitive)?.intOrNull == id) return@use parsed
                        }
                    } else if (line.isEmpty()) data.clear()
                }
                return@use null
            }
            when (val element: JsonElement = BlabladorApi.json.parseToJsonElement(body.string())) {
                is JsonObject -> element
                // Some servers answer a single request with a one-element batch.
                is JsonArray -> element.firstOrNull()?.jsonObject
                else -> null
            }
        }
    }
}

/** The user's MCP servers, saved encrypted (tokens included), and the tools they offer. */
class McpLibrary(private val context: Context) {
    private val file = File(context.filesDir, "mcp.json")
    private val serializer = ListSerializer(McpServer.serializer())
    private val clients = mutableMapOf<String, McpClient>()

    val servers = mutableStateListOf<McpServer>().apply {
        addAll(runCatching { BlabladorApi.json.decodeFromString(serializer, EncryptedStorage.read(context, file)!!) }.getOrDefault(emptyList()))
    }
    /** Tools per server, loaded on first use and after edits. */
    val tools = mutableStateMapOf<String, List<McpTool>>()
    val errors = mutableStateMapOf<String, String>()
    val loading = mutableStateMapOf<String, Boolean>()

    fun server(id: String) = servers.firstOrNull { it.id == id }

    fun save(server: McpServer) {
        val index = servers.indexOfFirst { it.id == server.id }
        if (index >= 0) servers[index] = server else servers += server
        clients.remove(server.id); tools.remove(server.id); errors.remove(server.id)
        persist()
    }

    fun delete(server: McpServer) {
        servers.removeAll { it.id == server.id }
        clients.remove(server.id); tools.remove(server.id); errors.remove(server.id)
        persist()
    }

    /** Connects and lists the server's tools. */
    suspend fun load(server: McpServer) {
        if (!server.enabled) return
        loading[server.id] = true
        try {
            tools[server.id] = client(server).listTools()
            errors.remove(server.id)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            tools[server.id] = emptyList()
            errors[server.id] = e.message ?: "Could not connect."
        } finally {
            loading.remove(server.id)
        }
    }

    /** Tools of all enabled servers, loading any not loaded yet. */
    suspend fun availableTools(): List<McpTool> {
        val enabled = servers.filter { it.enabled }
        coroutineScope { enabled.filter { tools[it.id] == null }.map { async { load(it) } }.awaitAll() }
        return enabled.flatMap { tools[it.id].orEmpty() }
    }

    suspend fun call(tool: McpTool, arguments: JsonObject): Pair<String, Boolean> {
        val server = server(tool.server) ?: throw McpException("This server was removed.")
        return client(server).callTool(tool.name, arguments)
    }

    private fun client(server: McpServer) = clients.getOrPut(server.id) { McpClient(server) }

    private fun persist() = EncryptedStorage.write(context, file, BlabladorApi.json.encodeToString(serializer, servers.toList()))
}
