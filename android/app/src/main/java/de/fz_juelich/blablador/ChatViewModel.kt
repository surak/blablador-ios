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
import de.fz_juelich.blablador.data.AudioPlayback
import de.fz_juelich.blablador.data.AudioStore
import de.fz_juelich.blablador.data.VideoStore
import de.fz_juelich.blablador.data.BlabladorApi
import de.fz_juelich.blablador.data.BlabladorException
import de.fz_juelich.blablador.data.ChatMessage
import de.fz_juelich.blablador.data.ChatRole
import de.fz_juelich.blablador.data.Conversation
import de.fz_juelich.blablador.data.ConversationStore
import de.fz_juelich.blablador.data.DocumentAttachment
import de.fz_juelich.blablador.data.ImageStore
import de.fz_juelich.blablador.data.EncryptedStorage
import de.fz_juelich.blablador.data.KnowledgeLibrary
import de.fz_juelich.blablador.data.ChatSearch
import de.fz_juelich.blablador.data.PythonRunner
import de.fz_juelich.blablador.data.complete
import de.fz_juelich.blablador.data.McpLibrary
import de.fz_juelich.blablador.data.McpTool
import de.fz_juelich.blablador.data.MemoryStore
import de.fz_juelich.blablador.data.WebPage
import de.fz_juelich.blablador.data.Skill
import de.fz_juelich.blablador.data.SkillLibrary
import de.fz_juelich.blablador.data.PdfExtractor
import de.fz_juelich.blablador.data.RemoteModel
import de.fz_juelich.blablador.data.SearchResult
import de.fz_juelich.blablador.data.Settings
import de.fz_juelich.blablador.data.Tools
import de.fz_juelich.blablador.data.VoiceLibrary
import de.fz_juelich.blablador.data.WebSearch
import de.fz_juelich.blablador.data.jsonString
import de.fz_juelich.blablador.data.speech
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

private const val CONTINUE_PROMPT = "Continue the scene naturally, with matching sound."

class ChatViewModel(application: Application) : AndroidViewModel(application) {
    val settings = Settings(application)
    val images = ImageStore(application)
    private val conversationStore = ConversationStore(application)
    private val pdf = PdfExtractor(application, settings)
    val knowledge = KnowledgeLibrary(application, viewModelScope, pdf)
    val voices = VoiceLibrary(application)
    val memory = MemoryStore(application)
    val skills = SkillLibrary(application)
    val mcp = McpLibrary(application)
    val audio = AudioStore(application)
    val videos = VideoStore(application)
    val playback = AudioPlayback()

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
    var responseTimeoutMinutes by mutableStateOf(settings.responseTimeoutMinutes.also { BlabladorApi.responseTimeoutMinutes = it })
        private set
    var imageToolsEnabled by mutableStateOf(settings.imageToolsEnabled)
        private set
    var systemPrompt by mutableStateOf(settings.systemPrompt)
        private set
    var ocrEngine by mutableStateOf(settings.ocrEngine)
        private set

    private var streamJob: Job? = null
    private val maxToolRounds = 4
    /** Above this many characters (about 30,000 tokens) older messages are replaced by a summary. */
    private val compactionThreshold = 120_000
    /** Messages always sent in full. */
    private val recentMessages = 8

    val api get() = BlabladorApi(apiKey)
    val current get() = conversations.firstOrNull { it.id == currentId }

    val chatModels get() = models.filter { it.isChatCapable }.sortedBy { it.displayName.lowercase() }
    val selectedModelName get() = RemoteModel(selectedModel).displayName
    val imageModelName get() = BlabladorApi.IMAGE_MODELS.firstOrNull { it.first == imageModel }?.second ?: imageModel

    init {
        refresh()
        EncryptedStorage.removeDecryptedCopies(application)
        viewModelScope.launch(Dispatchers.IO) { EncryptedStorage.encryptOldFiles(application) }
    }

    // MARK: Settings

    var endpoint by mutableStateOf(settings.endpoint.also { BlabladorApi.endpoint = it })
        private set

