package de.fz_juelich.blablador.ui

import androidx.compose.material.icons.outlined.ContentPaste
import android.content.Intent
import android.net.Uri
import android.speech.RecognizerIntent
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Brush
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material.icons.outlined.Balance
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Brush
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.DocumentScanner
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.Menu
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material.icons.outlined.Photo
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import coil.compose.AsyncImage
import de.fz_juelich.blablador.ChatViewModel
import de.fz_juelich.blablador.data.DataFiles
import de.fz_juelich.blablador.data.Incoming
import de.fz_juelich.blablador.data.BlabladorApi
import de.fz_juelich.blablador.data.Conversation
import de.fz_juelich.blablador.data.DocumentAttachment
import de.fz_juelich.blablador.data.ImageStore
import de.fz_juelich.blablador.data.Updates
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Calendar
import java.util.Locale

/** Full-screen pages on top of the chat. */
private sealed interface Page {
    data object Settings : Page
    data class Knowledge(val baseId: String? = null) : Page
    data object Decision : Page
    data object Voices : Page
    data object AddVoice : Page
    data object Memory : Page
    data object Skills : Page
    data object Mcp : Page
    data object Tasks : Page
    data object Permissions : Page
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(vm: ChatViewModel) {
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val pages = remember { mutableStateListOf<Page>().apply { if (vm.apiKey.isEmpty()) add(Page.Settings) } }
    fun open(page: Page) { pages.add(page) }
    fun close() { pages.removeLastOrNull() }

    // Composer state lives here so images in the chat can start an edit.
    var draft by remember { mutableStateOf("") }
    val attachments = remember { mutableStateListOf<ByteArray>() }
    val documents = remember { mutableStateListOf<DocumentAttachment>() }
    var imageMode by remember { mutableStateOf(false) }
    var speechMode by remember { mutableStateOf(false) }
    var videoMode by remember { mutableStateOf(false) }
    val mentions = remember { mutableStateListOf<de.fz_juelich.blablador.data.Mention>() }
    val focus = remember { FocusRequester() }

    // Device tools ask for Android permissions when they first run; tasks and background replies notify.
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        vm.answerPermissions(results.isNotEmpty() && results.values.all { it })
    }
    LaunchedEffect(vm.permissionRequest) { vm.permissionRequest?.let { permissionLauncher.launch(it.toTypedArray()) } }
    val notificationLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { vm.wantsNotifications = false }
    LaunchedEffect(vm.wantsNotifications) {
        if (vm.wantsNotifications) {
            if (android.os.Build.VERSION.SDK_INT >= 33) notificationLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
            else vm.wantsNotifications = false
        }
    }

    val speaker = rememberSpeaker()

