package de.fz_juelich.blablador.ui

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.DeleteOutline
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import de.fz_juelich.blablador.ChatViewModel
import de.fz_juelich.blablador.data.McpServer
import kotlinx.coroutines.launch

/** Connected MCP servers: the list, or one server being edited. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun McpScreen(vm: ChatViewModel, onClose: () -> Unit) {
    val library = vm.mcp
    val scope = rememberCoroutineScope()
    var editing by remember { mutableStateOf<McpServer?>(null) }

    LaunchedEffect(Unit) { library.servers.filter { library.tools[it.id] == null }.forEach { scope.launch { library.load(it) } } }

    editing?.let { server ->
        McpServerEditor(server, isNew = library.server(server.id) == null,
            onSave = { library.save(it); scope.launch { library.load(it) }; editing = null },
            onDelete = { library.delete(server); editing = null },
            onClose = { editing = null })
        return
    }
    BackHandler(onBack = onClose)

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Connected tools (MCP)") },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        )
    }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Section("Servers", footer = "Connect services that speak the Model Context Protocol (MCP), such as GitLab, a calendar or your own tools, " +
                "and the assistant can use their tools in every chat. Blablador connects over HTTPS (\"Streamable HTTP\"). Tool calls wait for your OK " +
                "unless you turn that off for a server. What a tool returns is treated like web content: it can't change the assistant's memory.") {
                if (library.servers.isEmpty()) Text("No servers yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                library.servers.forEach { server ->
                    Row(Modifier.fillMaxWidth().clickable { editing = server }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(server.name)
                            val error = library.errors[server.id]
                            Text(status(vm, server), style = MaterialTheme.typography.bodySmall, maxLines = 2,
                                color = if (error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (library.loading[server.id] == true) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null)
                    }
                }
                TextButton(onClick = { editing = McpServer(name = "", url = "https://") }) {
                    Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(6.dp)); Text("Add server")
                }
            }
        }
    }
}

private fun status(vm: ChatViewModel, server: McpServer): String {
    if (!server.enabled) return "Off"
    vm.mcp.errors[server.id]?.let { return it }
    val tools = vm.mcp.tools[server.id] ?: return "Connecting…"
    return if (tools.size == 1) "1 tool"
    else "${tools.size} tools: " + tools.take(4).joinToString(", ") { it.name } + if (tools.size > 4) "…" else ""
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun McpServerEditor(server: McpServer, isNew: Boolean, onSave: (McpServer) -> Unit, onDelete: () -> Unit, onClose: () -> Unit) {
    var name by remember { mutableStateOf(server.name) }
    var url by remember { mutableStateOf(server.url) }
    var token by remember { mutableStateOf(server.token) }
    var enabled by remember { mutableStateOf(server.enabled) }
    var ask by remember { mutableStateOf(server.askBeforeCalls) }
    var confirmDelete by remember { mutableStateOf(false) }
    BackHandler(onBack = onClose)
    val valid = name.isNotBlank() && url.trim().let { it.startsWith("https://") && it.length > 8 || it.startsWith("http://localhost") || it.startsWith("http://127.0.0.1") }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(if (isNew) "New server" else server.name) },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Cancel") } },
            actions = {
                if (!isNew) IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Outlined.DeleteOutline, "Remove server") }
                TextButton(onClick = {
                    onSave(server.copy(name = name.trim(), url = url.trim(), token = token.trim(), enabled = enabled, askBeforeCalls = ask))
                }, enabled = valid) { Text("Save") }
            },
        )
    }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Name, e.g. GitLab") }, singleLine = true)
            OutlinedTextField(url, { url = it }, Modifier.fillMaxWidth(), label = { Text("Address") }, singleLine = true,
                placeholder = { Text("https://example.org/mcp") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(token, { token = it }, Modifier.fillMaxWidth(), label = { Text("Access token (optional)") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            Text("The token is sent as \"Authorization: Bearer …\" and stored encrypted on this device.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Toggle("On", enabled) { enabled = it }
            Toggle("Ask before each tool call", ask) { ask = it }
        }
    }

    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Remove ${server.name}?") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; onDelete() }) { Text("Remove", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}
