package de.fz_juelich.blablador.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material3.AlertDialog
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
import de.fz_juelich.blablador.data.Memory

/** What the assistant remembers about the user; edit, delete or add facts. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoryScreen(vm: ChatViewModel, onClose: () -> Unit) {
    val store = vm.memory
    var newFact by remember { mutableStateOf("") }
    var confirmDelete by remember { mutableStateOf(false) }
    BackHandler(onBack = onClose)

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Memory") },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        )
    }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Section("Memory", footer = "The assistant remembers what's worth keeping from your chats, such as facts about you, your projects, decisions and conclusions, " +
                "and uses it in every chat. With Learn from every chat off, it only saves what you ask it to remember. After each reply, the exchange is sent " +
                "once more to the model to pick out what to remember. Memories are encrypted on this device and sent to the model with each message.") {
                Toggle("Use memory", store.enabled, store::turn)
                if (store.enabled) Toggle("Learn from every chat", store.learnsAutomatically, store::learnAutomatically)
            }
            Section("Memories") {
                if (store.memories.isEmpty()) Text("Nothing remembered yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                store.memories.forEach { memory -> MemoryRow(memory, onChange = { store.update(memory, it) }, onDelete = { store.delete(memory) }) }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(newFact, { newFact = it }, Modifier.weight(1f), placeholder = { Text("Add a memory") })
                    TextButton(onClick = { if (store.add(newFact)) newFact = "" }, enabled = newFact.isNotBlank()) { Text("Add") }
                }
            }
            if (store.memories.isNotEmpty()) TextButton(onClick = { confirmDelete = true }) {
                Text("Forget everything", color = MaterialTheme.colorScheme.error)
            }
        }
    }

    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Forget all memories?") },
        confirmButton = { TextButton(onClick = { store.deleteAll(); confirmDelete = false }) { Text("Forget everything", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}

@Composable
private fun MemoryRow(memory: Memory, onChange: (String) -> Unit, onDelete: () -> Unit) {
    var text by remember(memory.id) { mutableStateOf(memory.text) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(text, {
            text = it
            if (it.isNotBlank()) onChange(it.trim())
        }, Modifier.weight(1f).padding(vertical = 4.dp))
        IconButton(onClick = onDelete) { Icon(Icons.Outlined.DeleteOutline, "Forget") }
    }
}