    // Shares, files opened with Blablador, blablador:// links and shortcuts: one new chat each, never sent by
    // itself (except blablador://ask, which is a question to send).
    var addingMemory by remember { mutableStateOf(false) }
    LaunchedEffect(vm.incoming) {
        when (val incoming = vm.claimIncoming()) {
            is Incoming.Ask -> {
                if (vm.apiKey.isNotEmpty()) pages.clear()
                vm.newChat()
                vm.send(incoming.question)
            }
            is Incoming.Share -> {
                if (vm.apiKey.isNotEmpty()) pages.clear()
                vm.newChat()
                draft = incoming.text
                attachments.clear()
                documents.clear()
                for (file in incoming.files) {
                    val name = file.name
                    val uri = android.net.Uri.fromFile(file)
                    runCatching {
                        when {
                            name.substringAfterLast('.', "").lowercase() in listOf("jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp") -> {
                                val data = withContext(Dispatchers.IO) { file.readBytes() }
                                attachments.add(withContext(Dispatchers.Default) { ImageStore.jpeg(data, 2048, 90) } ?: data)
                            }
                            name.endsWith(".pdf", ignoreCase = true) -> documents.add(vm.readPdf(uri))
                            DataFiles.supports(name) -> documents.add(vm.attachDataFile(uri, name))
                        }
                    }
                    file.delete()
                }
                if (incoming.focus) runCatching { focus.requestFocus() }
            }
            Incoming.AddMemory -> addingMemory = true
            is Incoming.OpenChat -> vm.conversations.firstOrNull { it.id == incoming.id }?.let { pages.clear(); vm.select(it) }
            Incoming.Tasks -> vm.checkTasks()
            null -> {}
        }
    }
    if (addingMemory) {
        var fact by remember { mutableStateOf("") }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { addingMemory = false },
            title = { Text("Add to memory") },
            text = {
                androidx.compose.material3.OutlinedTextField(fact, { fact = it }, placeholder = { Text("What should Blablador remember?") })
            },
            confirmButton = {
                TextButton(onClick = { vm.memory.add(fact); addingMemory = false }, enabled = fact.isNotBlank()) { Text("Remember") }
            },
            dismissButton = { TextButton(onClick = { addingMemory = false }) { Text("Cancel") } },
        )
    }

    when (val page = pages.lastOrNull()) {
        Page.Settings -> {
            SettingsScreen(vm, onOpenKnowledge = { open(Page.Knowledge()) }, onOpenVoices = { open(Page.Voices) },
                onOpenDecision = { open(Page.Decision) }, onOpenMemory = { open(Page.Memory) }, onOpenSkills = { open(Page.Skills) }, onOpenMcp = { open(Page.Mcp) },
                onOpenTasks = { open(Page.Tasks) }, onOpenPermissions = { open(Page.Permissions) }, onClose = ::close)
            return
        }
        is Page.Knowledge -> { KnowledgeScreen(vm, page.baseId, onClose = ::close); return }
        Page.Decision -> { DecisionScreen(vm, onClose = ::close); return }
        Page.Voices -> { VoicesScreen(vm, onClone = { open(Page.AddVoice) }, onClose = ::close); return }
        Page.AddVoice -> { AddVoiceScreen(vm, onClose = ::close); return }
        Page.Memory -> {
            MemoryScreen(vm, onClose = ::close, onOpenChat = { id ->
                vm.conversations.firstOrNull { it.id == id }?.let { vm.select(it); pages.clear() }
            })
            return
        }
        Page.Skills -> { SkillsScreen(vm, onClose = ::close); return }
        Page.Mcp -> { McpScreen(vm, onClose = ::close); return }
        Page.Tasks -> { TasksScreen(vm, onClose = ::close); return }
        Page.Permissions -> { PermissionsScreen(vm, onClose = ::close); return }
        null -> {}
    }

    vm.toolApproval?.let { approval ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { vm.answerApproval(ChatViewModel.ApprovalChoice.Deny) },
            title = { Text(approval.title) },
            text = {
                Text(approval.detail, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState()))
            },
            confirmButton = {
                Row {
                    var more by remember { mutableStateOf(false) }
                    Box {
                        TextButton(onClick = { more = true }) { Text("Allow more") }
                        DropdownMenu(expanded = more, onDismissRequest = { more = false }) {
                            DropdownMenuItem(text = { Text("Allow for this chat") }, onClick = { more = false; vm.answerApproval(ChatViewModel.ApprovalChoice.Chat) })
                            DropdownMenuItem(text = { Text("Always allow") }, onClick = { more = false; vm.answerApproval(ChatViewModel.ApprovalChoice.Always) })
                        }
                    }
                    TextButton(onClick = { vm.answerApproval(ChatViewModel.ApprovalChoice.Once) }) { Text("Allow") }
                }
            },
            dismissButton = { TextButton(onClick = { vm.answerApproval(ChatViewModel.ApprovalChoice.Deny) }) { Text("Deny") } },
        )
    }

    ModalNavigationDrawer(
        drawerState = drawer,
        drawerContent = {
            HistoryDrawer(vm, onPick = { scope.launch { drawer.close() } })
        },
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    navigationIcon = { IconButton(onClick = { scope.launch { drawer.open() } }) { Icon(Icons.Outlined.Menu, "Chats") } },
                    title = { ModelMenu(vm) },
                    actions = {
                        IconButton(onClick = { vm.newChat(); draft = ""; attachments.clear(); documents.clear() }, enabled = vm.currentId != null) {
                            Icon(Icons.Outlined.EditNote, "New chat")
                        }
                        IconButton(onClick = { open(Page.Settings) }) { Icon(Icons.Outlined.Settings, "Settings") }
                    },
                )
            },
        ) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
                UpdateBanner()
                Box(Modifier.weight(1f)) {
                    val conversation = vm.current
                    if (conversation == null || conversation.messages.isEmpty()) {
                        Welcome(vm.userName) { vm.send(it) }
                    } else {
                        MessageList(conversation, vm, speaker, onContinueVideo = { name ->
                            scope.launch {
                                vm.videos.lastFrame(name)?.let {
                                    attachments.clear(); attachments.add(it)
                                    if (draft.isEmpty()) draft = vm.promptForVideo(name).orEmpty()
                                    videoMode = true; imageMode = false; speechMode = false
                                    focus.requestFocus()
                                }
                            }
                        }) { name ->
                            vm.images.data(name)?.let {
                                attachments.clear(); attachments.add(it)
                                imageMode = true
                                speechMode = false
                                focus.requestFocus()
                            }
                        }
                    }
                }
                ActiveKnowledge(vm, onOpen = { open(Page.Knowledge(it)) })
                Composer(
                    vm, draft, { draft = it }, attachments, documents, mentions,
                    imageMode, { imageMode = it; if (it) { speechMode = false; videoMode = false } },
                    speechMode, { speechMode = it; if (it) { imageMode = false; videoMode = false } },
                    videoMode, { videoMode = it; if (it) { imageMode = false; speechMode = false } },
                    focus,
                    onNavigate = ::open,
                ) {
                    val text = draft
                    val images = attachments.toList()
                    val docs = documents.toList()
                    val mentioned = mentions.toList()
                    draft = ""; attachments.clear(); documents.clear(); mentions.clear()
                    vm.send(text, images, docs, mentioned, createImage = imageMode, createVideo = videoMode, speak = speechMode)
                }
            }
        }
    }
}

