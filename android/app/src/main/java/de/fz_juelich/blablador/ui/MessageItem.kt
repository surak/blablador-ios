package de.fz_juelich.blablador.ui

import androidx.compose.foundation.combinedClickable
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.foundation.ExperimentalFoundationApi

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.drawBehind
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.Psychology
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material.icons.automirrored.outlined.VolumeUp
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import de.fz_juelich.blablador.data.KnowledgeCitation
import androidx.compose.material.icons.outlined.Brush
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil.compose.AsyncImage
import de.fz_juelich.blablador.R
import de.fz_juelich.blablador.data.ChatMessage
import de.fz_juelich.blablador.data.ChatRole
import de.fz_juelich.blablador.data.DocumentAttachment
import de.fz_juelich.blablador.data.SearchResult
import de.fz_juelich.blablador.data.WebImage
import de.fz_juelich.blablador.data.Skill
import androidx.compose.material.icons.outlined.AutoFixHigh
import androidx.compose.material.icons.outlined.TableChart
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.Psychology
import kotlinx.coroutines.delay
import java.io.File

@Composable
fun MessageItem(
    message: ChatMessage,
    isLast: Boolean,
    isStreaming: Boolean,
    imageFile: (String) -> File,
    speaking: Boolean,
    onSpeak: () -> Unit,
    /** Regenerates the reply, with another model when an id is given. */
    onRegenerate: (String?) -> Unit,
    onEditImage: (String) -> Unit,
    speechClip: @Composable (String) -> Unit,
    videoFile: (String) -> File = { File(it) },
    onContinueVideo: (String) -> Unit = {},
    isSkillSaved: (String) -> Boolean = { false },
    onSaveSkill: (Skill) -> Unit = {},
    /** Chat models as id and display name, for "Regenerate with". */
    models: List<Pair<String, String>> = emptyList(),
    onEdit: (String) -> Unit = {},
    onShowVersion: (Int) -> Unit = {},
    canRerun: (String) -> Boolean = { false },
    onRerun: (String) -> Unit = {},
) {
    var editing by remember { mutableStateOf(false) }
    if (editing) EditMessageDialog(message.content, onDismiss = { editing = false }) { editing = false; onEdit(it) }
    when (message.role) {
        ChatRole.user -> Column(Modifier.fillMaxWidth().padding(start = 48.dp), horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (message.images.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                message.images.forEach { ChatImage(imageFile(it), if (message.images.size == 1) 180 else 100, square = true) { onEditImage(it) } }
            }
            message.documents.forEach { DocumentChip(it) }
            if (message.mentions.isNotEmpty()) MentionChips(message.mentions)
            if (message.content.isNotEmpty()) SelectionContainer {
                Text(message.content, style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.clip(RoundedCornerShape(20.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(horizontal = 16.dp, vertical = 10.dp))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (message.alternatives.isNotEmpty()) VersionSwitcher(message, enabled = !isStreaming, onShow = onShowVersion)
                if (message.content.isNotEmpty()) IconButton(onClick = { editing = true }, enabled = !isStreaming, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Outlined.Edit, "Edit", Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        else -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Avatar(active = isLast && isStreaming)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                message.status?.let { status ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        val icon = when {
                            status.startsWith("Searching knowledge") || status.startsWith("Knowledge") -> Icons.AutoMirrored.Outlined.LibraryBooks
                            status.startsWith("Search") -> Icons.Outlined.Language
                            status.startsWith("Speaking") -> Icons.Outlined.GraphicEq
                            else -> Icons.Outlined.Brush
                        }
                        Icon(icon, null,
                            Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(status, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (message.plan.isNotEmpty()) PlanCard(message.plan)
                if (message.reasoning.isNotEmpty()) Thinking(message.reasoning, isLast && isStreaming && message.content.isEmpty())
                if (message.webImages.isNotEmpty()) WebImages(message.webImages)
                message.images.forEach { ChatImage(imageFile(it), 420, square = false) { onEditImage(it) } }
                message.audio.forEach { speechClip(it) }
                message.videos.forEach { name -> VideoClip(videoFile(name)) { onContinueVideo(name) } }
                when {
                    message.content.isEmpty() -> if (message.status == null && message.images.isEmpty() && message.audio.isEmpty() && message.videos.isEmpty() && message.reasoning.isEmpty() && isLast && isStreaming) TypingIndicator()
                    message.isError -> SelectionContainer {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Outlined.WarningAmber, null, tint = MaterialTheme.colorScheme.error)
                            Text(message.content, color = MaterialTheme.colorScheme.error)
                        }
                    }
                    else -> MarkdownText(message.content)
                }
                message.toolCalls.forEach { MemoryNote("Used $it", Icons.Outlined.Extension) }
                message.skillsUsed.forEach { MemoryNote("Used skill: $it", Icons.Outlined.AutoFixHigh) }
                message.remembered.forEach { MemoryNote("Remembered: $it") }
                message.forgotten.forEach { MemoryNote("Forgot: $it") }
                message.suggestedSkills.forEach { SuggestedSkill(it, isSkillSaved(it.name)) { onSaveSkill(it) } }
                if (message.citations.isNotEmpty()) Citations(message.citations)
                if (message.sources.isNotEmpty()) Sources(message.sources)
                if (!(isLast && isStreaming) && (message.content.isNotEmpty() || message.images.isNotEmpty())) {
                    Actions(message, isLast, speaking, onSpeak, onRegenerate, models)
                    if (message.alternatives.isNotEmpty()) VersionSwitcher(message, enabled = !isStreaming, onShow = onShowVersion)
                }
                val trace = message.trace
                if (trace != null && !(isLast && isStreaming)) TraceLine(trace, canRerun, onRerun)
            }
        }
    }
}

@Composable
private fun Avatar(active: Boolean) {
    var dim by remember { mutableStateOf(false) }
    LaunchedEffect(active) {
        dim = false
        while (active) { delay(700); dim = !dim }
        dim = false
    }
    Image(painterResource(R.drawable.avatar), null, Modifier.size(28.dp),
        alpha = if (dim) 0.45f else 1f)
}

@Composable
private fun TypingIndicator() {
    LinearProgressIndicator(Modifier.width(180.dp).height(6.dp).clip(RoundedCornerShape(6.dp)), color = Brand.violet)
}

@Composable
private fun ChatImage(file: File, size: Int, square: Boolean, onEdit: () -> Unit) {
    var viewing by remember { mutableStateOf(false) }
    Box {
        AsyncImage(
            model = file, contentDescription = null,
            contentScale = if (square) ContentScale.Crop else ContentScale.FillWidth,
            modifier = Modifier.then(if (square) Modifier.size(size.dp) else Modifier.widthIn(max = size.dp).fillMaxWidth())
                .clip(RoundedCornerShape(16.dp)).clickable { viewing = true },
        )
        Surface(
            onClick = onEdit, shape = CircleShape, color = androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.55f),
            modifier = Modifier.align(Alignment.BottomEnd).padding(8.dp),
        ) {
            Row(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Brush, null, Modifier.size(14.dp), tint = androidx.compose.ui.graphics.Color.White)
                Spacer(Modifier.width(4.dp))
                Text("Edit", style = MaterialTheme.typography.labelMedium, color = androidx.compose.ui.graphics.Color.White)
            }
        }
    }
    if (viewing) Dialog(onDismissRequest = { viewing = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxWidth().background(androidx.compose.ui.graphics.Color.Black).clickable { viewing = false }) {
            AsyncImage(model = file, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
fun DocumentChip(document: DocumentAttachment, onRemove: (() -> Unit)? = null) {
    val pages = if (document.pageCount == 1) "1 page" else "${document.pageCount} pages"
    Row(
        Modifier.clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(if (document.dataFile != null) Icons.Outlined.TableChart else Icons.Outlined.Description, null, tint = Brand.violet)
        Column(Modifier.widthIn(max = 180.dp)) {
            Text(document.name, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(if (document.dataFile != null) "Data file" else if (document.ocrPageCount > 0) "$pages · OCR" else pages, style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (onRemove != null) IconButton(onClick = onRemove, modifier = Modifier.size(24.dp)) {
            Icon(Icons.Outlined.Close, "Remove ${document.name}", Modifier.size(16.dp))
        }
    }
}

@Composable
private fun Sources(sources: List<SearchResult>) {
    val context = LocalContext.current
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        itemsIndexed(sources) { index, source ->
            Column(
                Modifier.width(170.dp).height(72.dp).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable(enabled = isSafeLink(source.url)) {
                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(source.url))) }
                    }.padding(10.dp),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(source.title, style = MaterialTheme.typography.labelMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text("${index + 1} · ${Uri.parse(source.url).host ?: source.url}", style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** A skill the model offered to save; the user can read it and save it. */
@Composable
private fun SuggestedSkill(skill: Skill, saved: Boolean, onSave: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Outlined.AutoFixHigh, null, Modifier.size(18.dp), tint = Brand.violet)
            Text("Suggested skill: ${skill.name}", style = MaterialTheme.typography.titleSmall)
        }
        Text(skill.description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (expanded) MarkdownText(skill.instructions)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            androidx.compose.material3.OutlinedButton(onClick = onSave, enabled = !saved) { Text(if (saved) "Saved" else "Save skill") }
            TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "Hide" else "Read") }
        }
    }
}

@Composable
private fun MemoryNote(text: String, icon: androidx.compose.ui.graphics.vector.ImageVector = Icons.Outlined.Psychology) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Pictures found online, each opening the page it is on. */
@Composable
private fun WebImages(images: List<WebImage>) {
    val context = LocalContext.current
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(images.filter { isSafeLink(it.url) }, key = { it.image }) { image ->
            AsyncImage(
                model = image.thumbnail ?: image.image, contentDescription = image.title, contentScale = ContentScale.Crop,
                modifier = Modifier.size(150.dp).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(image.url))) } },
            )
        }
    }
}

/** Knowledge-base excerpts behind a reply; tap one to read it. */
@Composable
private fun Citations(citations: List<KnowledgeCitation>) {
    var shown by remember { mutableStateOf<Int?>(null) }
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        itemsIndexed(citations) { index, citation ->
            Column(
                Modifier.width(170.dp).height(72.dp).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable { shown = index }.padding(10.dp),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(citation.text, style = MaterialTheme.typography.labelMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(label(index, citation), style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
    shown?.let { index ->
        val citation = citations[index]
        AlertDialog(
            onDismissRequest = { shown = null },
            title = { Text(label(index, citation)) },
            text = { SelectionContainer { Text(citation.text, Modifier.verticalScroll(rememberScrollState())) } },
            confirmButton = { TextButton(onClick = { shown = null }) { Text("Done") } },
        )
    }
}

private fun label(index: Int, citation: KnowledgeCitation) =
    "K${index + 1} · ${citation.document}" + (citation.page?.let { " · p. $it" } ?: "")

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Actions(message: ChatMessage, isLast: Boolean, speaking: Boolean, onSpeak: () -> Unit, onRegenerate: (String?) -> Unit,
                    models: List<Pair<String, String>>) {
    var choosingModel by remember { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { delay(1500); copied = false } }
    val tint = MaterialTheme.colorScheme.onSurfaceVariant
    Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        // Generated speech: Copy and Share hand over the audio file; reading the text aloud makes no sense there.
        val audio = message.audio.map { androidx.core.content.FileProvider.getUriForFile(context, context.packageName + ".files", de.fz_juelich.blablador.data.EncryptedStorage.decryptedCopy(context, File(File(context.filesDir, "audio"), it))) }
        IconButton(onClick = {
            if (audio.isEmpty()) clipboard.setText(AnnotatedString(message.content))
            else context.getSystemService(android.content.ClipboardManager::class.java)
                .setPrimaryClip(android.content.ClipData.newUri(context.contentResolver, "Blablador speech", audio.last()))
            copied = true
        }) {
            Icon(if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy, if (audio.isEmpty()) "Copy" else "Copy audio", Modifier.size(18.dp), tint = tint)
        }
        if (audio.isEmpty()) IconButton(onClick = onSpeak) {
            Icon(if (speaking) Icons.Outlined.StopCircle else Icons.AutoMirrored.Outlined.VolumeUp, "Read aloud", Modifier.size(18.dp), tint = tint)
        }
        IconButton(onClick = {
            val intent = if (audio.isEmpty()) Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, message.content)
            else Intent(Intent.ACTION_SEND_MULTIPLE).setType("audio/mpeg")
                .putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(audio)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            context.startActivity(Intent.createChooser(intent, null))
        }) { Icon(Icons.Outlined.Share, if (audio.isEmpty()) "Share" else "Share audio", Modifier.size(18.dp), tint = tint) }
        if (audio.isEmpty()) DocumentButton(message.content, tint)
        if (isLast) Box {
            // Tap regenerates; long-press picks another model.
            Box(Modifier.size(48.dp).clip(CircleShape).combinedClickable(onClick = { onRegenerate(null) }, onLongClick = { choosingModel = true },
                onLongClickLabel = "Regenerate with another model"), contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.Refresh, "Regenerate", Modifier.size(18.dp), tint = tint)
            }
            DropdownMenu(expanded = choosingModel, onDismissRequest = { choosingModel = false }) {
                DropdownMenuItem(text = { Text("Regenerate") }, onClick = { choosingModel = false; onRegenerate(null) })
                if (models.isNotEmpty()) {
                    HorizontalDivider()
                    Text("Regenerate with", style = MaterialTheme.typography.labelMedium, color = tint,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
                    models.forEach { (id, name) -> DropdownMenuItem(text = { Text(name) }, onClick = { choosingModel = false; onRegenerate(id) }) }
                }
            }
        }
    }
}

/** "‹ 2/3 ›" for a message with earlier or later versions. */
@Composable
private fun VersionSwitcher(message: ChatMessage, enabled: Boolean, onShow: (Int) -> Unit) {
    val versions = (message.alternatives.map { it.first().version } + message.version).sorted()
    val position = versions.indexOf(message.version) + 1
    val tint = MaterialTheme.colorScheme.onSurfaceVariant
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { onShow(-1) }, enabled = enabled && position > 1, modifier = Modifier.size(32.dp)) {
            Icon(Icons.AutoMirrored.Outlined.KeyboardArrowLeft, "Previous version", Modifier.size(18.dp), tint = tint)
        }
        Text("$position/${versions.size}", style = MaterialTheme.typography.labelMedium, color = tint)
        IconButton(onClick = { onShow(1) }, enabled = enabled && position < versions.size, modifier = Modifier.size(32.dp)) {
            Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, "Next version", Modifier.size(18.dp), tint = tint)
        }
    }
}