    fun updateConnection(key: String, newEndpoint: String) {
        val url = newEndpoint.trim().ifEmpty { BlabladorApi.DEFAULT_ENDPOINT }
        if (url != endpoint) {
            endpoint = url; settings.endpoint = url; BlabladorApi.endpoint = url
            if (key.trim() == apiKey) { refresh(); return }
        }
        updateApiKey(key)
    }

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
    var videoSeconds by mutableStateOf(settings.videoSeconds)
        private set
    var videoAspect by mutableStateOf(settings.videoAspect)
        private set
    val videoAspectName get() = BlabladorApi.VIDEO_ASPECTS.firstOrNull { it.first == videoAspect }?.second ?: videoAspect
    fun chooseVideoSeconds(seconds: Int) { videoSeconds = seconds; settings.videoSeconds = seconds }
    fun chooseVideoAspect(aspect: String) { videoAspect = aspect; settings.videoAspect = aspect }

    fun selectImageModel(id: String) { imageModel = id; settings.imageModel = id }
    fun setResponseTimeout(minutes: Int) {
        responseTimeoutMinutes = minutes; settings.responseTimeoutMinutes = minutes; BlabladorApi.responseTimeoutMinutes = minutes
    }

    fun setWebSearch(on: Boolean) { webSearchEnabled = on; settings.webSearchEnabled = on }