@Composable
private fun ModelMenu(vm: ChatViewModel) {
    var open by remember { mutableStateOf(false) }
    Column(Modifier.clickable { open = true }) {
        Text("Blablador", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(vm.selectedModelName + " ▾", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (vm.chatModels.isEmpty()) DropdownMenuItem(text = { Text(vm.modelsError ?: "Loading models…") }, onClick = {}, enabled = false)
            vm.chatModels.forEach { model ->
                DropdownMenuItem(
                    text = { Text(model.displayName) },
                    leadingIcon = { if (model.id == vm.selectedModel) Icon(Icons.Outlined.Check, null) else Spacer(Modifier.size(24.dp)) },
                    onClick = { vm.selectModel(model.id); open = false },
                )
            }
        }
    }
}

@Composable
private fun HistoryDrawer(vm: ChatViewModel, onPick: () -> Unit) {
    var query by remember { mutableStateOf("") }
    ModalDrawerSheet(Modifier.width(320.dp)) {
        Column(Modifier.padding(12.dp)) {
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), placeholder = { Text("Search chats") },
                leadingIcon = { Icon(Icons.Outlined.Search, null) }, singleLine = true, shape = RoundedCornerShape(24.dp))
            Spacer(Modifier.height(8.dp))
            NavigationDrawerItem(label = { Text("New chat") }, icon = { Icon(Icons.Outlined.EditNote, null) }, selected = false,
                onClick = { vm.newChat(); onPick() })
            Text("Recent", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp))
        }
        val shown = vm.conversations.filter { c ->
            query.isBlank() || c.title.contains(query, true) || c.messages.any { it.content.contains(query, true) }
        }
        LazyColumn(contentPadding = PaddingValues(horizontal = 12.dp)) {
            items(shown, key = { it.id }) { conversation ->
                var menu by remember { mutableStateOf(false) }
                Box {
                    NavigationDrawerItem(
                        label = { Text(conversation.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        selected = conversation.id == vm.currentId,
                        onClick = { vm.select(conversation); onPick() },
                        badge = {
                            IconButton(onClick = { menu = true }, Modifier.size(32.dp)) {
                                Icon(Icons.Outlined.DeleteOutline, "Delete", Modifier.size(18.dp))
                            }
                        },
                    )
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Delete chat", color = MaterialTheme.colorScheme.error) },
                            onClick = { vm.delete(conversation); menu = false })
                    }
                }
            }
        }
    }
}

