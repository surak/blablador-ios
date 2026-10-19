package de.fz_juelich.blablador

import android.app.Application
import android.net.Uri
import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import de.fz_juelich.blablador.data.BlabladorApi
import de.fz_juelich.blablador.data.BlabladorException
import de.fz_juelich.blablador.data.ChatMessage
import de.fz_juelich.blablador.data.ChatRole
import de.fz_juelich.blablador.data.Conversation
import de.fz_juelich.blablador.data.ConversationStore
import de.fz_juelich.blablador.data.DocumentAttachment
import de.fz_juelich.blablador.data.ImageStore
import de.fz_juelich.blablador.data.PdfExtractor
import de.fz_juelich.blablador.data.RemoteModel
import de.fz_juelich.blablador.data.SearchResult
import de.fz_juelich.blablador.data.Settings
import de.fz_juelich.blablador.data.Tools
import de.fz_juelich.blablador.data.WebSearch
import de.fz_juelich.blablador.data.jsonString
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.text.DateFormat
import java.util.Date

class ChatViewModel(application: Application) : AndroidViewModel(application) {
    val settings = Settings(application)
    val images = ImageStore(application)
    private val conversationStore = ConversationStore(application)
    private val pdf = PdfExtractor(application, settings)

    val conversations = mutableStateListOf<Conversation>().apply { addAll(conversationStore.load()) }
    var currentId by mutableStateOf<String?>(null)
        private set
    var models by mutableStateOf<List<RemoteModel>>(emptyList())
        private set
    var modelsError by mutableStateOf<String?>(null)
        private set
    var isStreaming by mutableStateOf(false)
        private set

    var apiKey by mutableStateOf(settings.apiKey)
        private set
    var selectedModel by mutableStateOf(settings.selectedModel)
        private set
    var imageModel by mutableStateOf(settings.imageModel)
        private set
    var userName by mutableStateOf(settings.userName)
        private set
    var webSearchEnabled by mutableStateOf(settings.webSearchEnabled)
        private set
    var imageToolsEnabled by mutableStateOf(settings.imageToolsEnabled)
        private set
    var systemPrompt by mutableStateOf(settings.systemPrompt)
        private set
    var ocrEngine by mutableStateOf(settings.ocrEngine)
        private set

    private var streamJob: Job? = null
    private val maxToolRounds = 4

    val api get() = BlabladorApi(apiKey)
    val current get() = conversations.firstOrNull { it.id == currentId }

    val chatModels get() = models.filter { it.isChatCapable }.sortedBy { it.displayName.lowercase() }
    val selectedModelName get() = RemoteModel(selectedModel).displayName
    val imageModelName get() = BlabladorApi.IMAGE_MODELS.firstOrNull { it.first == imageModel }?.second ?: imageModel

    init {
        refresh()
    }

    // MARK: Settings

    fun updateApiKey(key: String) {
        val trimmed = key.trim()
        if (trimmed == apiKey) return
        apiKey = trimmed
        settings.apiKey = trimmed
        userName = ""
        settings.userName = ""
        refresh()
    }

    fun selectModel(id: String) { selectedModel = id; settings.selectedModel = id }
    fun selectImageModel(id: String) { imageModel = id; settings.imageModel = id }
    fun setWebSearch(on: Boolean) { webSearchEnabled = on; settings.webSearchEnabled = on }
    fun setImageTools(on: Boolean) { imageToolsEnabled = on; settings.imageToolsEnabled = on }
    fun updateSystemPrompt(text: String) { systemPrompt = text; settings.systemPrompt = text }
    fun chooseOcrEngine(engine: String) { ocrEngine = engine; settings.ocrEngine = engine }

    private fun refresh() {
        viewModelScope.launch {
            if (apiKey.isEmpty()) {
                models = emptyList()
                return@launch
            }
            runCatching { api.models() }
                .onSuccess { models = it; modelsError = null }
                .onFailure { modelsError = it.message }
            runCatching { api.userName() }.onSuccess {
                userName = it.trim()
                settings.userName = userName
            }
        }
    }

    // MARK: Conversations