    var pythonEnabled by mutableStateOf(settings.pythonEnabled)
        private set
    fun setPython(on: Boolean) { pythonEnabled = on; settings.pythonEnabled = on }
    private val python by lazy { PythonRunner(getApplication()) }
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
            // The name comes from Helmholtz Codebase; only Blablador keys belong there.
            if (endpoint == BlabladorApi.DEFAULT_ENDPOINT) runCatching { api.userName() }.onSuccess {
                userName = it.trim()
                settings.userName = userName
            }
        }
    }

    // MARK: Knowledge

    /** Knowledge bases picked before the first message of a new chat. */
    private var pendingKnowledge by mutableStateOf<List<String>>(emptyList())

    /** Knowledge bases searched for the current chat. */
    val activeKnowledge: List<String>
        get() = (if (currentId == null) pendingKnowledge else current?.knowledge.orEmpty()).filter { knowledge.base(it) != null }

    fun toggleKnowledge(id: String) {
        val ids = if (id in activeKnowledge) activeKnowledge - id else activeKnowledge + id
        if (currentId == null) pendingKnowledge = ids else update { it.copy(knowledge = ids) }
    }

    // MARK: Conversations

    fun newChat() {
        stop()
        currentId = null
        pendingKnowledge = emptyList()
    }

    fun select(conversation: Conversation) {
        stop()
        currentId = conversation.id
        selectModel(conversation.model)
    }

    fun delete(conversation: Conversation) {
        if (conversation.id == currentId) newChat()
        images.delete(conversation.messages.flatMap { it.images })
        audio.delete(conversation.messages.flatMap { it.audio })
        videos.delete(conversation.messages.flatMap { it.videos })
        conversations.removeAll { it.id == conversation.id }
        persist()
    }

    fun deleteAll() {
        newChat()
        images.delete(conversations.flatMap { c -> c.messages.flatMap { it.images } })
        audio.delete(conversations.flatMap { c -> c.messages.flatMap { it.audio } })
        videos.delete(conversations.flatMap { c -> c.messages.flatMap { it.videos } })
        conversations.clear()
        persist()
    }

    // MARK: Attachments

    fun displayName(uri: Uri) = pdf.displayName(uri)

    suspend fun readPdf(uri: Uri): DocumentAttachment = pdf.extract(uri, api)

    suspend fun readPhotoText(data: ByteArray, name: String): DocumentAttachment = pdf.extractPhoto(data, name, api)

    // MARK: Messaging

    /**
     * Sends a chat message. With [createImage], the text is used directly as an image prompt;
     * with [speak], it is spoken with the selected Drama 3 voice.
     */
    fun send(text: String, attachments: List<ByteArray> = emptyList(), documents: List<DocumentAttachment> = emptyList(),
             createImage: Boolean = false, createVideo: Boolean = false, speak: Boolean = false) {
        val trimmed = text.trim()
        if ((trimmed.isEmpty() && attachments.isEmpty() && documents.isEmpty()) || isStreaming) return

        if (currentId == null) {
            val title = when {
                trimmed.isNotEmpty() -> title(trimmed)
                documents.isNotEmpty() -> documents.first().name
                else -> "Image"
            }
            val conversation = Conversation(title = title, model = selectedModel, knowledge = pendingKnowledge)
            pendingKnowledge = emptyList()
            conversations.add(0, conversation)
            currentId = conversation.id
            if (trimmed.isNotEmpty()) nameChat(conversation.id, trimmed, selectedModel)
        }
        val names = attachments.map(images::save)
        update { it.copy(messages = it.messages + ChatMessage(role = ChatRole.user, content = trimmed, images = names, documents = documents)) }

        when {
            speak && trimmed.isNotEmpty() -> makeSpeech(trimmed)
            createVideo && (trimmed.isNotEmpty() || names.isNotEmpty()) -> makeVideo(trimmed.ifEmpty { CONTINUE_PROMPT }, names.lastOrNull())
            createImage -> makeImage(trimmed, names.lastOrNull())
            else -> respond()
        }
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

    /** The prompt that made a video, to start its continuation from. */
    fun promptForVideo(name: String): String? {
        val messages = current?.messages ?: return null
        val index = messages.indexOfFirst { name in it.videos }
        if (index < 0) return null
        return messages.take(index).lastOrNull { it.role == ChatRole.user }?.content
    }

    /** Video mode: makes a clip with sound from the prompt. */
    private fun makeVideo(prompt: String, firstFrame: String?) {
        val reply = ChatMessage(role = ChatRole.assistant, content = "")
        update { it.copy(messages = it.messages + reply) }
        isStreaming = true
        val seconds = videoSeconds
        val aspect = videoAspect
        streamJob = viewModelScope.launch {
            try {
                updateMessage(reply.id) { it.copy(status = "Making a $seconds-second video with MiniMax-H3… This takes a few minutes.") }
                val frame = firstFrame?.let(images::data)?.let { withContext(Dispatchers.Default) { ImageStore.jpeg(it, 1920) } ?: it }
                val data = api.generateVideo(prompt, seconds, aspect, frame)
                val name = withContext(Dispatchers.IO) { videos.save(data) }
                updateMessage(reply.id) { it.copy(videos = it.videos + name) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                updateMessage(reply.id) { it.copy(content = e.message ?: "Video failed.", isError = true) }
            } finally {
                updateMessage(reply.id) { it.copy(status = null) }
                isStreaming = false
                persist()
            }
        }
    }

    /** Speech mode: speaks the user's text with the selected voice and delivery settings. */
    private fun makeSpeech(script: String) {
        val reply = ChatMessage(role = ChatRole.assistant, content = "")
        update { it.copy(messages = it.messages + reply) }
        isStreaming = true
        streamJob = viewModelScope.launch {
            try {
                val name = runSpeechTool(script, reply.id)
                updateMessage(reply.id) { it.copy(audio = it.audio + name) }
                playback.toggle(name, audio.file(name))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                updateMessage(reply.id) { it.copy(content = e.message ?: "Speech failed.", isError = true) }
            } finally {
                updateMessage(reply.id) { it.copy(status = null) }
                isStreaming = false
                persist()
            }
        }
    }

    /** Speaks a script with Drama 3 and returns the stored file name. */
    private suspend fun runSpeechTool(script: String, replyId: String): String {
        val voice = voices.selected
        updateMessage(replyId) { it.copy(status = "Speaking with ${voice.name} · Drama 3…") }
        val sample = withContext(Dispatchers.IO) { voices.sample(voice) }
        return withContext(Dispatchers.IO) { audio.save(api.speech(voices.styled(script), voice, sample)) }
    }

    private val latestImage get() = current?.messages?.lastOrNull { it.images.isNotEmpty() }?.images?.lastOrNull()

    private fun respond() {
        val conversation = current ?: return
        var system = systemPrompt
        system += "\n\nToday is ${DateFormat.getDateInstance(DateFormat.FULL).format(Date())}."
        if (webSearchEnabled) {
            system += WebSearch.SYSTEM_PROMPT
        }
        if (pythonEnabled) system += " " + PythonRunner.SYSTEM_PROMPT
        if (imageToolsEnabled) {
            system += " You can create images with generate_image and modify the latest image in the chat with edit_image. Never describe an image as created unless the tool succeeded."
        }
        if (voices.toolsEnabled) {
            system += " You can speak aloud with generate_speech when the user asks you to say, read or voice something. Never claim you spoke unless the tool succeeded."
        }
        val asked = conversation.messages.lastOrNull { it.role == ChatRole.user }?.content.orEmpty()
        if (memory.enabled) system += "\n\n" + memory.systemPrompt(asked)
        skills.systemPrompt?.let { system += "\n\n" + it }
        system += "\n\n" + SkillLibrary.SYSTEM_PROMPT + " Use search_chats when the user refers to an earlier conversation."
        val systemText = system.trim()
        val wire = history(systemText, conversation)

        val reply = ChatMessage(role = ChatRole.assistant, content = "")
        val model = selectedModel
        val bases = activeKnowledge
        val question = conversation.messages.lastOrNull { it.role == ChatRole.user }?.content.orEmpty()
        update { it.copy(model = model, messages = it.messages + reply) }

        val tools = buildList {
            if (webSearchEnabled) { add(Tools.webSearch); add(Tools.imageSearch); add(Tools.readPage) }
            if (pythonEnabled) add(Tools.runPython)
            if (imageToolsEnabled) { add(Tools.generateImage); add(Tools.editImage) }
            if (voices.toolsEnabled) add(Tools.generateSpeech)
            if (memory.enabled) { add(Tools.remember); add(Tools.forget) }
            add(Tools.searchChats); add(Tools.suggestSkill)
            if (skills.skills.isNotEmpty()) add(Tools.useSkill)
        }
        isStreaming = true
        streamJob = viewModelScope.launch {
            try {
                var messages = wire
                compact(conversation, model, wire, reply.id)?.let { messages = history(systemText, it) }
                if (bases.isNotEmpty() && question.isNotEmpty()) {
                    updateMessage(reply.id) { it.copy(status = "Searching knowledge…") }
                    try {
                        val citations = knowledge.search(question, bases, api)
                        if (citations.isNotEmpty()) {
                            updateMessage(reply.id) { it.copy(citations = citations) }
                            val system = jsonString(messages[0]["content"]).orEmpty() + "\n\n" + KnowledgeLibrary.context(citations)
                            messages = listOf(buildJsonObject { put("role", "system"); put("content", system.trim()) }) + messages.drop(1)
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        updateMessage(reply.id) { it.copy(status = "Knowledge search failed, answering without it…") }
                    }
                }
                // PDFs and knowledge excerpts come from outside the chat; see runTurn's memory lock.
                val outsideContent = conversation.messages.any { it.documents.isNotEmpty() } ||
                    current?.messages?.firstOrNull { it.id == reply.id }?.citations?.isNotEmpty() == true
                val mcpTools = mcp.availableTools()
                if (mcpTools.isNotEmpty()) {
                    val system = jsonString(messages[0]["content"]).orEmpty() +
                        "\n\nTools named <service>__<tool> belong to services the user connected (MCP). Use them when they fit the request."
                    messages = listOf(buildJsonObject { put("role", "system"); put("content", system) }) + messages.drop(1)
                }
                val readOutside = runTurn(model, messages, tools + mcpTools.map { it.definition }, reply.id, outsideContent, mcpTools)
                learn(question, reply.id, model, userOnly = readOutside)
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
                    val empty = it.content.isEmpty() && it.images.isEmpty() && it.audio.isEmpty() && it.videos.isEmpty() && isActive
                    if (empty) it.copy(status = null, content = "No response from the model.", isError = true) else it.copy(status = null)
                }
                isStreaming = false
                persist()
            }
        }
    }

    /**
     * Streams the reply, running tools whenever the model asks for them. Memory changes are refused once the reply
     * has read outside content (web results, PDFs, knowledge bases), so text planted there can't write itself into
     * every future chat.
     */
    private suspend fun runTurn(model: String, initial: List<JsonObject>, initialTools: List<JsonObject>, replyId: String, outside: Boolean, mcpTools: List<McpTool> = emptyList()): Boolean {
        var outsideContent = outside
        val messages = initial.toMutableList()
        var tools = initialTools

        for (round in 0..maxToolRounds) {
            val isFinalRound = round == maxToolRounds
            if (isFinalRound) {
                messages += buildJsonObject { put("role", "user"); put("content", "Stop using tools now and write the final answer using the results above.") }
            }
            val prefix = message(replyId)?.content.orEmpty()
            val reasoningPrefix = message(replyId)?.reasoning.orEmpty()
            var text = ""
            var reasoning = ""
            var calls: List<BlabladorApi.ToolCall> = emptyList()
            try {
                api.streamChat(model, messages, tools).collect { event ->
                    when (event) {
                        is BlabladorApi.StreamEvent.Content -> {
                            text += event.text
                            val (thinking, answer) = splitThinking(text)
                            val visible = stripToolMarkup(answer)
                            updateMessage(replyId) {
                                it.copy(status = null, content = prefix + visible,
                                    reasoning = if (thinking.isEmpty()) it.reasoning else joined(reasoningPrefix, reasoning + thinking))
                            }
                        }
                        is BlabladorApi.StreamEvent.Reasoning -> {
                            reasoning += event.text
                            updateMessage(replyId) { it.copy(status = null, reasoning = joined(reasoningPrefix, reasoning)) }
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
                return outsideContent
            }
            if (calls.isEmpty()) return outsideContent

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
                val script = jsonString(arguments?.get("script")).orEmpty()
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
                    call.name == "generate_speech" && script.isNotEmpty() -> try {
                        val name = runSpeechTool(script, replyId)
                        updateMessage(replyId) { it.copy(audio = it.audio + name) }
                        "The speech was created and the user can play it. Don't repeat the script; just briefly comment on it."
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        "Speech tool failed: ${e.message}"
                    }
                    call.name == "use_skill" -> {
                        val skill = skills.skill(jsonString(arguments?.get("name")).orEmpty())
                        if (skill != null) {
                            updateMessage(replyId) { if (skill.name in it.skillsUsed) it else it.copy(skillsUsed = it.skillsUsed + skill.name) }
                            "Instructions of the skill \"${skill.name}\":\n\n${skill.instructions}"
                        } else "There is no skill called \"${jsonString(arguments?.get("name"))}\"."
                    }
                    call.name == "suggest_skill" && !jsonString(arguments?.get("instructions")).isNullOrBlank() -> {
                        val skill = Skill(
                            name = jsonString(arguments?.get("name")).orEmpty().ifBlank { "New skill" },
                            description = jsonString(arguments?.get("description")).orEmpty(),
                            instructions = jsonString(arguments?.get("instructions")).orEmpty(),
                        )
                        updateMessage(replyId) { it.copy(suggestedSkills = it.suggestedSkills + skill) }
                        "The suggestion is shown to the user with a Save button; it is not saved until they press it. Don't repeat the instructions; mention it in one sentence."
                    }
                    call.name == "search_chats" && query.isNotEmpty() -> {
                        outsideContent = true
                        updateMessage(replyId) { it.copy(status = "Searching earlier chats…") }
                        ChatSearch.search(query, conversations.toList(), currentId)
                    }
                    (call.name == "remember" || call.name == "forget") && outsideContent ->
                        "Memory can't be changed in a reply that used web results, documents or knowledge bases, because they could contain planted instructions. " +
                            "Tell the user they can ask again in a new message without them, or edit memories in Settings → Memory."
                    call.name == "remember" && memory.enabled -> {
                        val fact = jsonString(arguments?.get("fact")).orEmpty().trim()
                        if (memory.add(fact)) {
                            updateMessage(replyId) { it.copy(remembered = it.remembered + fact) }
                            "Saved to memory."
                        } else "Already remembered or empty; nothing saved."
                    }
                    call.name == "forget" && memory.enabled -> {
                        val number = jsonString(arguments?.get("number"))?.toIntOrNull()
                        val forgotten = number?.let(memory::forget)
                        if (forgotten != null) {
                            updateMessage(replyId) { it.copy(forgotten = it.forgotten + forgotten.text) }
                            "Forgot: ${forgotten.text}. The numbers of later memories moved up by one."
                        } else "There is no memory number $number."
                    }
                    call.name == "image_search" && query.isNotEmpty() -> {
                        outsideContent = true
                        updateMessage(replyId) { it.copy(status = "Searching pictures of “$query”") }
                        try {
                            val images = WebSearch.searchImages(query)
                            updateMessage(replyId) { message ->
                                message.copy(webImages = message.webImages + images.filter { image -> message.webImages.none { it.image == image.image } })
                            }
                            if (images.isEmpty()) "No pictures found for \"$query\"."
                            else "${images.size} pictures are shown to the user: ${images.joinToString("; ") { it.title }}. Don't include image links in your answer."
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            "Image search failed: ${e.message}"
                        }
                    }
                    call.name == "run_python" && !jsonString(arguments?.get("code")).isNullOrBlank() -> {
                        outsideContent = true
                        runPython(jsonString(arguments?.get("code")).orEmpty(), replyId)
                    }
                    mcpTools.any { it.qualifiedName == call.name } -> {
                        outsideContent = true
                        runMcpTool(mcpTools.first { it.qualifiedName == call.name }, arguments ?: JsonObject(emptyMap()), replyId)
                    }
                    call.name == "read_page" && !jsonString(arguments?.get("url")).isNullOrBlank() -> {
                        outsideContent = true
                        val address = jsonString(arguments?.get("url")).orEmpty()
                        updateMessage(replyId) { it.copy(status = "Reading ${Uri.parse(address).host ?: address}…") }
                        try {
                            val page = WebPage.read(address)
                            var number = 0
                            updateMessage(replyId) { message ->
                                val index = message.sources.indexOfFirst { it.url == page.url }
                                if (index >= 0) { number = index + 1; message }
                                else {
                                    number = message.sources.size + 1
                                    message.copy(sources = message.sources + SearchResult(page.title, page.url, null))
                                }
                            }
                            "[$number] ${page.title}\nURL: ${page.url}\n\n${page.text.ifEmpty { "(No readable text on this page.)" }}"
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            "Could not read the page: ${e.message}"
                        }
                    }
                    call.name == "web_search" && query.isNotEmpty() -> {
                        outsideContent = true
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
        return outsideContent
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
            if (message.role == ChatRole.assistant && message.audio.isNotEmpty()) text = "[Generated speech]\n$text"
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
    /** Splits a `<think>…</think>` block some models put at the start of their answer from the answer itself. */
    private fun splitThinking(text: String): Pair<String, String> {
        val trimmed = text.trimStart()
        if (!trimmed.startsWith("<think>")) return "" to text
        val body = trimmed.removePrefix("<think>")
        val end = body.indexOf("</think>")
        return if (end < 0) body to "" else body.substring(0, end) to body.substring(end + "</think>".length).trim()
    }

    /** Thinking from earlier tool rounds, then this round's. */
    private fun joined(earlier: String, new: String) = if (earlier.isEmpty()) new else "$earlier\n\n$new"

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

    /** Runs Python with Pyodide; figures are added to the reply as images. */
    private suspend fun runPython(code: String, replyId: String): String {
        updateMessage(replyId) { it.copy(status = "Running Python…", toolCalls = it.toolCalls + "Python") }
        // Attached documents, as text files in /data.
        val files = current?.messages.orEmpty().flatMap { it.documents }.associate { document ->
            val name = document.name.replace("/", "_")
            (if (name.endsWith(".txt")) name else "$name.txt") to document.text
        }
        return try {
            val result = python.run(code, files)
            val names = result.images.map(images::save)
            if (names.isNotEmpty()) updateMessage(replyId) { it.copy(images = it.images + names) }
            var output = result.output.trim()
            result.value?.takeIf { it.isNotEmpty() && it != "None" }?.let { output += (if (output.isEmpty()) "" else "\n") + "Result: " + it }
            result.error?.let { output += (if (output.isEmpty()) "" else "\n") + it }
            if (names.isNotEmpty()) output += "\n[${names.size} figure(s) shown to the user]"
            output = output.trim()
            if (output.isEmpty()) "The code ran without output." else output.takeLast(20_000)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            "Python failed: ${e.message}"
        }
    }

    /** Replaces a new chat's provisional title (its first words) with a short name from the helper model. */
    private fun nameChat(id: String, text: String, model: String) {
        val provisional = title(text)
        viewModelScope.launch {
            val system = "Give a chat a short title that says what it is about, like a heading: two to six words, in the language of the user's message, without quotes or final period. Don't copy the start of the message. Reply with only the title."
            val name = runCatching { api.complete(BlabladorApi.helperModel(model), system, text.take(2000)) }.getOrNull()
                ?.trim()?.trim('"', '\'', '“', '”', '«', '»', '*', '#', '.')?.trim() ?: return@launch
            val index = conversations.indexOfFirst { it.id == id }
            if (name.isEmpty() || name.length > 80 || '\n' in name || index < 0 || conversations[index].title != provisional) return@launch
            conversations[index] = conversations[index].copy(title = name)
            persist()
        }
    }

    // MARK: Connected tools (MCP)

    /** A shell command or connected-service tool call waiting for the user's OK. */
    data class ToolApproval(val title: String, val detail: String, val answer: kotlinx.coroutines.CompletableDeferred<ApprovalChoice>)

    enum class ApprovalChoice { Once, Always, Deny }

    var toolApproval by mutableStateOf<ToolApproval?>(null)
        private set

    fun answerApproval(choice: ApprovalChoice) {
        toolApproval?.answer?.complete(choice)
        toolApproval = null
    }

    /** Chat and server pairs where the user allowed MCP tool calls without asking. */
    private val mcpAllowed = mutableSetOf<String>()

    /** Runs a tool of a connected MCP server after the user's OK. */
    private suspend fun runMcpTool(tool: McpTool, arguments: JsonObject, replyId: String): String {
        val server = mcp.server(tool.server)
        val key = "$currentId|${tool.server}"
        if (server?.askBeforeCalls != false && key !in mcpAllowed) {
            updateMessage(replyId) { it.copy(status = "Waiting for approval…") }
            val shown = kotlinx.serialization.json.Json { prettyPrint = true }.encodeToString(JsonObject.serializer(), arguments)
            val answer = kotlinx.coroutines.CompletableDeferred<ApprovalChoice>()
            toolApproval = ToolApproval("Let ${server?.name ?: "this server"} use ${tool.name}?", shown.take(2_000), answer)
            val choice = try { answer.await() } finally { if (toolApproval?.answer === answer) toolApproval = null }
            if (choice == ApprovalChoice.Always) mcpAllowed += key
            if (choice == ApprovalChoice.Deny) return "The user declined this tool call. Ask what to do instead or continue without it."
        }
        updateMessage(replyId) { it.copy(status = "Using ${tool.name}…", toolCalls = it.toolCalls + "${server?.name ?: "Server"}: ${tool.name}") }
        return try {
            val (text, _) = mcp.call(tool, arguments)
            if (text.isEmpty()) "(The tool returned nothing.)" else text.take(30_000)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            "Tool failed: ${e.message}"
        }
    }

    // MARK: Long chats

    private fun history(system: String, conversation: Conversation) = chatHistory(system, conversation, ::wireMessage)

    private fun size(wire: List<JsonObject>) = requestSize(wire)

    /**
     * Summarises everything but the most recent messages with the helper model when the chat got too long;
     * returns the conversation with the new summary, or null when nothing changed.
     */
    private suspend fun compact(conversation: Conversation, model: String, wire: List<JsonObject>, replyId: String): Conversation? {
        val end = conversation.messages.size - recentMessages
        val covered = conversation.summaryCount ?: 0
        if (size(wire) <= compactionThreshold || end <= covered) return null
        updateMessage(replyId) { it.copy(status = "Summarizing earlier messages…") }
        val transcript = StringBuilder(conversation.summary?.let { "Summary so far:\n$it\n\n" } ?: "")
        for (message in conversation.messages.subList(covered, end).filter { !it.isError }) {
            val who = if (message.role == ChatRole.user) "User" else "Assistant"
            var text = message.content
            if (message.documents.isNotEmpty()) text = message.documents.joinToString(" ") { "[Attached ${it.name}]" } + "\n" + text
            if (message.images.isNotEmpty()) text = "[${message.images.size} image(s)]\n$text"
            transcript.append("$who: ${text.take(6_000)}\n\n")
        }
        val system = "Summarize this conversation so an assistant can continue it without the original messages. Keep facts, decisions, names, numbers, code and file names, open questions and what the user wants, in the conversation's language. At most 500 words. Reply with only the summary."
        val summary = runCatching { api.complete(BlabladorApi.helperModel(model), system, transcript.takeLast(300_000).toString()) }
            .getOrNull()?.trim().orEmpty()
        val index = conversations.indexOfFirst { it.id == conversation.id }
        if (summary.isEmpty() || index < 0) return null
        conversations[index] = conversations[index].copy(summary = summary, summaryCount = end)
        persist()
        return conversation.copy(summary = summary, summaryCount = end)
    }

    /** Saves what's worth keeping from the exchange to long-term memory, in the background. */
    private fun learn(question: String, replyId: String, model: String, userOnly: Boolean) {
        val reply = message(replyId)
        if (!memory.enabled || !memory.learnsAutomatically || question.isEmpty() || reply == null || reply.isError || reply.content.isEmpty()) return
        viewModelScope.launch {
            val facts = runCatching { memory.learn(question, if (userOnly) null else reply.content, api, model) }.getOrDefault(emptyList())
            if (facts.isEmpty()) return@launch
            updateMessage(replyId) { it.copy(remembered = it.remembered + facts) }
            persist()
        }
    }

    private fun title(text: String): String {
        val first = text.lineSequence().first()
        return if (first.length > 40) first.take(40) + "…" else first
    }
}

/** The system prompt (with the summary of older messages, if any) and the messages after the summary. */
internal fun chatHistory(system: String, conversation: Conversation, wireMessage: (ChatMessage) -> JsonObject): List<JsonObject> {
    val covered = minOf(conversation.summaryCount ?: 0, conversation.messages.size)
    val summary = conversation.summary
    val text = if (summary != null && covered > 0)
        "$system\n\nSummary of the earlier part of this chat (those messages are not shown):\n$summary" else system
    return listOf(buildJsonObject { put("role", "system"); put("content", text) }) +
        conversation.messages.drop(covered).filter { !it.isError }.map(wireMessage)
}

/** Rough size of a request: text, plus about 3,000 characters per image. */
internal fun requestSize(wire: List<JsonObject>): Int = wire.sumOf { message ->
    when (val content = message["content"]) {
        is JsonPrimitive -> content.content.length
        is kotlinx.serialization.json.JsonArray -> content.sumOf { part -> jsonString((part as? JsonObject)?.get("text"))?.length ?: 3_000 }
        else -> 0
    }
}