@Composable
private fun Welcome(userName: String, onPick: (String) -> Unit) {
    val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
    val salutation = when (hour) { in 5..11 -> "Good morning"; in 12..17 -> "Good afternoon"; in 18..21 -> "Good evening"; else -> "Hello" }
    val suggestions: List<Pair<ImageVector, String>> = listOf(
        Icons.Outlined.Lightbulb to "Explain quantum computing in simple terms",
        Icons.Outlined.EditNote to "Help me write an email to my team",
        Icons.Outlined.Code to "Write a Python script to rename files",
        Icons.Outlined.Public to "Plan a weekend trip to Jülich",
    )
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(28.dp)) {
        Spacer(Modifier.height(24.dp))
        Column {
            Text(if (userName.isEmpty()) salutation else "$salutation, $userName", fontSize = 34.sp, fontWeight = FontWeight.SemiBold,
                style = MaterialTheme.typography.headlineLarge.copy(brush = Brand.gradient))
            Text("How can I help you today?", fontSize = 34.sp, fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f), lineHeight = 40.sp)
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            suggestions.forEach { (icon, text) ->
                Column(
                    Modifier.size(160.dp).clip(RoundedCornerShape(18.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
                        .clickable { onPick(text) }.padding(14.dp),
                    verticalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(text, style = MaterialTheme.typography.bodyMedium)
                    Icon(icon, null, Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.background).padding(8.dp))
                }
            }
        }
    }
}

