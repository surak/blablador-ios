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
import de.fz_juelich.blablador.data.Incoming
import de.fz_juelich.blablador.data.find
import de.fz_juelich.blablador.data.ChatIndex
import de.fz_juelich.blablador.data.PythonRunner
import de.fz_juelich.blablador.data.DataFiles
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
import de.fz_juelich.blablador.data.DeviceTools
import de.fz_juelich.blablador.data.Mention
import de.fz_juelich.blablador.data.Mentions
import de.fz_juelich.blablador.data.Notifier
import de.fz_juelich.blablador.data.PlanTools
import de.fz_juelich.blablador.data.ScheduledTask
import de.fz_juelich.blablador.data.SkillDrafter
import de.fz_juelich.blablador.data.StepState
import de.fz_juelich.blablador.data.TaskStore
import de.fz_juelich.blablador.data.ToolPermissions
import de.fz_juelich.blablador.data.Trace
import de.fz_juelich.blablador.data.TraceCall
import de.fz_juelich.blablador.data.splitThinking
import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
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
    companion object {
        const val ACTION_NEW_CHAT = "de.fz_juelich.blablador.NEW_CHAT"
        const val ACTION_ADD_MEMORY = "de.fz_juelich.blablador.ADD_MEMORY"
    }

    val settings = Settings(application)
    val images = ImageStore(application)
    private val conversationStore = ConversationStore(application)
    private val pdf = PdfExtractor(application, settings)
    val knowledge = KnowledgeLibrary(application, viewModelScope, pdf)
    val voices = VoiceLibrary(application)
    val memory = MemoryStore(application)
    val skills = SkillLibrary(application)
    val chatIndex = ChatIndex(application)
    val mcp = McpLibrary(application)
    val audio = AudioStore(application)
    val videos = VideoStore(application)
    val playback = AudioPlayback()
    val permissions = ToolPermissions(application, { mcp.servers.toList() }, { mcp.save(it) })
    val tasks = TaskStore(application)

    val conversations = mutableStateListOf<Conversation>().apply { addAll(conversationStore.load().map(::markingInterrupted)) }
    var currentId by mutableStateOf<String?>(null)
        private set
    var models by mutableStateOf<List<RemoteModel>>(emptyList())
        private set
    var modelsError by mutableStateOf<String?>(null)
        private set
    /** Replies being written, per chat; they keep going when the user switches chats. */
    private val running = mutableStateMapOf<String, Job>()
    /** The open chat is writing a reply. */
    val isStreaming: Boolean get() = currentId?.let { it in running } ?: false
    /** Some chat is writing a reply. */
    val isBusy: Boolean get() = running.isNotEmpty()
    /** Whether the app is on screen (set by MainActivity), for notifications. */
    var appVisible = false

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

    /** Tool rounds per reply; a reply with a plan may take more. */
    private val maxToolRounds = 8
    private val maxPlanRounds = 25
    private val prettyJson = kotlinx.serialization.json.Json { prettyPrint = true }

    /** Runs the work of a reply for a chat; when it ends, due scheduled tasks get their turn. */
    private fun start(chat: String?, work: suspend CoroutineScope.() -> Unit) {
        chat ?: return
        lateinit var job: Job
        job = viewModelScope.launch {
            try { work() } finally {
                if (running[chat] === job) running.remove(chat)
                checkTasks()
            }
        }
        running[chat] = job
    }

    private fun chatContaining(messageId: String) = conversations.firstOrNull { c -> c.messages.any { it.id == messageId } }

    fun canRerun(tool: String) = tool !in setOf("update_plan", "remember", "forget", "use_skill", "suggest_skill", "generate_image", "edit_image",
        "generate_speech", "create_event", "create_reminder", "schedule_task", "write_file", "edit_file")
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
        // Scheduled tasks run while the app is open; an alarm at each time brings it back.
        viewModelScope.launch { while (true) { delay(30_000); checkTasks() } }
        tasks.scheduleAlarm()
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

    var deviceToolsEnabled by mutableStateOf(settings.deviceToolsEnabled)
        private set
    fun turnDeviceTools(on: Boolean) { deviceToolsEnabled = on; settings.deviceToolsEnabled = on }

    var draftsSkills by mutableStateOf(settings.skillsDraftAutomatically)
        private set
    fun suggestSkillsAfterTasks(on: Boolean) { draftsSkills = on; settings.skillsDraftAutomatically = on }

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

    // MARK: From outside the app

    /** A share, link or shortcut waiting for the chat screen. */
    var incoming by mutableStateOf<Incoming?>(null)
        private set

    /** Takes what's waiting, so it is handled once. */
    fun claimIncoming(): Incoming? = incoming.also { incoming = null }

    /**
     * Shares (ACTION_SEND / SEND_MULTIPLE), files opened with Blablador (ACTION_VIEW), blablador:// links and
     * shortcuts. Shared content URIs stop working once the sending app is done, so files are copied first.
     */
    fun receive(intent: android.content.Intent) {
        val app = getApplication<Application>()
        when (intent.action) {
            android.content.Intent.ACTION_SEND, android.content.Intent.ACTION_SEND_MULTIPLE -> {
                val text = listOfNotNull(intent.getStringExtra(android.content.Intent.EXTRA_SUBJECT), intent.getStringExtra(android.content.Intent.EXTRA_TEXT))
                    .filter { it.isNotBlank() }.distinct().joinToString("\n")
                val uris = buildList {
                    @Suppress("DEPRECATION")
                    (intent.getParcelableExtra<Uri>(android.content.Intent.EXTRA_STREAM))?.let(::add)
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<Uri>(android.content.Intent.EXTRA_STREAM)?.let(::addAll)
                }.distinct()
                viewModelScope.launch { incoming = Incoming.Share(text, copyShared(app, uris)) }
            }
            android.content.Intent.ACTION_VIEW -> {
                val data = intent.data ?: return
                if (data.scheme == "blablador") incoming = Incoming.parse(data.toString())
                else viewModelScope.launch { incoming = Incoming.Share("", copyShared(app, listOf(data))) }
            }
            ACTION_NEW_CHAT -> incoming = Incoming.Share("")
            ACTION_ADD_MEMORY -> incoming = Incoming.AddMemory
        }
    }

    private suspend fun copyShared(app: Application, uris: List<Uri>): List<java.io.File> = withContext(Dispatchers.IO) {
        val folder = java.io.File(app.cacheDir, "shared/" + java.util.UUID.randomUUID()).apply { mkdirs() }
        uris.mapIndexedNotNull { index, uri ->
            runCatching {
                val name = app.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                } ?: uri.lastPathSegment?.substringAfterLast('/') ?: "Shared ${index + 1}"
                val type = app.contentResolver.getType(uri).orEmpty()
                // Photos often come without an extension; the attachment code goes by name.
                val named = if ('.' !in name && type.startsWith("image/")) "$name.${type.substringAfter('/')}" else name
                val file = java.io.File(folder, named.replace('/', '_'))
                app.contentResolver.openInputStream(uri)?.use { input -> file.outputStream().use { input.copyTo(it) } } ?: return@runCatching null
                file
            }.getOrNull()
        }
    }

    // MARK: Conversations

    fun newChat() {
        currentId = null
        pendingKnowledge = emptyList()
    }

    fun select(conversation: Conversation) {
        currentId = conversation.id
        selectModel(conversation.model)
    }

    fun delete(conversation: Conversation) {
        running.remove(conversation.id)?.cancel()
        if (conversation.id == currentId) newChat()
        images.delete(conversation.allMessages.flatMap { it.images })
        DataFiles.delete(getApplication(), conversation.allMessages.flatMap { it.documents }.mapNotNull { it.dataFile })
        audio.delete(conversation.allMessages.flatMap { it.audio })
        videos.delete(conversation.allMessages.flatMap { it.videos })
        conversations.removeAll { it.id == conversation.id }
        persist()
    }

    fun deleteAll() {
        running.values.toList().forEach { it.cancel() }
        running.clear()
        newChat()
        images.delete(conversations.flatMap { c -> c.allMessages.flatMap { it.images } })
        DataFiles.delete(getApplication(), conversations.flatMap { c -> c.allMessages.flatMap { it.documents }.mapNotNull { it.dataFile } })
        audio.delete(conversations.flatMap { c -> c.allMessages.flatMap { it.audio } })
        videos.delete(conversations.flatMap { c -> c.allMessages.flatMap { it.videos } })
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
    /** Stores a data file (CSV, Excel, JSON…) for Python and returns it as an attachment. */
    suspend fun attachDataFile(uri: android.net.Uri, name: String): DocumentAttachment = withContext(Dispatchers.IO) {
        val app = getApplication<Application>()
        val bytes = app.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: throw IllegalStateException("Couldn't open $name.")
        DataFiles.attach(app, name, bytes)
    }

    fun send(text: String, attachments: List<ByteArray> = emptyList(), documents: List<DocumentAttachment> = emptyList(),
             mentions: List<Mention> = emptyList(), createImage: Boolean = false, createVideo: Boolean = false, speak: Boolean = false) {
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
        update { it.copy(messages = it.messages + ChatMessage(role = ChatRole.user, content = trimmed, images = names, documents = documents, mentions = mentions)) }
        // A mentioned knowledge base stays on for the chat.
        mentions.filter { it.kind == Mention.Kind.knowledge && it.value !in activeKnowledge && knowledge.base(it.value) != null }.forEach { toggleKnowledge(it.value) }

        when {
            speak && trimmed.isNotEmpty() -> makeSpeech(trimmed)
            createVideo && (trimmed.isNotEmpty() || names.isNotEmpty()) -> makeVideo(trimmed.ifEmpty { CONTINUE_PROMPT }, names.lastOrNull())
            createImage -> makeImage(trimmed, names.lastOrNull())
            else -> respond()
        }
    }

    /**
     * Answers the last message again; the previous answer stays as an earlier version. With [model], that model
     * becomes the chat's model first.
     */
    fun regenerate(model: String? = null) {
        val messages = current?.messages ?: return
        if (isStreaming || messages.lastOrNull()?.role != ChatRole.assistant) return
        if (model != null) selectModel(model)
        val (alternatives, version) = versions(messages.takeLast(1))
        update { dropSummary(it.copy(messages = it.messages.dropLast(1)), it.messages.size - 1) }
        respond(alternatives, version)
    }

    /**
     * Sends a changed version of an earlier message of the user; the old one and everything after it stay as an
     * earlier version, reachable with the arrows under the message.
     */
    fun edit(messageId: String, text: String) {
        val trimmed = text.trim()
        val messages = current?.messages ?: return
        val index = messages.indexOfFirst { it.id == messageId }
        if (isStreaming || trimmed.isEmpty() || index < 0 || messages[index].role != ChatRole.user) return
        val (alternatives, version) = versions(messages.drop(index))
        val edited = ChatMessage(role = ChatRole.user, content = trimmed, images = messages[index].images,
            documents = messages[index].documents, mentions = messages[index].mentions, alternatives = alternatives, version = version)
        update { dropSummary(it.copy(messages = it.messages.take(index) + edited), index) }
        respond()
    }

    /** Shows the previous (-1) or next (+1) version of the chat from this message on. */
    fun showVersion(messageId: String, offset: Int) {
        val messages = current?.messages ?: return
        val index = messages.indexOfFirst { it.id == messageId }
        if (isStreaming || index < 0) return
        val switched = messagesShowingVersion(messages, offset, index) ?: return
        update { dropSummary(it.copy(messages = switched), index) }
    }

    /** A summary of messages that changed no longer fits; long chats are summarised again when needed. */
    private fun dropSummary(conversation: Conversation, index: Int): Conversation =
        if ((conversation.summaryCount ?: 0) > index) conversation.copy(summary = null, summaryCount = null) else conversation

    /** Stops the open chat's reply. */
    fun stop() {
        val id = currentId ?: return
        running.remove(id)?.cancel()
        approvals.filter { it.chat == id }.forEach { answer(it, ApprovalChoice.Deny) }
    }

    private fun makeImage(prompt: String, source: String?) {
        val reply = ChatMessage(role = ChatRole.assistant, content = "")
        update { it.copy(messages = it.messages + reply) }
        start(currentId) {
            try {
                val image = runImageTool(if (source == null) "generate_image" else "edit_image", prompt.ifEmpty { "Improve this image" }, source, reply.id)
                updateMessage(reply.id) { it.copy(images = it.images + image) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                updateMessage(reply.id) { it.copy(content = e.message ?: "Image failed.", isError = true) }
            } finally {
                updateMessage(reply.id) { it.copy(status = null) }
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
        val seconds = videoSeconds
        val aspect = videoAspect
        start(currentId) {
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
                persist()
            }
        }
    }

    /** Speech mode: speaks the user's text with the selected voice and delivery settings. */
    private fun makeSpeech(script: String) {
        val reply = ChatMessage(role = ChatRole.assistant, content = "")
        update { it.copy(messages = it.messages + reply) }
        start(currentId) {
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

    private fun latestImage(replyId: String) = chatContaining(replyId)?.messages?.lastOrNull { it.images.isNotEmpty() }?.images?.lastOrNull()

    private fun respond(alternatives: List<List<ChatMessage>> = emptyList(), version: Int = 1, chatId: String? = currentId, task: ScheduledTask? = null) {
        val id = chatId ?: return
        val conversation = conversations.firstOrNull { it.id == id } ?: return
        val lastUser = conversation.messages.lastOrNull { it.role == ChatRole.user }
        val question = lastUser?.content.orEmpty()
        val mentions = lastUser?.mentions.orEmpty()
        val mentioned = mentions.filter { it.kind == Mention.Kind.tool }.map { it.value }.toSet()
        val useWeb = webSearchEnabled || "web" in mentioned
        val usePython = pythonEnabled || "python" in mentioned
        val useDevice = deviceToolsEnabled || "device" in mentioned
        val useImages = imageToolsEnabled || "image" in mentioned

        val now = Date()
        var system = systemPrompt
        system += "\n\nToday is ${DateFormat.getDateInstance(DateFormat.FULL).format(now)}, local time ${DateFormat.getTimeInstance(DateFormat.SHORT).format(now)}."
        if (useWeb) system += WebSearch.SYSTEM_PROMPT
        if (usePython) system += " " + PythonRunner.SYSTEM_PROMPT
        if (useImages) {
            system += " You can create images with generate_image and modify the latest image in the chat with edit_image. Never describe an image as created unless the tool succeeded."
        }
        if (voices.toolsEnabled) {
            system += " You can speak aloud with generate_speech when the user asks you to say, read or voice something. Never claim you spoke unless the tool succeeded."
        }
        if (useDevice) system += " " + DeviceTools.SYSTEM_PROMPT
        system += " " + PlanTools.SYSTEM_PROMPT
        system += " Use schedule_task when the user wants something done later or regularly."
        skills.systemPrompt?.let { system += "\n\n" + it }
        system += "\n\n" + SkillLibrary.SYSTEM_PROMPT + " Use search_chats when the user refers to an earlier conversation."
        Mentions.prompt(mentions, skills::skill, mcp::server)?.let { system += "\n\n" + it }
        if (task != null) {
            system += "\n\nThis message is a scheduled task the user set up earlier (\"${task.title}\", ${task.scheduleText.lowercase()}); it runs now while they aren't watching, " +
                "and your answer is shown as a notification. Do all of it without asking questions. If it is a reminder, reply with the reminder itself, " +
                "addressed to the user, e.g. \"Time to call Maria.\" Write the result so it reads well on its own."
        }
        val baseSystem = system.trim()

        val model = selectedModel
        val reply = ChatMessage(role = ChatRole.assistant, content = "", alternatives = alternatives, version = version,
            trace = Trace(model = model),
            skillsUsed = mentions.filter { it.kind == Mention.Kind.skill }.mapNotNull { skills.skill(it.value)?.name })
        val bases = conversation.knowledge.filter { knowledge.base(it) != null }
        updateChat(id) { it.copy(model = model, messages = it.messages + reply) }

        val tools = permissions.filter(buildList {
            if (useWeb) { add(Tools.webSearch); add(Tools.imageSearch); add(Tools.readPage) }
            if (usePython) add(Tools.runPython)
            if (useImages) { add(Tools.generateImage); add(Tools.editImage) }
            if (voices.toolsEnabled) add(Tools.generateSpeech)
            if (memory.enabled) { add(Tools.remember); add(Tools.forget) }
            add(Tools.searchChats); add(Tools.suggestSkill); add(PlanTools.tool); add(ScheduledTask.tool)
            if (useDevice) addAll(DeviceTools.definitions)
            if (skills.skills.isNotEmpty()) add(Tools.useSkill)
        })
        start(id) {
            val started = System.currentTimeMillis()
            var cancelled = false
            try {
                // Memories go last in the system prompt; with many, picking the relevant ones may need an embedding.
                val systemText = if (memory.enabled) baseSystem + "\n\n" + memory.systemPrompt(question, api) else baseSystem
                val wire = history(systemText, conversation)
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
                val outsideContent = conversation.messages.any { it.documents.isNotEmpty() } || message(reply.id)?.citations?.isNotEmpty() == true
                val mcpTools = mcp.availableTools().filter { permissions.rule("mcp:${it.server}") != ToolPermissions.Rule.never }
                if (mcpTools.isNotEmpty()) {
                    val system = jsonString(messages[0]["content"]).orEmpty() +
                        "\n\nTools named <service>__<tool> belong to services the user connected (MCP). Use them when they fit the request."
                    messages = listOf(buildJsonObject { put("role", "system"); put("content", system) }) + messages.drop(1)
                }
                val readOutside = runTurn(model, messages, tools + mcpTools.map { it.definition }, reply.id, id, outsideContent, mcpTools)
                learn(question, reply.id, model, userOnly = readOutside)
            } catch (e: CancellationException) {
                cancelled = true
                throw e
            } catch (e: BlabladorException) {
                val message = if (e.status == 400 && e.body.contains("image", ignoreCase = true))
                    "${RemoteModel(model).displayName} can't read images. Pick a vision model such as DeepSeek-V4.1-Flash or Qwen3.8-27B."
                else e.message
                updateMessage(reply.id) { it.copy(content = message ?: "Request failed.", isError = true) }
            } catch (e: Exception) {
                updateMessage(reply.id) { it.copy(content = e.message ?: "Request failed.", isError = true) }
            } finally {
                val seconds = (System.currentTimeMillis() - started) / 1000.0
                updateMessage(reply.id) { m ->
                    val trace = m.trace?.let { t -> t.copy(seconds = seconds, calls = t.calls.map { if (it.state == StepState.running) it.copy(state = StepState.failed) else it }) }
                    val empty = m.content.isEmpty() && m.images.isEmpty() && m.audio.isEmpty() && m.videos.isEmpty() && !cancelled
                    if (empty) m.copy(status = null, trace = trace, content = "No response from the model.", isError = true) else m.copy(status = null, trace = trace)
                }
                persist()
                if (!cancelled) finished(reply.id, id, question, model, started, task)
            }
        }
    }

    /** After a reply: a notification when the user wasn't watching, and a skill drafted from a task of several steps. */
    private fun finished(replyId: String, chatId: String, question: String, model: String, started: Long, task: ScheduledTask?) {
        val reply = message(replyId) ?: return
        val app = getApplication<Application>()
        if (task != null || ((!appVisible || currentId != chatId) && System.currentTimeMillis() - started > 5_000)) {
            val body = when {
                reply.isError -> "Failed: ${reply.content}"
                reply.content.isEmpty() -> "The reply is ready."
                else -> splitThinking(reply.content).second
            }
            Notifier.notify(app, task?.title ?: conversations.firstOrNull { it.id == chatId }?.title ?: "Blablador", body, chatId)
        }
        val trace = reply.trace
        if (task != null || !draftsSkills || reply.isError || reply.skillsUsed.isNotEmpty() || reply.suggestedSkills.isNotEmpty() ||
            !SkillDrafter.worthDrafting(trace) || trace == null) return
        val existing = skills.skills.map { it.name }
        viewModelScope.launch {
            val skill = SkillDrafter.draft(question, trace, reply.content, existing, api, model) ?: return@launch
            updateMessage(replyId) { it.copy(suggestedSkills = it.suggestedSkills + skill) }
            persist()
        }
    }

    // MARK: Scheduled tasks

    /** Runs tasks that became due, one at a time, when no chat is busy. */
    fun checkTasks() {
        if (isBusy || apiKey.isEmpty()) return
        val task = tasks.due().firstOrNull() ?: return
        tasks.save(task.copy(lastRun = System.currentTimeMillis(), enabled = task.enabled && task.weekdays.isNotEmpty()))
        val chat = runTask(task)
        tasks.tasks.firstOrNull { it.id == task.id }?.let { tasks.save(it.copy(lastChat = chat)) }
    }

    fun runTaskNow(task: ScheduledTask) {
        if (isBusy) return
        tasks.save(task.copy(lastRun = System.currentTimeMillis()))
        runTask(task)
    }

    /** Runs a scheduled task in a new chat (not opened) and returns the chat's id. */
    private fun runTask(task: ScheduledTask): String {
        val date = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date())
        val message = ChatMessage(role = ChatRole.user, content = task.prompt,
            mentions = if (task.webSearch) listOf(Mention(Mention.Kind.tool, "web", "Web search")) else emptyList())
        val conversation = Conversation(title = "${task.title} · $date", model = selectedModel, messages = listOf(message))
        conversations.add(0, conversation)
        persist()
        respond(chatId = conversation.id, task = task)
        return conversation.id
    }

    /**
     * Streams the reply, running tools whenever the model asks for them. Memory changes are refused once the reply
     * has read outside content (web results, PDFs, knowledge bases, device data), so text planted there can't write
     * itself into every future chat.
     */
    private suspend fun runTurn(model: String, initial: List<JsonObject>, initialTools: List<JsonObject>, replyId: String, chatId: String, outside: Boolean, mcpTools: List<McpTool> = emptyList()): Boolean {
        val outsideContent = booleanArrayOf(outside)
        val messages = initial.toMutableList()
        var tools = initialTools
        var round = 0

        while (true) {
            val hasPlan = message(replyId)?.plan?.isNotEmpty() == true
            val maxRounds = if (hasPlan) maxOf(maxToolRounds, maxPlanRounds) else maxToolRounds
            val isFinalRound = round >= maxRounds
            round++
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
                        is BlabladorApi.StreamEvent.Usage -> updateMessage(replyId) { m ->
                            m.copy(trace = m.trace?.let { it.copy(promptTokens = it.promptTokens + event.prompt, completionTokens = it.completionTokens + event.completion) })
                        }
                    }
                }
                updateMessage(replyId) { m -> m.copy(trace = m.trace?.let { it.copy(rounds = it.rounds + 1) }) }
            } catch (e: BlabladorException) {
                // Model without tool support: answer without tools.
                if (e.status == 400 && tools.isNotEmpty() && round == 1 && !e.body.contains("image", ignoreCase = true)) {
                    tools = emptyList()
                    continue
                }
                throw e
            }

            if (isFinalRound || (calls.isEmpty() && containsToolMarkup(text))) {
                if (stripToolMarkup(text).isEmpty()) updateMessage(replyId) { it.copy(content = prefix) }
                return outsideContent[0]
            }
            if (calls.isEmpty()) return outsideContent[0]

            messages += buildJsonObject {
                put("role", "assistant")
                put("tool_calls", buildJsonArray { calls.forEach { add(it.wire) } })
                put("content", if (text.isEmpty()) JsonNull else JsonPrimitive(text))
            }
            // Preambles like "Let me look that up" are status, not part of the answer; notes between plan steps are kept.
            val note = stripToolMarkup(text)
            val keepsNotes = message(replyId)?.plan?.isNotEmpty() == true
            updateMessage(replyId) { it.copy(content = if (keepsNotes && note.isNotEmpty()) "$prefix$note\n\n" else prefix) }

            for (call in calls) {
                val arguments = runCatching { BlabladorApi.json.parseToJsonElement(call.arguments).jsonObject }.getOrNull()
                val started = System.currentTimeMillis()
                var traced = TraceCall(tool = call.name, arguments = call.arguments)
                updateMessage(replyId) { m -> m.copy(trace = m.trace?.let { it.copy(calls = it.calls + traced) }) }
                val (output, state) = execute(call.name, arguments, replyId, chatId, mcpTools, outsideContent)
                traced = traced.copy(result = output.take(4_000), seconds = (System.currentTimeMillis() - started) / 1000.0, state = state)
                updateMessage(replyId) { m -> m.copy(trace = m.trace?.let { t -> t.copy(calls = t.calls.map { if (it.id == traced.id) traced else it }) }) }
                messages += buildJsonObject { put("role", "tool"); put("tool_call_id", call.id); put("content", output) }
            }
            updateMessage(replyId) { it.copy(status = "Thinking…") }
        }
    }

    /** Runs one recorded tool call again and shows the new result in the trace (the reply itself stays). */
    fun rerun(callId: String, messageId: String) {
        val chat = chatContaining(messageId) ?: return
        var call = message(messageId)?.trace?.calls?.firstOrNull { it.id == callId } ?: return
        if (!canRerun(call.tool)) return
        val arguments = runCatching { BlabladorApi.json.parseToJsonElement(call.arguments).jsonObject }.getOrNull()
        fun write(updated: TraceCall) = updateMessage(messageId) { m -> m.copy(trace = m.trace?.let { t -> t.copy(calls = t.calls.map { if (it.id == updated.id) updated else it }) }) }
        call = call.copy(state = StepState.running)
        write(call)
        viewModelScope.launch {
            val started = System.currentTimeMillis()
            val (output, state) = execute(call.tool, arguments, messageId, chat.id, mcp.availableTools(), booleanArrayOf(true))
            write(call.copy(result = output.take(4_000), seconds = (System.currentTimeMillis() - started) / 1000.0, state = state))
            updateMessage(messageId) { it.copy(status = null) }
            persist()
        }
    }

    /** Runs one tool call after checking its permission, and returns what goes back to the model. */
    private suspend fun execute(name: String, arguments: JsonObject?, replyId: String, chatId: String, mcpTools: List<McpTool>, outsideContent: BooleanArray): Pair<String, StepState> {
        val query = jsonString(arguments?.get("query")).orEmpty()
        val prompt = jsonString(arguments?.get("prompt")).orEmpty()
        val script = jsonString(arguments?.get("script")).orEmpty()
        val app = getApplication<Application>()

        if ((name == "remember" || name == "forget") && outsideContent[0]) {
            return ("Memory can't be changed in a reply that used web results, documents, knowledge bases or device data, because they could contain planted instructions. " +
                "Tell the user they can ask again in a new message without them, or edit memories in Settings → Memory.") to StepState.denied
        }
        ToolPermissions.kind(name)?.let { kind ->
            var title = "Let Blablador use $name?"
            var detail = arguments?.let { prettyJson.encodeToString(JsonObject.serializer(), it) }.orEmpty()
            DeviceTools.approval(name, arguments)?.let { (t, d) -> title = t; detail = d }
            if (name == "schedule_task") ScheduledTask.fromArguments(arguments)?.let { title = "Schedule “${it.title}”?"; detail = it.scheduleText + "\n\n" + it.prompt }
            if (permissions.rule(kind) != ToolPermissions.Rule.allow) updateMessage(replyId) { it.copy(status = "Waiting for approval…") }
            if (!authorize(kind, chatId, title, detail)) {
                return "The user didn't allow $name (it can be changed in Settings → Permissions). Continue without it or ask what to do instead." to StepState.denied
            }
        }

        return when {
            name == "update_plan" -> {
                val items = PlanTools.items(arguments)
                updateMessage(replyId) { it.copy(plan = items) }
                PlanTools.summary(items) to StepState.done
            }
            (name == "generate_image" || name == "edit_image") && prompt.isNotEmpty() -> try {
                val image = runImageTool(name, prompt, latestImage(replyId), replyId)
                updateMessage(replyId) { it.copy(images = it.images + image) }
                "The image was created and is shown to the user. Do not include it or a link in your answer; just briefly comment on it." to StepState.done
            } catch (e: CancellationException) { throw e } catch (e: Exception) { "Image tool failed: ${e.message}" to StepState.failed }
            name == "generate_speech" && script.isNotEmpty() -> try {
                val audioName = runSpeechTool(script, replyId)
                updateMessage(replyId) { it.copy(audio = it.audio + audioName) }
                "The speech was created and the user can play it. Don't repeat the script; just briefly comment on it." to StepState.done
            } catch (e: CancellationException) { throw e } catch (e: Exception) { "Speech tool failed: ${e.message}" to StepState.failed }
            name == "use_skill" -> {
                val skill = skills.skill(jsonString(arguments?.get("name")).orEmpty())
                if (skill != null) {
                    updateMessage(replyId) { if (skill.name in it.skillsUsed) it else it.copy(skillsUsed = it.skillsUsed + skill.name) }
                    "Instructions of the skill \"${skill.name}\":\n\n${skill.instructions}" to StepState.done
                } else "There is no skill called \"${jsonString(arguments?.get("name"))}\"." to StepState.failed
            }
            name == "suggest_skill" && !jsonString(arguments?.get("instructions")).isNullOrBlank() -> {
                val skill = Skill(
                    name = jsonString(arguments?.get("name")).orEmpty().ifBlank { "New skill" },
                    description = jsonString(arguments?.get("description")).orEmpty(),
                    instructions = jsonString(arguments?.get("instructions")).orEmpty(),
                )
                updateMessage(replyId) { it.copy(suggestedSkills = it.suggestedSkills + skill) }
                "The suggestion is shown to the user with a Save button; it is not saved until they press it. Don't repeat the instructions; mention it in one sentence." to StepState.done
            }
            name == "search_chats" && query.isNotEmpty() -> {
                outsideContent[0] = true
                updateMessage(replyId) { it.copy(status = "Searching earlier chats…") }
                ChatSearch.find(query, conversations.toList(), chatId, api, chatIndex) to StepState.done
            }
            name == "remember" && memory.enabled -> {
                val fact = jsonString(arguments?.get("fact")).orEmpty().trim()
                if (memory.add(fact, conversations.firstOrNull { it.id == chatId })) {
                    updateMessage(replyId) { it.copy(remembered = it.remembered + fact) }
                    "Saved to memory." to StepState.done
                } else "Already remembered or empty; nothing saved." to StepState.done
            }
            name == "forget" && memory.enabled -> {
                val number = jsonString(arguments?.get("number"))?.toIntOrNull()
                val forgotten = number?.let(memory::forget)
                if (forgotten != null) {
                    updateMessage(replyId) { it.copy(forgotten = it.forgotten + forgotten.text) }
                    "Forgot: ${forgotten.text}. The numbers of later memories moved up by one." to StepState.done
                } else "There is no memory number $number." to StepState.failed
            }
            name == "schedule_task" -> {
                val task = ScheduledTask.fromArguments(arguments)
                    ?: return "Couldn't read the schedule: give title, prompt and time as HH:MM, optionally days or a date." to StepState.failed
                tasks.save(task)
                requestNotifications()
                val next = task.next()?.let { " Next run: ${DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it))}." }.orEmpty()
                "Scheduled “${task.title}”: ${task.scheduleText}.$next The user can change it in Settings → Scheduled tasks." to StepState.done
            }
            name in DeviceTools.names -> {
                if (!name.startsWith("create_")) outsideContent[0] = true
                updateMessage(replyId) {
                    it.copy(status = when (name) { "current_location" -> "Finding your location…"; "find_contacts" -> "Looking up contacts…"; else -> "Checking your calendar…" })
                }
                if (!DeviceTools.granted(app, name) && !requestPermissions(DeviceTools.permissions(name))) {
                    "No access. The user can allow it in the system settings for Blablador." to StepState.denied
                } else try {
                    DeviceTools.run(app, name, arguments) to StepState.done
                } catch (e: CancellationException) { throw e } catch (e: Exception) { (e.message ?: "Failed.") to StepState.failed }
            }
            name == "image_search" && query.isNotEmpty() -> {
                outsideContent[0] = true
                updateMessage(replyId) { it.copy(status = "Searching pictures of “$query”") }
                try {
                    val images = WebSearch.searchImages(query)
                    updateMessage(replyId) { message ->
                        message.copy(webImages = message.webImages + images.filter { image -> message.webImages.none { it.image == image.image } })
                    }
                    (if (images.isEmpty()) "No pictures found for \"$query\"."
                    else "${images.size} pictures are shown to the user: ${images.joinToString("; ") { it.title }}. Don't include image links in your answer.") to StepState.done
                } catch (e: CancellationException) { throw e } catch (e: Exception) { "Image search failed: ${e.message}" to StepState.failed }
            }
            name == "run_python" && !jsonString(arguments?.get("code")).isNullOrBlank() -> {
                outsideContent[0] = true
                runPython(jsonString(arguments?.get("code")).orEmpty(), replyId)
            }
            mcpTools.any { it.qualifiedName == name } -> {
                outsideContent[0] = true
                runMcpTool(mcpTools.first { it.qualifiedName == name }, arguments ?: JsonObject(emptyMap()), replyId, chatId)
            }
            name == "read_page" && !jsonString(arguments?.get("url")).isNullOrBlank() -> {
                outsideContent[0] = true
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
                    "[$number] ${page.title}\nURL: ${page.url}\n\n${page.text.ifEmpty { "(No readable text on this page.)" }}" to StepState.done
                } catch (e: CancellationException) { throw e } catch (e: Exception) { "Could not read the page: ${e.message}" to StepState.failed }
            }
            name == "web_search" && query.isNotEmpty() -> {
                outsideContent[0] = true
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
                    WebSearch.toolOutput(query, numbered) to StepState.done
                } catch (e: CancellationException) { throw e } catch (e: Exception) { "Search failed: ${e.message}" to StepState.failed }
            }
            else -> "Unknown tool $name, or its arguments are missing." to StepState.failed
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

    private fun updateChat(id: String, change: (Conversation) -> Conversation) {
        val index = conversations.indexOfFirst { it.id == id }
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
    private suspend fun runPython(code: String, replyId: String): Pair<String, StepState> {
        updateMessage(replyId) { it.copy(status = "Running Python…", toolCalls = it.toolCalls + "Python") }
        // Attached documents in /data: data files as they are, others as text.
        val files = withContext(Dispatchers.IO) {
            chatContaining(replyId)?.messages.orEmpty().flatMap { it.documents }.associate { document ->
                val name = document.name.replace("/", "_")
                val data = document.dataFile?.let { DataFiles.data(getApplication(), it) }
                if (data != null) name to data else (if (name.endsWith(".txt")) name else "$name.txt") to document.text.encodeToByteArray()
            }
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
            (if (output.isEmpty()) "The code ran without output." else output.takeLast(20_000)) to (if (result.error == null) StepState.done else StepState.failed)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            "Python failed: ${e.message}" to StepState.failed
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

    // MARK: Approvals and permissions

    /** A tool call waiting for the user's OK. */
    data class ToolApproval(val chat: String, val kind: String, val title: String, val detail: String,
                            val answer: kotlinx.coroutines.CompletableDeferred<ApprovalChoice>, val id: String = java.util.UUID.randomUUID().toString())

    enum class ApprovalChoice { Once, Chat, Always, Deny }

    /** Tool calls waiting for the user's OK, from any chat; the open chat shows its first one. */
    val approvals = mutableStateListOf<ToolApproval>()
    val toolApproval: ToolApproval? get() = approvals.firstOrNull { it.chat == currentId }

    fun answerApproval(choice: ApprovalChoice) { toolApproval?.let { answer(it, choice) } }

    private fun answer(approval: ToolApproval, choice: ApprovalChoice) {
        approvals.remove(approval)
        approval.answer.complete(choice)
    }

    /** Kinds of tools the user allowed for one chat ("<chat>|<kind>"), until the app quits. */
    private val chatAllowed = mutableSetOf<String>()

    /**
     * Whether a tool of this kind may run: by its rule in Settings → Permissions, the user's earlier "Allow for this
     * chat", or by asking now.
     */
    private suspend fun authorize(kind: String, chat: String, title: String, detail: String): Boolean {
        when (permissions.rule(kind)) {
            ToolPermissions.Rule.never -> return false
            ToolPermissions.Rule.allow -> return true
            ToolPermissions.Rule.ask -> {}
        }
        if ("$chat|$kind" in chatAllowed) return true
        if (chat != currentId || !appVisible) Notifier.notify(getApplication(), "Blablador needs your OK", title, chat)
        val deferred = kotlinx.coroutines.CompletableDeferred<ApprovalChoice>()
        val approval = ToolApproval(chat, kind, title, detail.take(2_000), deferred)
        approvals += approval
        val choice = try { deferred.await() } finally { approvals.remove(approval) }
        when (choice) {
            ApprovalChoice.Chat -> chatAllowed += "$chat|$kind"
            ApprovalChoice.Always -> permissions.set(kind, ToolPermissions.Rule.allow)
            else -> {}
        }
        return choice != ApprovalChoice.Deny
    }

    /** Android permissions the chat screen should ask for (device tools); answered with [answerPermissions]. */
    var permissionRequest by mutableStateOf<List<String>?>(null)
        private set
    private var permissionAnswer: kotlinx.coroutines.CompletableDeferred<Boolean>? = null

    private suspend fun requestPermissions(names: List<String>): Boolean {
        if (!appVisible) return false
        val deferred = kotlinx.coroutines.CompletableDeferred<Boolean>()
        permissionAnswer = deferred
        permissionRequest = names
        return try { deferred.await() } finally { permissionRequest = null; permissionAnswer = null }
    }

    fun answerPermissions(granted: Boolean) { permissionAnswer?.complete(granted) }

    /** Asks the screen for the notification permission (Android 13+) when something will notify later. */
    var wantsNotifications by mutableStateOf(false)
    private fun requestNotifications() { if (!Notifier.allowed(getApplication())) wantsNotifications = true }

    /** Runs a tool of a connected MCP server after the user's OK. */
    private suspend fun runMcpTool(tool: McpTool, arguments: JsonObject, replyId: String, chatId: String): Pair<String, StepState> {
        val server = mcp.server(tool.server)
        val shown = prettyJson.encodeToString(JsonObject.serializer(), arguments)
        if (permissions.rule("mcp:${tool.server}") != ToolPermissions.Rule.allow) updateMessage(replyId) { it.copy(status = "Waiting for approval…") }
        if (!authorize("mcp:${tool.server}", chatId, "Let ${server?.name ?: "this server"} use ${tool.name}?", shown)) {
            return "The user declined this tool call. Ask what to do instead or continue without it." to StepState.denied
        }
        updateMessage(replyId) { it.copy(status = "Using ${tool.name}…", toolCalls = it.toolCalls + "${server?.name ?: "Server"}: ${tool.name}") }
        return try {
            val (text, isError) = mcp.call(tool, arguments)
            (if (text.isEmpty()) "(The tool returned nothing.)" else text.take(30_000)) to (if (isError) StepState.failed else StepState.done)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            "Tool failed: ${e.message}" to StepState.failed
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

    /**
     * After a reply, in the background: indexes new messages for search_chats and saves what's worth keeping
     * from the exchange to long-term memory.
     */
    private fun learn(question: String, replyId: String, model: String, userOnly: Boolean) {
        val reply = message(replyId)
        if (question.isEmpty() || reply == null || reply.isError || reply.content.isEmpty()) return
        val chat = conversations.firstOrNull { c -> c.messages.any { it.id == replyId } }
        viewModelScope.launch {
            runCatching { chatIndex.update(conversations.toList(), api) }
            if (!memory.enabled || !memory.learnsAutomatically) return@launch
            val facts = runCatching { memory.learn(question, if (userOnly) null else reply.content, api, model, chat) }.getOrDefault(emptyList())
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

/**
 * Replies that were still empty when the app quit or was stopped (nothing is running after a restart) become an
 * error the user can regenerate, instead of looking like they are still being written.
 */
fun markingInterrupted(conversation: Conversation): Conversation = conversation.copy(messages = conversation.messages.map { m ->
    if (m.role == ChatRole.assistant && m.content.isEmpty() && !m.isError && m.images.isEmpty() && m.audio.isEmpty() && m.videos.isEmpty())
        m.copy(content = "The reply was interrupted. Tap Regenerate to try again.", isError = true)
    else m
})

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

/** Versions to keep when [tail] is replaced: its own earlier versions plus itself, and the next version number. */
fun versions(tail: List<ChatMessage>): Pair<List<List<ChatMessage>>, Int> {
    val earlier = tail.first().alternatives
    val all = earlier + listOf(listOf(tail.first().copy(alternatives = emptyList())) + tail.drop(1))
    return all to (all.maxOf { it.first().version } + 1)
}

/** The chat with the version [offset] steps away shown from [index] on, or null when there is none. */
fun messagesShowingVersion(messages: List<ChatMessage>, offset: Int, index: Int): List<ChatMessage>? {
    val tail = messages.drop(index)
    val current = listOf(tail.first().copy(alternatives = emptyList())) + tail.drop(1)
    val all = (tail.first().alternatives + listOf(current)).sortedBy { it.first().version }
    val position = all.indexOfFirst { it.first().id == messages[index].id }
    val target = position + offset
    if (position < 0 || target !in all.indices) return null
    val others = all.filterIndexed { i, _ -> i != target }
    val shown = all[target]
    return messages.take(index) + listOf(shown.first().copy(alternatives = others)) + shown.drop(1)
}
