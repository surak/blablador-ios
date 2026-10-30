package de.fz_juelich.blablador.ui

import de.fz_juelich.blablador.data.Updates
import androidx.compose.ui.text.style.TextAlign
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import de.fz_juelich.blablador.ChatViewModel
import de.fz_juelich.blablador.data.BlabladorApi

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(vm: ChatViewModel, onOpenKnowledge: () -> Unit, onOpenVoices: () -> Unit, onOpenDecision: () -> Unit, onOpenMemory: () -> Unit, onOpenSkills: () -> Unit, onClose: () -> Unit) {
    var key by remember { mutableStateOf(vm.apiKey) }
    var endpoint by remember { mutableStateOf(vm.endpoint) }
    var confirmDelete by remember { mutableStateOf(false) }
    val context = LocalContext.current
    fun close() { vm.updateConnection(key, endpoint); onClose() }
    BackHandler(onBack = ::close)

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Settings") },
            navigationIcon = { IconButton(onClick = ::close) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Done") } },
        )
    }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Section("Blablador API", footer = listOfNotNull(
                vm.modelsError ?: if (vm.models.isNotEmpty()) "Connected – ${vm.chatModels.size} chat models available." else null,
                "The endpoint is Blablador unless you change it. For Blablador, create a Helmholtz Codebase personal access token with the read_user scope and paste it as the API key.",
            ).joinToString("\n\n")) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(endpoint, { endpoint = it }, Modifier.weight(1f), label = { Text("Endpoint") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                    if (endpoint != BlabladorApi.DEFAULT_ENDPOINT) TextButton(onClick = {
                        endpoint = BlabladorApi.DEFAULT_ENDPOINT
                        vm.updateConnection(key, endpoint)
                    }) { Text("Blablador") }
                }
                OutlinedTextField(key, { key = it }, Modifier.fillMaxWidth(), label = { Text("API key") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                TextButton(onClick = {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://codebase.helmholtz.cloud/-/user_settings/personal_access_tokens/legacy/new")))
                }) { Text("Get an API key (read_user scope)") }
                TextButton(onClick = { vm.updateConnection(key, endpoint) }) { Text("Connect") }
            }

            Section("Model") {
                vm.chatModels.forEach { model ->
                    Choice(model.displayName, model.id == vm.selectedModel) { vm.selectModel(model.id) }
                }
                if (vm.chatModels.isEmpty()) Text(vm.selectedModelName)
                TextButton(onClick = { vm.selectModel(BlabladorApi.DEFAULT_MODEL) }) { Text("Reset to ${BlabladorApi.DEFAULT_MODEL}") }
            }

            Section("Wait for a reply", footer = "How long to wait for a model that is slow to start or pauses while thinking, before giving up.") {
                BlabladorApi.RESPONSE_TIMEOUT_CHOICES.forEach { minutes ->
                    Choice(BlabladorApi.timeoutLabel(minutes), minutes == vm.responseTimeoutMinutes) { vm.setResponseTimeout(minutes) }
                }
            }

            Section("Images", footer = "Used for new images. Editing photos always uses Qwen-Image 2.1, the model that supports editing.") {
                BlabladorApi.IMAGE_MODELS.forEach { (id, name) -> Choice(name, id == vm.imageModel) { vm.selectImageModel(id) } }
                Toggle("Let the assistant create images", vm.imageToolsEnabled, vm::setImageTools)
            }

            Section("Documents", footer = "Reads scanned PDF pages and text from photos. On device is private and works offline; Blablador's LightOnOCR keeps tables and layout better. If Blablador fails, the app reads on device.") {
                Choice("On device (ML Kit)", vm.ocrEngine == "device") { vm.chooseOcrEngine("device") }
                Choice("Blablador (LightOnOCR)", vm.ocrEngine == "blablador") { vm.chooseOcrEngine("blablador") }
            }

            VoiceSettingsSection(vm, onManageVoices = onOpenVoices)

            Section("Knowledge and decisions", footer = "Knowledge bases let chats answer from your documents. Decide asks Blablador's Clef model typed questions and shows probabilities.") {
                Link("Knowledge bases", "${vm.knowledge.bases.size}", onOpenKnowledge)
                Link("Decide (Clef)", "", onOpenDecision)
            }

            Section("Memory and skills", footer = "Facts about you the assistant remembers across chats, and instructions for tasks you repeat.") {
                Link("Memory", if (vm.memory.enabled) "${vm.memory.memories.size}" else "Off", onOpenMemory)
                Link("Skills", "${vm.skills.skills.size}", onOpenSkills)
            }

            Section("Web search", footer = "Lets the model search the web via search.blablador.fz-juelich.de when it needs current information.") {
                Toggle("Web search", vm.webSearchEnabled, vm::setWebSearch)
            }

            Section("Custom instructions", footer = "Sent as a system prompt with every chat.") {
                OutlinedTextField(vm.systemPrompt, vm::updateSystemPrompt, Modifier.fillMaxWidth(),
                    placeholder = { Text("e.g. Answer concisely.") }, minLines = 2, maxLines = 6)
            }

            TextButton(onClick = { confirmDelete = true }) { Text("Delete all chats", color = MaterialTheme.colorScheme.error) }

            val context = LocalContext.current
            Text("Blablador ${Updates.currentVersion(context)}", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
                textAlign = TextAlign.Center)
        }
    }

    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Delete all chats?") },
        confirmButton = { TextButton(onClick = { vm.deleteAll(); confirmDelete = false }) { Text("Delete all", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}

@Composable
internal fun Section(title: String, footer: String? = null, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) { content() } }
        footer?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
internal fun Choice(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, onClick)
        Text(label)
    }
}

@Composable
internal fun Toggle(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(checked, onChange)
    }
}

@Composable
private fun Link(label: String, value: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Text("$value ›", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