@Composable
private fun MessageList(conversation: Conversation, vm: ChatViewModel, speaker: Speaker, onContinueVideo: (String) -> Unit, onEditImage: (String) -> Unit) {
    val state = rememberLazyListState()
    val last = conversation.messages.lastOrNull()
    LaunchedEffect(conversation.messages.size, last?.content?.length, last?.images?.size) {
        state.scrollToItem(maxOf(0, conversation.messages.size - 1), Int.MAX_VALUE / 2)
    }
    LazyColumn(state = state, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(20.dp),
        modifier = Modifier.fillMaxSize()) {
        items(conversation.messages, key = { it.id }) { message ->
            MessageItem(
                message = message,
                isLast = message.id == last?.id,
                isStreaming = vm.isStreaming,
                imageFile = vm.images::file,
                speaking = speaker.speakingId == message.id,
                onSpeak = { speaker.toggle(message.id, message.content) },
                onRegenerate = { vm.regenerate(it) },
                models = vm.chatModels.map { it.id to it.displayName },
                onEdit = { vm.edit(message.id, it) },
                onShowVersion = { vm.showVersion(message.id, it) },
                onEditImage = onEditImage,
                speechClip = { SpeechClip(vm, it) },
                videoFile = vm.videos::file,
                onContinueVideo = onContinueVideo,
                isSkillSaved = { vm.skills.skill(it) != null },
                onSaveSkill = vm.skills::save,
                canRerun = vm::canRerun,
                onRerun = { vm.rerun(it, message.id) },
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Composer(
    vm: ChatViewModel,
    draft: String,
    onDraft: (String) -> Unit,
    attachments: MutableList<ByteArray>,
    documents: MutableList<DocumentAttachment>,
    mentions: MutableList<de.fz_juelich.blablador.data.Mention>,
    imageMode: Boolean,
    onImageMode: (Boolean) -> Unit,
    speechMode: Boolean,
    onSpeechMode: (Boolean) -> Unit,
    videoMode: Boolean,
    onVideoMode: (Boolean) -> Unit,
    focus: FocusRequester,
    onNavigate: (Page) -> Unit,
    onSend: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var naming by remember { mutableStateOf(false) }
    var reading by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }
    val canSend = reading == 0 && (draft.isNotBlank() || attachments.isNotEmpty() || documents.isNotEmpty())

    fun addPhoto(uri: Uri) = scope.launch {
        val data = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } } ?: return@launch
        attachments.add(withContext(Dispatchers.Default) { ImageStore.jpeg(data, 2048, 90) } ?: data)
    }

    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(4)) { uris -> uris.forEach { addPhoto(it) } }
    var cameraUri by remember { mutableStateOf<Uri?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { taken -> if (taken) cameraUri?.let { addPhoto(it) } }
    val pdfs = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        // Images become photo attachments, PDFs are read into text, data files are kept for Python.
        uris.forEach { uri ->
            val type = context.contentResolver.getType(uri).orEmpty()
            val name = context.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: uri.lastPathSegment.orEmpty()
            when {
                type.startsWith("image/") -> addPhoto(uri)
                type == "application/pdf" || name.endsWith(".pdf", ignoreCase = true) -> {
                    reading++
                    scope.launch {
                        try { documents.add(vm.readPdf(uri)) } catch (e: Exception) { error = e.message } finally { reading-- }
                    }
                }
                DataFiles.supports(name) -> scope.launch {
                    try { documents.add(vm.attachDataFile(uri, name)) } catch (e: Exception) { error = "$name: ${e.message}" }
                }
                else -> error = "$name: only images, PDFs and data files (CSV, Excel, JSON…) can be attached."
            }
        }
    }
    val ocrPhotos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(10)) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        reading++
        scope.launch {
            try {
                uris.forEachIndexed { index, uri ->
                    val data = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } } ?: return@forEachIndexed
                    val name = if (uris.size > 1) "Photo text ${index + 1}" else "Photo text"
                    runCatching { documents.add(vm.readPhotoText(data, name)) }.onFailure { error = "$name: ${it.message}" }
                }
            } finally { reading-- }
        }
    }
    val dictation = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val spoken = result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull() ?: return@rememberLauncherForActivityResult
        onDraft(if (draft.isBlank()) spoken else "$draft $spoken")
    }

    Column(
        Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(28.dp)).background(MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 6.dp, vertical = 4.dp),
    ) {
        if (attachments.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()).padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            attachments.forEachIndexed { index, data ->
                Box {
                    AsyncImage(model = data, contentDescription = null, contentScale = ContentScale.Crop,
                        modifier = Modifier.size(64.dp).clip(RoundedCornerShape(12.dp)))
                    Icon(Icons.Filled.Close, "Remove image", tint = Color.White,
                        modifier = Modifier.align(Alignment.TopEnd).padding(3.dp).size(18.dp).clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.6f)).clickable { attachments.removeAt(index) })
                }
            }
        }
        if (documents.isNotEmpty() || reading > 0) Row(Modifier.horizontalScroll(rememberScrollState()).padding(8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            documents.forEach { document -> DocumentChip(document) { documents.remove(document) } }
            if (reading > 0) Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(6.dp))
                Text("Reading text…", style = MaterialTheme.typography.labelMedium)
            }
        }
        if (mentions.isNotEmpty()) MentionChips(mentions.toList()) { mention -> mentions.removeAll { it.id == mention.id } }
        mentionQuery(draft)?.let { query ->
            val all = de.fz_juelich.blablador.data.Mentions.all(vm.skills.skills.toList(), vm.knowledge.bases.map { it.id to it.name }, vm.mcp.servers.toList())
            MentionSuggestions(query, all) { mention ->
                onDraft(draft.replace(mentionPattern, { if (it.value.startsWith("@")) "" else " " }))
                if (mentions.none { it.id == mention.id }) mentions.add(mention)
            }
        }
        AnimatedVisibility(imageMode) { ImageModeChip(vm, editing = attachments.isNotEmpty()) { onImageMode(false) } }
        AnimatedVisibility(videoMode) { VideoModeChip(vm, fromImage = attachments.isNotEmpty()) { onVideoMode(false) } }
        AnimatedVisibility(speechMode) {
            Row(Modifier.padding(start = 8.dp, top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SpeechModeChip(vm, onCloneVoice = { onNavigate(Page.AddVoice) }) { onSpeechMode(false) }
                SpeechMarkupMenu(draft, onDraft)
            }
        }
        Row(verticalAlignment = Alignment.Bottom) {
            IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.Add, "Add and tools") }
            TextField(
                value = draft, onValueChange = onDraft,
                modifier = Modifier.weight(1f).focusRequester(focus),
                placeholder = {
                    Text(when {
                        imageMode -> if (attachments.isEmpty()) "Describe an image" else "Describe the change"
                        videoMode -> if (attachments.isEmpty()) "Describe a video, with its sounds" else "Describe what happens next"
                        speechMode -> "What should ${vm.voices.selected.name} say?"
                        else -> "Ask Blablador"
                    })
                },
                maxLines = 6,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                ),
            )
            IconButton(onClick = {
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                runCatching { dictation.launch(intent) }.onFailure { error = "Speech recognition isn't available on this device." }
            }) { Icon(Icons.Outlined.Mic, "Dictate") }
            when {
                vm.isStreaming -> IconButton(onClick = vm::stop) {
                    Icon(Icons.Filled.Stop, "Stop generating", Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.onSurface).padding(8.dp),
                        tint = MaterialTheme.colorScheme.surface)
                }
                canSend -> IconButton(onClick = onSend) {
                    Icon(when { imageMode -> Icons.Filled.Brush; videoMode -> Icons.Filled.Movie; speechMode -> Icons.Filled.GraphicEq; else -> Icons.Filled.ArrowUpward },
                        when { imageMode -> "Create image"; videoMode -> "Create video"; speechMode -> "Speak"; else -> "Send" },
                        Modifier.clip(CircleShape).background(Brand.gradient).padding(8.dp), tint = Color.White)
                }
            }
        }
    }
    if (menu) androidx.compose.material3.ModalBottomSheet(onDismissRequest = { menu = false }) {
        ToolsPanel(vm, imageMode, videoMode, speechMode,
            onMode = { mode ->
                when (mode) {
                    "image" -> onImageMode(true)
                    "video" -> onVideoMode(true)
                    "speech" -> onSpeechMode(true)
                    else -> { onImageMode(false); onVideoMode(false); onSpeechMode(false) }
                }
            },
            onAction = { action ->
                menu = false
                when (action) {
                    PanelAction.Camera -> {
                        val file = File(context.cacheDir, "camera").apply { mkdirs() }.let { File(it, "photo.jpg") }
                        cameraUri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
                        camera.launch(cameraUri!!)
                    }
                    PanelAction.Photos -> photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    PanelAction.Paste -> {
                        // Images copied in other apps arrive as content URIs on the clipboard.
                        val clipboard = context.getSystemService(android.content.ClipboardManager::class.java)
                        val clip = clipboard?.primaryClip
                        val uris = (0 until (clip?.itemCount ?: 0)).mapNotNull { clip?.getItemAt(it)?.uri }
                            .filter { context.contentResolver.getType(it)?.startsWith("image/") == true }
                        if (uris.isEmpty()) error = "The clipboard has no image. Copy an image first, then choose Paste."
                        else uris.forEach { addPhoto(it) }
                    }
                    PanelAction.Files -> pdfs.launch(arrayOf("application/pdf", "image/*") + DataFiles.MIME_TYPES)
                    PanelAction.ScanText -> ocrPhotos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    PanelAction.Decide -> onNavigate(Page.Decision)
                    PanelAction.Knowledge -> onNavigate(Page.Knowledge())
                    PanelAction.NewKnowledge -> naming = true
                    PanelAction.Mcp -> onNavigate(Page.Mcp)
                    PanelAction.Skills -> onNavigate(Page.Skills)
                    PanelAction.Tasks -> onNavigate(Page.Tasks)
                    PanelAction.Permissions -> onNavigate(Page.Permissions)
                }
            })
    }
    if (naming) NameDialog("New knowledge base", "", onDismiss = { naming = false }) { name ->
        naming = false
        val base = vm.knowledge.create(name)
        vm.toggleKnowledge(base.id)
        onNavigate(Page.Knowledge(base.id))
    }
    error?.let { message ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { error = null },
            confirmButton = { TextButton(onClick = { error = null }) { Text("OK") } },
            title = { Text("Couldn't read text") },
            text = { Text(message) },
        )
    }
}