    fun newChat() {
        stop()
        currentId = null
    }

    fun select(conversation: Conversation) {
        stop()
        currentId = conversation.id
        selectModel(conversation.model)
    }

    fun delete(conversation: Conversation) {
        if (conversation.id == currentId) newChat()
        images.delete(conversation.messages.flatMap { it.images })
        conversations.removeAll { it.id == conversation.id }
        persist()
    }

    fun deleteAll() {
        newChat()
        images.delete(conversations.flatMap { c -> c.messages.flatMap { it.images } })
        conversations.clear()
        persist()
    }

    // MARK: Attachments

    suspend fun readPdf(uri: Uri): DocumentAttachment = pdf.extract(uri, api)

    suspend fun readPhotoText(data: ByteArray, name: String): DocumentAttachment = pdf.extractPhoto(data, name, api)

    // MARK: Messaging

    /** Sends a chat message. With [createImage], the text is used directly as an image prompt. */
    fun send(text: String, attachments: List<ByteArray> = emptyList(), documents: List<DocumentAttachment> = emptyList(), createImage: Boolean = false) {
        val trimmed = text.trim()
        if ((trimmed.isEmpty() && attachments.isEmpty() && documents.isEmpty()) || isStreaming) return

        if (currentId == null) {
            val title = when {
                trimmed.isNotEmpty() -> title(trimmed)
                documents.isNotEmpty() -> documents.first().name
                else -> "Image"
            }
            val conversation = Conversation(title = title, model = selectedModel)
            conversations.add(0, conversation)
            currentId = conversation.id
        }
        val names = attachments.map(images::save)
        update { it.copy(messages = it.messages + ChatMessage(role = ChatRole.user, content = trimmed, images = names, documents = documents)) }

        if (createImage) makeImage(trimmed, names.lastOrNull()) else respond()
    }

    fun regenerate() {
        if (isStreaming) return
        update { conversation ->
            if (conversation.messages.lastOrNull()?.role == ChatRole.assistant) conversation.copy(messages = conversation.messages.dropLast(1))
            else conversation
        }
        respond()
    }

    fun stop() {
        streamJob?.cancel()
        streamJob = null
        isStreaming = false
    }

