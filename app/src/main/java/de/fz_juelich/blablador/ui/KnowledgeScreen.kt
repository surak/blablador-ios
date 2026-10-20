package de.fz_juelich.blablador.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.fz_juelich.blablador.ChatViewModel
import de.fz_juelich.blablador.data.KnowledgeBase
import java.text.DateFormat
import java.util.Date

/** Knowledge bases: the list, or one base's documents when [baseId] is set. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KnowledgeScreen(vm: ChatViewModel, initialBase: String?, onClose: () -> Unit) {
    var baseId by remember { mutableStateOf(initialBase) }
    var naming by remember { mutableStateOf<String?>(null) }
    var renaming by remember { mutableStateOf<KnowledgeBase?>(null) }
    var deleting by remember { mutableStateOf<KnowledgeBase?>(null) }
    val library = vm.knowledge
    val base = baseId?.let(library::base)
    fun back() { if (base != null && initialBase == null) baseId = null else onClose() }
    BackHandler(onBack = ::back)

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty() && base != null) library.add(uris, base.id, vm.api)
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(base?.name ?: "Knowledge") },
            navigationIcon = { IconButton(onClick = ::back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = {
                if (base != null) {
                    IconButton(onClick = { renaming = base }) { Icon(Icons.Outlined.Edit, "Rename") }
                    IconButton(onClick = { deleting = base }) { Icon(Icons.Outlined.DeleteOutline, "Delete knowledge base") }
                }
            },
        )
    }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (base == null) {
                Section("Knowledge bases", footer = "Collections of PDFs and text files that stay available. Turn one on for a chat with + → Knowledge, " +
                    "and Blablador answers from those documents with citations. Text is extracted and indexed with Blablador's embedding model; " +
                    "the index stays on this device.") {
                    library.bases.forEach { item ->
                        Row(Modifier.fillMaxWidth().clickable { baseId = item.id }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(item.name)
                                Text(library.progress[item.id] ?: documentCount(item), style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null)
                        }
                    }
                    TextButton(onClick = { naming = "" }) {
                        Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(6.dp)); Text("New knowledge base")
                    }
                }
            } else {
                Section("This chat") {
                    Toggle("Use in the current chat", base.id in vm.activeKnowledge) { vm.toggleKnowledge(base.id) }
                }
                Section("Documents", footer = "PDFs (scanned pages are read with OCR), text and Markdown files.") {
                    library.progress[base.id]?.let { status ->
                        Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(8.dp))
                            Text(status, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                    if (base.documents.isEmpty() && library.progress[base.id] == null) {
                        Text("No documents yet.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 8.dp))
                    }
                    base.documents.forEach { document ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.Description, null, tint = Brand.violet)
                            Spacer(Modifier.width(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text(document.name)
                                val pages = if (document.pageCount == 1) "1 page" else "${document.pageCount} pages"
                                val ocr = if (document.ocrPageCount > 0) " · OCR" else ""
                                Text("$pages$ocr · ${if (document.chunkCount == 1) "1 passage" else "${document.chunkCount} passages"} · ${DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(document.addedAt))}",
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            IconButton(onClick = { library.remove(document, base.id) }) { Icon(Icons.Outlined.DeleteOutline, "Remove ${document.name}") }
                        }
                    }
                    TextButton(onClick = { picker.launch(arrayOf("application/pdf", "text/*")) }, enabled = library.progress[base.id] == null) {
                        Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(6.dp)); Text("Add documents")
                    }
                }
            }
        }
    }

    naming?.let { name ->
        NameDialog("New knowledge base", name, onDismiss = { naming = null }) {
            val created = library.create(it)
            vm.toggleKnowledge(created.id)
            baseId = created.id
            naming = null
        }
    }
    renaming?.let { item ->
        NameDialog("Rename", item.name, onDismiss = { renaming = null }) { library.rename(item.id, it); renaming = null }
    }
    deleting?.let { item ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete “${item.name}”?") },
            text = { Text("Its documents and index are removed from this device.") },
            confirmButton = {
                TextButton(onClick = { library.delete(item.id); deleting = null; baseId = null; if (initialBase != null) onClose() }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
        )
    }
    library.lastError?.let { message ->
        AlertDialog(
            onDismissRequest = { library.lastError = null },
            title = { Text("Couldn't add document") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { library.lastError = null }) { Text("OK") } },
        )
    }
}

private fun documentCount(base: KnowledgeBase) = when (base.documents.size) {
    0 -> "No documents"
    1 -> "1 document"
    else -> "${base.documents.size} documents"
}

@Composable
fun NameDialog(title: String, initial: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(name, { name = it }, singleLine = true, label = { Text("Name") }) },
        confirmButton = { TextButton(onClick = { onSave(name.trim()) }, enabled = name.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