/** An "@name" being typed at the end of the draft. */
private val mentionPattern = Regex("""(^|\s)@[^\s@]*$""")

private fun mentionQuery(draft: String): String? = mentionPattern.find(draft)?.value?.substringAfter('@')

/** Knowledge bases searched in this chat; tap to open, × to stop using. */
@Composable
private fun ActiveKnowledge(vm: ChatViewModel, onOpen: (String) -> Unit) {
    val active = vm.activeKnowledge.mapNotNull(vm.knowledge::base)
    if (active.isEmpty()) return
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        active.forEach { base ->
            Row(
                Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant).clickable { onOpen(base.id) }
                    .padding(start = 10.dp, end = 6.dp, top = 5.dp, bottom = 5.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(Icons.AutoMirrored.Outlined.LibraryBooks, null, Modifier.size(14.dp), tint = Brand.violet)
                Text(vm.knowledge.progress[base.id] ?: base.name, style = MaterialTheme.typography.labelMedium, maxLines = 1)
                Icon(Icons.Filled.Close, "Stop using ${base.name}", Modifier.size(16.dp).clickable { vm.toggleKnowledge(base.id) })
            }
        }
    }
}

@Composable
private fun VideoModeChip(vm: ChatViewModel, fromImage: Boolean, onClose: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(
        Modifier.padding(start = 8.dp, top = 6.dp).clip(CircleShape).background(Brand.gradient).padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(Icons.Filled.Movie, null, Modifier.size(14.dp), tint = Color.White)
        Box {
            Text(if (fromImage) "Video from image · ${vm.videoSeconds} s ▾" else "Video · ${vm.videoSeconds} s · ${vm.videoAspectName} ▾", color = Color.White,
                style = MaterialTheme.typography.labelMedium, modifier = Modifier.clickable { menu = true })
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                BlabladorApi.VIDEO_DURATIONS.forEach { seconds ->
                    DropdownMenuItem(text = { Text("$seconds seconds") }, onClick = { vm.chooseVideoSeconds(seconds); menu = false },
                        leadingIcon = { if (seconds == vm.videoSeconds) Icon(Icons.Outlined.Check, null) else Spacer(Modifier.size(24.dp)) })
                }
                if (!fromImage) HorizontalDivider()
                if (!fromImage) BlabladorApi.VIDEO_ASPECTS.forEach { (id, name) ->
                    DropdownMenuItem(text = { Text("$name $id") }, onClick = { vm.chooseVideoAspect(id); menu = false },
                        leadingIcon = { if (id == vm.videoAspect) Icon(Icons.Outlined.Check, null) else Spacer(Modifier.size(24.dp)) })
                }
            }
        }
        Icon(Icons.Filled.Close, "Leave video mode", Modifier.size(14.dp).clickable(onClick = onClose), tint = Color.White)
    }
}