/** Changes a message and sends it again; the old version stays. */
@Composable
private fun EditMessageDialog(text: String, onDismiss: () -> Unit, onSend: (String) -> Unit) {
    var draft by remember { mutableStateOf(text) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit message") },
        text = { OutlinedTextField(draft, { draft = it }, Modifier.fillMaxWidth(), minLines = 3, maxLines = 10) },
        confirmButton = { TextButton(onClick = { onSend(draft) }, enabled = draft.isNotBlank()) { Text("Send") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** The model's thinking trace: open and following along while it thinks, folded away once the answer starts. */
@Composable
private fun Thinking(text: String, thinking: Boolean) {
    var expanded by remember { mutableStateOf<Boolean?>(null) }
    val open = expanded ?: thinking
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.clickable { expanded = !open }, verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Outlined.Psychology, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(if (thinking) "Thinking…" else "Thought process", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Icon(if (open) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, if (open) "Hide thinking" else "Show thinking",
                Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (open) {
            val scroll = rememberScrollState()
            LaunchedEffect(text.length) { if (thinking) scroll.scrollTo(scroll.maxValue) }
            SelectionContainer {
                Text(text.trim(), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.heightIn(max = 260.dp).verticalScroll(scroll)
                        .drawBehind { drawRect(Color.Gray.copy(alpha = 0.35f), size = androidx.compose.ui.geometry.Size(2.dp.toPx(), size.height)) }
                        .padding(start = 12.dp))
            }
        }
    }
}

/** A generated video with its sound, with play controls. */
@Composable
private fun VideoClip(file: File, onContinue: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val save = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.CreateDocument("video/mp4")) { uri ->
        if (uri != null) context.contentResolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
    }
    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
    androidx.compose.ui.viewinterop.AndroidView(
        factory = { context ->
            android.widget.VideoView(context).apply {
                val controls = android.widget.MediaController(context)
                controls.setAnchorView(this)
                setMediaController(controls)
                setVideoPath(file.path)
                setOnPreparedListener { seekTo(1) }
            }
        },
        modifier = Modifier.fillMaxWidth().heightIn(max = 420.dp).clip(RoundedCornerShape(14.dp)),
    )
    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        TextButton(onClick = onContinue) { Text("Continue") }
        TextButton(onClick = { save.launch("Blablador video.mp4") }) { Text("Save") }
        TextButton(onClick = {
            val uri = androidx.core.content.FileProvider.getUriForFile(context, context.packageName + ".files", file)
            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).setType("video/mp4")
                .putExtra(android.content.Intent.EXTRA_STREAM, uri).addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            context.startActivity(android.content.Intent.createChooser(intent, null))
        }) { Text("Share") }
    }
    }
}

/** Tap copies the answer as formatted text for Google Docs or Word; long-press also offers saving a Word file. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun DocumentButton(markdown: String, tint: androidx.compose.ui.graphics.Color) {
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { delay(1500); copied = false } }
    @Composable
    fun saver(mime: String, make: () -> ByteArray?) = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.CreateDocument(mime)) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        runCatching { make()?.let { data -> context.contentResolver.openOutputStream(uri)?.use { it.write(data) } } }
    }
    val saveWord = saver("application/vnd.openxmlformats-officedocument.wordprocessingml.document") { de.fz_juelich.blablador.data.DocumentExport.docx(markdown) }
    val saveExcel = saver("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") { de.fz_juelich.blablador.data.OfficeExport.xlsx(markdown) }
    val saveSlides = saver("application/vnd.openxmlformats-officedocument.presentationml.presentation") { de.fz_juelich.blablador.data.OfficeExport.pptx(markdown) }
    val name = de.fz_juelich.blablador.data.DocumentExport.fileName(markdown)
    val hasTables = remember(markdown) { de.fz_juelich.blablador.data.OfficeExport.tables(markdown).isNotEmpty() }
    /** Writes the file to the cache and lets the user pick an app to open it. */
    fun openIn(ext: String, mime: String, type: String, make: () -> ByteArray?) {
        val data = make() ?: return
        val file = java.io.File(java.io.File(context.cacheDir, "exports").apply { mkdirs() }, "$name.$ext")
        file.writeBytes(data)
        val uri = androidx.core.content.FileProvider.getUriForFile(context, context.packageName + ".files", file)
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (view.resolveActivity(context.packageManager) == null &&
            context.packageManager.queryIntentActivities(view, 0).isEmpty()) {
            android.widget.Toast.makeText(context, "No app on this device opens $type files", android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        runCatching { context.startActivity(Intent.createChooser(view, "Open with")) }
            .onFailure { android.widget.Toast.makeText(context, "No app on this device opens $type files", android.widget.Toast.LENGTH_SHORT).show() }
    }
    fun copy() {
        val clip = android.content.ClipData.newHtmlText("Blablador", de.fz_juelich.blablador.data.DocumentExport.plain(markdown),
            de.fz_juelich.blablador.data.DocumentExport.html(markdown))
        context.getSystemService(android.content.ClipboardManager::class.java)?.setPrimaryClip(clip)
        copied = true
    }
    Box {
        Box(Modifier.size(48.dp).clip(CircleShape).combinedClickable(onClick = ::copy, onLongClick = { menu = true },
            onClickLabel = "Copy for Google Docs or Word", onLongClickLabel = "More document options"), contentAlignment = Alignment.Center) {
            Icon(if (copied) Icons.Outlined.Check else Icons.Outlined.Description, "Copy for Google Docs or Word", Modifier.size(18.dp), tint = tint)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Copy for Google Docs or Word") }, onClick = { menu = false; copy() })
            HorizontalDivider()
            Text("Save as a file", style = MaterialTheme.typography.labelMedium, color = tint,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
            DropdownMenuItem(text = { Text("Word document…") }, onClick = { menu = false; saveWord.launch("$name.docx") })
            if (hasTables) DropdownMenuItem(text = { Text("Excel spreadsheet…") }, onClick = { menu = false; saveExcel.launch("$name.xlsx") })
            DropdownMenuItem(text = { Text("PowerPoint slides…") }, onClick = { menu = false; saveSlides.launch("$name.pptx") })
            HorizontalDivider()
            Text("Open in an app", style = MaterialTheme.typography.labelMedium, color = tint,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
            DropdownMenuItem(text = { Text("Open as Word document") }, onClick = {
                menu = false
                openIn("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "Word") { de.fz_juelich.blablador.data.DocumentExport.docx(markdown) }
            })
            if (hasTables) DropdownMenuItem(text = { Text("Open as spreadsheet") }, onClick = {
                menu = false
                openIn("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "spreadsheet") { de.fz_juelich.blablador.data.OfficeExport.xlsx(markdown) }
            })
            DropdownMenuItem(text = { Text("Open as slides") }, onClick = {
                menu = false
                openIn("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation", "slides") { de.fz_juelich.blablador.data.OfficeExport.pptx(markdown) }
            })
        }
    }
}