    private fun makeImage(prompt: String, source: String?) {
        val reply = ChatMessage(role = ChatRole.assistant, content = "")
        update { it.copy(messages = it.messages + reply) }
        isStreaming = true
        streamJob = viewModelScope.launch {
            try {
                val image = runImageTool(if (source == null) "generate_image" else "edit_image", prompt.ifEmpty { "Improve this image" }, source, reply.id)
                updateMessage(reply.id) { it.copy(images = it.images + image) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                updateMessage(reply.id) { it.copy(content = e.message ?: "Image failed.", isError = true) }
            } finally {
                updateMessage(reply.id) { it.copy(status = null) }
                isStreaming = false
                persist()
            }
        }
    }

    /** Runs an image tool and returns the stored file name. */
    private suspend fun runImageTool(name: String, prompt: String, source: String?, replyId: String): String {
        val data = if (name == "edit_image") {
            val original = source?.let(images::data) ?: throw BlabladorException(400, "There is no image to edit.")
            updateMessage(replyId) { it.copy(status = "Editing image with Qwen-Image…") }
            api.editImage(prompt, withContext(Dispatchers.Default) { ImageStore.jpeg(original, 1024) } ?: original)
        } else {
            updateMessage(replyId) { it.copy(status = "Creating image with $imageModelName…") }
            api.generateImage(imageModel, prompt)
        }
        return images.save(data)
    }

    private val latestImage get() = current?.messages?.lastOrNull { it.images.isNotEmpty() }?.images?.lastOrNull()

    private fun respond() {
        val conversation = current ?: return
        var system = systemPrompt
        system += "\n\nToday is ${DateFormat.getDateInstance(DateFormat.FULL).format(Date())}."
        if (webSearchEnabled) {
            system += " You can use the web_search tool for current or uncertain information. Cite sources inline as [1], [2] matching the search results."
        }
        if (imageToolsEnabled) {
            system += " You can create images with generate_image and modify the latest image in the chat with edit_image. Never describe an image as created unless the tool succeeded."
        }
        val wire = buildList {
            add(buildJsonObject { put("role", "system"); put("content", system.trim()) })
            conversation.messages.filter { !it.isError }.forEach { add(wireMessage(it)) }
        }

        val reply = ChatMessage(role = ChatRole.assistant, content = "")
        val model = selectedModel
        update { it.copy(model = model, messages = it.messages + reply) }

        val tools = buildList {
            if (webSearchEnabled) add(Tools.webSearch)
            if (imageToolsEnabled) { add(Tools.generateImage); add(Tools.editImage) }
        }
        isStreaming = true
        streamJob = viewModelScope.launch {
            try {
                runTurn(model, wire, tools, reply.id)
            } catch (e: CancellationException) {
                throw e
            } catch (e: BlabladorException) {
                val message = if (e.status == 400 && e.body.contains("image", ignoreCase = true))
                    "${RemoteModel(model).displayName} can't read images. Pick a vision model such as DeepSeek-V4.1-Flash or Qwen3.8-27B."
                else e.message
                updateMessage(reply.id) { it.copy(content = message ?: "Request failed.", isError = true) }
            } catch (e: Exception) {
                updateMessage(reply.id) { it.copy(content = e.message ?: "Request failed.", isError = true) }
            } finally {
                updateMessage(reply.id) {
                    val empty = it.content.isEmpty() && it.images.isEmpty() && isActive
                    if (empty) it.copy(status = null, content = "No response from the model.", isError = true) else it.copy(status = null)
                }
                isStreaming = false
                persist()
            }
        }
    }

    /** Streams the reply, running tools whenever the model asks for them. */
    private suspend fun runTurn(model: String, initial: List<JsonObject>, initialTools: List<JsonObject>, replyId: String) {
        val messages = initial.toMutableList()
        var tools = initialTools

        for (round in 0..maxToolRounds) {
            val isFinalRound = round == maxToolRounds
            if (isFinalRound) {
                messages += buildJsonObject { put("role", "user"); put("content", "Stop using tools now and write the final answer using the results above.") }
            }
            val prefix = message(replyId)?.content.orEmpty()
            var text = ""
            var calls: List<BlabladorApi.ToolCall> = emptyList()
            try {
                api.streamChat(model, messages, tools).collect { event ->
                    when (event) {
                        is BlabladorApi.StreamEvent.Content -> {
                            text += event.text
                            val visible = stripToolMarkup(text)
                            updateMessage(replyId) { it.copy(status = null, content = prefix + visible) }
                        }
                        is BlabladorApi.StreamEvent.ToolCalls -> calls = event.calls
                    }
                }
            } catch (e: BlabladorException) {
                // Model without tool support: answer without tools.
                if (e.status == 400 && tools.isNotEmpty() && round == 0 && !e.body.contains("image", ignoreCase = true)) {
                    tools = emptyList()
                    continue
                }
                throw e
            }

            if (isFinalRound || (calls.isEmpty() && containsToolMarkup(text))) {
                if (stripToolMarkup(text).isEmpty()) updateMessage(replyId) { it.copy(content = prefix) }
                return
            }
            if (calls.isEmpty()) return

            messages += buildJsonObject {
                put("role", "assistant")
                put("tool_calls", buildJsonArray { calls.forEach { add(it.wire) } })
                put("content", if (text.isEmpty()) JsonNull else JsonPrimitive(text))
            }
            // Preambles like "Let me look that up" are status, not part of the answer.
            updateMessage(replyId) { it.copy(content = prefix) }

            for (call in calls) {
                val arguments = runCatching { BlabladorApi.json.parseToJsonElement(call.arguments).jsonObject }.getOrNull()
                val query = jsonString(arguments?.get("query")).orEmpty()
                val prompt = jsonString(arguments?.get("prompt")).orEmpty()
                val output = when {
                    (call.name == "generate_image" || call.name == "edit_image") && prompt.isNotEmpty() -> try {
                        val image = runImageTool(call.name, prompt, latestImage, replyId)
                        updateMessage(replyId) { it.copy(images = it.images + image) }
                        "The image was created and is shown to the user. Do not include it or a link in your answer; just briefly comment on it."
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        "Image tool failed: ${e.message}"
                    }
                    call.name == "web_search" && query.isNotEmpty() -> {
                        updateMessage(replyId) { it.copy(status = "Searching “$query”") }
                        try {
                            val results = WebSearch.search(query, jsonString(arguments?.get("category")), jsonString(arguments?.get("time_range")))
                            val numbered = mutableListOf<Pair<Int, SearchResult>>()
                            updateMessage(replyId) { message ->
                                val sources = message.sources.toMutableList()
                                for (result in results) {
                                    val index = sources.indexOfFirst { it.url == result.url }
                                    if (index >= 0) numbered += (index + 1) to result
                                    else { sources += result; numbered += sources.size to result }
                                }
                                message.copy(sources = sources)
                            }
                            WebSearch.toolOutput(query, numbered)
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            "Search failed: ${e.message}"
                        }
                    }
                    else -> "Unknown tool ${call.name}."
                }
                messages += buildJsonObject { put("role", "tool"); put("tool_call_id", call.id); put("content", output) }
            }
            updateMessage(replyId) { it.copy(status = "Thinking…") }
        }
    }

    /** User attachments are sent as base64 images and document text; generated images are only mentioned. */
    private fun wireMessage(message: ChatMessage): JsonObject {
        var text = message.content
        if (message.documents.isNotEmpty()) {
            val documents = message.documents.map { "<document name=\"${it.name}\">\n${it.text}\n</document>" }
            text = (documents + text).filter { it.isNotEmpty() }.joinToString("\n\n")
        }
        if (message.role != ChatRole.user || message.images.isEmpty()) {
            if (message.role == ChatRole.assistant && message.images.isNotEmpty()) text = "[Generated image]\n$text"
            return buildJsonObject { put("role", message.role.name); put("content", text) }
        }
        return buildJsonObject {
            put("role", "user")
            put("content", buildJsonArray {
                if (text.isNotEmpty()) add(buildJsonObject { put("type", "text"); put("text", text) })
                for (name in message.images) {
                    val data = images.data(name) ?: continue
                    val jpeg = ImageStore.jpeg(data) ?: continue
                    add(buildJsonObject {
                        put("type", "image_url")
                        put("image_url", buildJsonObject { put("url", "data:image/jpeg;base64," + Base64.encodeToString(jpeg, Base64.NO_WRAP)) })
                    })
                }
            })
        }
    }

    private val toolMarkup = Regex("""<[｜|]\s*DSML\s*[｜|][\s\S]*$""")
    private fun containsToolMarkup(text: String) = toolMarkup.containsMatchIn(text)
    /** Removes raw tool-call markup some models emit as text instead of structured tool calls. */
    private fun stripToolMarkup(text: String) = text.replace(toolMarkup, "").trim()

    private fun message(id: String) = conversations.firstNotNullOfOrNull { c -> c.messages.firstOrNull { it.id == id } }

    private fun update(change: (Conversation) -> Conversation) {
        val index = conversations.indexOfFirst { it.id == currentId }
        if (index < 0) return
        conversations[index] = change(conversations[index]).copy(updatedAt = System.currentTimeMillis())
        persist()
    }

    private fun updateMessage(id: String, change: (ChatMessage) -> ChatMessage) {
        val index = conversations.indexOfFirst { c -> c.messages.any { it.id == id } }
        if (index < 0) return
        val conversation = conversations[index]
        conversations[index] = conversation.copy(messages = conversation.messages.map { if (it.id == id) change(it) else it })
    }

    /** Saves one at a time so an older snapshot can't overwrite a newer one. */
    private val saveDispatcher = Dispatchers.IO.limitedParallelism(1)

    private fun persist() {
        val snapshot = conversations.toList()
        viewModelScope.launch(saveDispatcher) { conversationStore.save(snapshot) }
    }

    private fun title(text: String): String {
        val first = text.lineSequence().first()
        return if (first.length > 40) first.take(40) + "…" else first
    }
}