@Composable
private fun ImageModeChip(vm: ChatViewModel, editing: Boolean, onClose: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(
        Modifier.padding(start = 8.dp, top = 6.dp).clip(CircleShape).background(Brand.gradient).padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(Icons.Filled.Brush, null, Modifier.size(14.dp), tint = Color.White)
        Box {
            Text(if (editing) "Edit image · Qwen-Image" else vm.imageModelName + " ▾", color = Color.White,
                style = MaterialTheme.typography.labelMedium, modifier = Modifier.clickable(enabled = !editing) { menu = true })
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                BlabladorApi.IMAGE_MODELS.forEach { (id, name) ->
                    DropdownMenuItem(text = { Text(name) }, onClick = { vm.selectImageModel(id); menu = false },
                        leadingIcon = { if (id == vm.imageModel) Icon(Icons.Outlined.Check, null) else Spacer(Modifier.size(24.dp)) })
                }
            }
        }
        Icon(Icons.Filled.Close, "Leave image mode", Modifier.size(14.dp).clickable(onClick = onClose), tint = Color.White)
    }
}

/** Read-aloud with the system text-to-speech engine. */
class Speaker {
    var speakingId by mutableStateOf<String?>(null)
    var tts: TextToSpeech? = null

    fun toggle(id: String, text: String) {
        val engine = tts ?: return
        engine.stop()
        if (speakingId == id) { speakingId = null; return }
        speakingId = id
        engine.speak(speakable(text), TextToSpeech.QUEUE_FLUSH, null, id)
    }

