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
    val focus = remember { FocusRequester() }

    val speaker = rememberSpeaker()

    when (val page = pages.lastOrNull()) {
        Page.Settings -> {
            SettingsScreen(vm, onOpenKnowledge = { open(Page.Knowledge()) }, onOpenVoices = { open(Page.Voices) },
                onOpenDecision = { open(Page.Decision) }, onClose = ::close)
            return
        }
        is Page.Knowledge -> { KnowledgeScreen(vm, page.baseId, onClose = ::close); return }
        Page.Decision -> { DecisionScreen(vm, onClose = ::close); return }
        Page.Voices -> { VoicesScreen(vm, onClone = { open(Page.AddVoice) }, onClose = ::close); return }
        Page.AddVoice -> { AddVoiceScreen(vm, onClose = ::close); return }
        null -> {}
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
                        MessageList(conversation, vm, speaker) { name ->
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
                    vm, draft, { draft = it }, attachments, documents,
                    imageMode, { imageMode = it; if (it) speechMode = false },
                    speechMode, { speechMode = it; if (it) imageMode = false },
                    focus,
                    onNavigate = ::open,
                ) {
                    val text = draft
                    val images = attachments.toList()
                    val docs = documents.toList()
                    draft = ""; attachments.clear(); documents.clear()
                    vm.send(text, images, docs, imageMode, speechMode)
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
private fun MessageList(conversation: Conversation, vm: ChatViewModel, speaker: Speaker, onEditImage: (String) -> Unit) {
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
                onRegenerate = vm::regenerate,
                onEditImage = onEditImage,
                speechClip = { SpeechClip(vm, it) },
            )
        }
    }
}

