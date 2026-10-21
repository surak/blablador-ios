package de.fz_juelich.blablador.ui

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
    onRegenerate: () -> Unit,
    onEditImage: (String) -> Unit,
    speechClip: @Composable (String) -> Unit,
    videoFile: (String) -> File = { File(it) },
) {
    when (message.role) {
        ChatRole.user -> Column(Modifier.fillMaxWidth().padding(start = 48.dp), horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (message.images.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                message.images.forEach { ChatImage(imageFile(it), if (message.images.size == 1) 180 else 100, square = true) { onEditImage(it) } }
            }
            message.documents.forEach { DocumentChip(it) }
            if (message.content.isNotEmpty()) SelectionContainer {
                Text(message.content, style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.clip(RoundedCornerShape(20.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(horizontal = 16.dp, vertical = 10.dp))
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
                if (message.reasoning.isNotEmpty()) Thinking(message.reasoning, isLast && isStreaming && message.content.isEmpty())
                message.images.forEach { ChatImage(imageFile(it), 420, square = false) { onEditImage(it) } }
                message.audio.forEach { speechClip(it) }
                message.videos.forEach { VideoClip(videoFile(it)) }
                when {
                    message.content.isEmpty() -> if (message.status == null && message.images.isEmpty() && message.audio.isEmpty() && message.videos.isEmpty() && message.reasoning.isEmpty()) TypingIndicator()
                    message.isError -> SelectionContainer {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Outlined.WarningAmber, null, tint = MaterialTheme.colorScheme.error)
                            Text(message.content, color = MaterialTheme.colorScheme.error)
                        }
                    }
                    else -> MarkdownText(message.content)
                }
                if (message.citations.isNotEmpty()) Citations(message.citations)
                if (message.sources.isNotEmpty()) Sources(message.sources)
                if (!(isLast && isStreaming) && (message.content.isNotEmpty() || message.images.isNotEmpty())) {
                    Actions(message, isLast, speaking, onSpeak, onRegenerate)
                }
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
        Icon(Icons.Outlined.Description, null, tint = Brand.violet)
        Column(Modifier.widthIn(max = 180.dp)) {
            Text(document.name, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(if (document.ocrPageCount > 0) "$pages · OCR" else pages, style = MaterialTheme.typography.labelSmall,
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
                    .clickable { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(source.url))) }.padding(10.dp),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(source.title, style = MaterialTheme.typography.labelMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text("${index + 1} · ${Uri.parse(source.url).host ?: source.url}", style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
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

@Composable
private fun Actions(message: ChatMessage, isLast: Boolean, speaking: Boolean, onSpeak: () -> Unit, onRegenerate: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { delay(1500); copied = false } }
    val tint = MaterialTheme.colorScheme.onSurfaceVariant
    Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        IconButton(onClick = { clipboard.setText(AnnotatedString(message.content)); copied = true }) {
            Icon(if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy, "Copy", Modifier.size(18.dp), tint = tint)
        }
        IconButton(onClick = onSpeak) {
            Icon(if (speaking) Icons.Outlined.StopCircle else Icons.AutoMirrored.Outlined.VolumeUp, "Read aloud", Modifier.size(18.dp), tint = tint)
        }
        IconButton(onClick = {
            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, message.content), null))
        }) { Icon(Icons.Outlined.Share, "Share", Modifier.size(18.dp), tint = tint) }
        if (isLast) IconButton(onClick = onRegenerate) { Icon(Icons.Outlined.Refresh, "Regenerate", Modifier.size(18.dp), tint = tint) }
    }
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
private fun VideoClip(file: File) {
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
}