    /** Skips Markdown symbols, citation markers and code blocks. */
    private fun speakable(text: String) = text
        .replace(Regex("""```[\s\S]*?```"""), " ")
        .replace(Regex("""\[\d+]"""), "")
        .replace(Regex("""[*_#`>|]+"""), "")
        .replace(Regex("""\[([^\]]+)]\([^)]+\)"""), "$1")
}

@Composable
private fun rememberSpeaker(): Speaker {
    val context = LocalContext.current
    val speaker = remember { Speaker() }
    DisposableEffect(Unit) {
        val engine = TextToSpeech(context) { status ->
            if (status == TextToSpeech.SUCCESS) speaker.tts?.language = Locale.getDefault()
        }
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) { if (speaker.speakingId == utteranceId) speaker.speakingId = null }
            @Deprecated("Deprecated in Java") override fun onError(utteranceId: String?) { speaker.speakingId = null }
        })
        speaker.tts = engine
        onDispose { engine.shutdown() }
    }
    return speaker
}

/** Tells the user when a newer version is on GitHub, with a link to the APK. */
@Composable
private fun UpdateBanner() {
    val context = LocalContext.current
    var release by remember { mutableStateOf<Updates.Release?>(null) }
    LaunchedEffect(Unit) {
        release = Updates.latest(context)?.takeIf { it.version != Updates.dismissed(context) }
    }
    val current = release ?: return
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp).clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.primaryContainer).padding(start = 14.dp, top = 6.dp, bottom = 6.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("Blablador ${current.version} is available", style = MaterialTheme.typography.titleSmall)
            Text("You have ${Updates.currentVersion(context)}. Download and open the APK to update.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onPrimaryContainer)
        }
        TextButton(onClick = {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(current.apk ?: current.page)))
        }) { Text("Download") }
        IconButton(onClick = { Updates.dismiss(context, current.version); release = null }) {
            Icon(Icons.Default.Close, "Hide until the next version")
        }
    }
}