@Composable
private fun Composer(
    vm: ChatViewModel,
    draft: String,
    onDraft: (String) -> Unit,
    attachments: MutableList<ByteArray>,
    documents: MutableList<DocumentAttachment>,
    imageMode: Boolean,
    onImageMode: (Boolean) -> Unit,
    speechMode: Boolean,
    onSpeechMode: (Boolean) -> Unit,
    focus: FocusRequester,
    onNavigate: (Page) -> Unit,
    onSend: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var knowledgeMenu by remember { mutableStateOf(false) }
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
        // Images become photo attachments; PDFs are read into text.
        uris.forEach { uri ->
            if (context.contentResolver.getType(uri)?.startsWith("image/") == true) addPhoto(uri)
            else {
                reading++
                scope.launch {
                    try { documents.add(vm.readPdf(uri)) } catch (e: Exception) { error = e.message } finally { reading-- }
                }
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
        AnimatedVisibility(imageMode) { ImageModeChip(vm, editing = attachments.isNotEmpty()) { onImageMode(false) } }
        AnimatedVisibility(speechMode) {
            Row(Modifier.padding(start = 8.dp, top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SpeechModeChip(vm, onCloneVoice = { onNavigate(Page.AddVoice) }) { onSpeechMode(false) }
                SpeechMarkupMenu(draft, onDraft)
            }
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.Add, "Add") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Camera") }, leadingIcon = { Icon(Icons.Outlined.CameraAlt, null) }, onClick = {
                        menu = false
                        val file = File(context.cacheDir, "camera").apply { mkdirs() }.let { File(it, "photo.jpg") }
                        cameraUri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
                        camera.launch(cameraUri!!)
                    })
                    DropdownMenuItem(text = { Text("Photos") }, leadingIcon = { Icon(Icons.Outlined.Photo, null) }, onClick = {
                        menu = false; photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    })
                    DropdownMenuItem(text = { Text("Paste image") }, leadingIcon = { Icon(Icons.Outlined.ContentPaste, null) }, onClick = {
                        menu = false
                        // Images copied in other apps arrive as content URIs on the clipboard.
                        val clipboard = context.getSystemService(android.content.ClipboardManager::class.java)
                        val clip = clipboard?.primaryClip
                        val uris = (0 until (clip?.itemCount ?: 0)).mapNotNull { clip?.getItemAt(it)?.uri }
                            .filter { context.contentResolver.getType(it)?.startsWith("image/") == true }
                        if (uris.isEmpty()) error = "The clipboard has no image. Copy an image first, then choose Paste image."
                        else uris.forEach { addPhoto(it) }
                    })
                    DropdownMenuItem(text = { Text("File (image or PDF)") }, leadingIcon = { Icon(Icons.Outlined.PictureAsPdf, null) }, onClick = {
                        menu = false; pdfs.launch(arrayOf("application/pdf", "image/*"))
                    })
                    DropdownMenuItem(text = { Text("Text from photo") }, leadingIcon = { Icon(Icons.Outlined.DocumentScanner, null) }, onClick = {
                        menu = false; ocrPhotos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("Knowledge") }, leadingIcon = { Icon(Icons.AutoMirrored.Outlined.LibraryBooks, null) },
                        trailingIcon = { if (vm.activeKnowledge.isNotEmpty()) Text("${vm.activeKnowledge.size}") },
                        onClick = { menu = false; knowledgeMenu = true })
                    DropdownMenuItem(text = { Text("Create or edit image") }, leadingIcon = { Icon(Icons.Outlined.Brush, null) },
                        trailingIcon = { if (imageMode) Icon(Icons.Outlined.Check, null) },
                        onClick = { menu = false; onImageMode(!imageMode) })
                    DropdownMenuItem(text = { Text("Speak (Drama 3)") }, leadingIcon = { Icon(Icons.Outlined.GraphicEq, null) },
                        trailingIcon = { if (speechMode) Icon(Icons.Outlined.Check, null) },
                        onClick = { menu = false; onSpeechMode(!speechMode) })
                    DropdownMenuItem(text = { Text("Web search") }, leadingIcon = { Icon(Icons.Outlined.Language, null) },
                        trailingIcon = { if (vm.webSearchEnabled) Icon(Icons.Outlined.Check, null) },
                        onClick = { menu = false; vm.setWebSearch(!vm.webSearchEnabled) })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("Decide (Clef)") }, leadingIcon = { Icon(Icons.Outlined.Balance, null) },
                        onClick = { menu = false; onNavigate(Page.Decision) })
                }
                DropdownMenu(expanded = knowledgeMenu, onDismissRequest = { knowledgeMenu = false }) {
                    if (vm.knowledge.bases.isEmpty()) DropdownMenuItem(text = { Text("No knowledge bases yet") }, onClick = {}, enabled = false)
                    vm.knowledge.bases.forEach { base ->
                        DropdownMenuItem(text = { Text(base.name) }, onClick = { vm.toggleKnowledge(base.id) },
                            leadingIcon = { if (base.id in vm.activeKnowledge) Icon(Icons.Outlined.Check, null) else Spacer(Modifier.size(24.dp)) })
                    }
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("New knowledge base…") }, leadingIcon = { Icon(Icons.Outlined.Add, null) },
                        onClick = { knowledgeMenu = false; naming = true })
                    DropdownMenuItem(text = { Text("Manage knowledge…") }, leadingIcon = { Icon(Icons.Outlined.Settings, null) },
                        onClick = { knowledgeMenu = false; onNavigate(Page.Knowledge()) })
                }
            }
            TextField(
                value = draft, onValueChange = onDraft,
                modifier = Modifier.weight(1f).focusRequester(focus),
                placeholder = {
                    Text(when {
                        imageMode -> if (attachments.isEmpty()) "Describe an image" else "Describe the change"
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
                    Icon(when { imageMode -> Icons.Filled.Brush; speechMode -> Icons.Filled.GraphicEq; else -> Icons.Filled.ArrowUpward },
                        when { imageMode -> "Create image"; speechMode -> "Speak"; else -> "Send" },
                        Modifier.clip(CircleShape).background(Brand.gradient).padding(8.dp), tint = Color.White)
                }
            }
        }
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
