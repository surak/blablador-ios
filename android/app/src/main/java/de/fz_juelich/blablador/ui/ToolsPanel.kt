package de.fz_juelich.blablador.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.AlternateEmail
import androidx.compose.material.icons.outlined.AutoFixHigh
import androidx.compose.material.icons.outlined.Balance
import androidx.compose.material.icons.outlined.Brush
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.DocumentScanner
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material.icons.outlined.Photo
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.fz_juelich.blablador.ChatViewModel

/** Things picked in the panel that open a picker or a page. */
enum class PanelAction { Camera, Photos, Files, Paste, ScanText, Decide, Knowledge, NewKnowledge, Mcp, Skills, Tasks, Permissions }

/**
 * What the + button opens: attach, the kind of reply, tools, knowledge, connected services and more, each with its
 * state visible instead of hidden in a menu.
 */
@Composable
fun ToolsPanel(
    vm: ChatViewModel,
    imageMode: Boolean, videoMode: Boolean, speechMode: Boolean,
    onMode: (String) -> Unit,
    onAction: (PanelAction) -> Unit,
) {
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        PanelSection("Add") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Tile("Camera", Icons.Outlined.CameraAlt, Modifier.weight(1f)) { onAction(PanelAction.Camera) }
                Tile("Photos", Icons.Outlined.Photo, Modifier.weight(1f)) { onAction(PanelAction.Photos) }
                Tile("Files", Icons.Outlined.Description, Modifier.weight(1f)) { onAction(PanelAction.Files) }
                Tile("Paste", Icons.Outlined.ContentPaste, Modifier.weight(1f)) { onAction(PanelAction.Paste) }
                Tile("Scan text", Icons.Outlined.DocumentScanner, Modifier.weight(1f)) { onAction(PanelAction.ScanText) }
            }
        }
        PanelSection("Reply with") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Tile("Text", Icons.Outlined.ChatBubbleOutline, Modifier.weight(1f), selected = !imageMode && !videoMode && !speechMode) { onMode("text") }
                Tile("Image", Icons.Outlined.Brush, Modifier.weight(1f), selected = imageMode) { onMode("image") }
                Tile("Video", Icons.Outlined.Movie, Modifier.weight(1f), selected = videoMode) { onMode("video") }
                Tile("Speech", Icons.Outlined.GraphicEq, Modifier.weight(1f), selected = speechMode) { onMode("speech") }
            }
        }
        PanelSection("Tools") {
            Card {
                ToggleRow("Web search", "Search and read pages when needed", Icons.Outlined.Language, vm.webSearchEnabled, vm::setWebSearch)
                Divider()
                ToggleRow("Run Python", "Calculations, data and plots on this device", Icons.Outlined.Code, vm.pythonEnabled, vm::setPython)
                Divider()
                ToggleRow("Calendar & contacts", "Events, contacts, location", Icons.Outlined.Event, vm.deviceToolsEnabled, vm::turnDeviceTools)
                Divider()
                ToggleRow("Create images", "The assistant may make and edit images", Icons.Outlined.Brush, vm.imageToolsEnabled, vm::setImageTools)
                Divider()
                ToggleRow("Memory", "${vm.memory.memories.size} memories", Icons.Outlined.Psychology, vm.memory.enabled, vm.memory::turn)
            }
        }
        PanelSection("Knowledge") {
            Card {
                vm.knowledge.bases.forEach { base ->
                    val on = base.id in vm.activeKnowledge
                    PanelRow(base.name, if (base.documents.size == 1) "1 document" else "${base.documents.size} documents",
                        Icons.AutoMirrored.Outlined.LibraryBooks, onClick = { vm.toggleKnowledge(base.id) }) {
                        Icon(if (on) Icons.Filled.CheckCircle else Icons.Outlined.Circle, null,
                            tint = if (on) Brand.violet else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Divider()
                }
                LinkRow(if (vm.knowledge.bases.isEmpty()) "Create a knowledge base" else "Manage knowledge bases", "Answer from your PDFs and notes",
                    Icons.AutoMirrored.Outlined.LibraryBooks) { onAction(if (vm.knowledge.bases.isEmpty()) PanelAction.NewKnowledge else PanelAction.Knowledge) }
            }
        }
        PanelSection("Connected tools") {
            Card {
                vm.mcp.servers.forEach { server ->
                    ToggleRow(server.name, vm.mcp.tools[server.id]?.let { "${it.size} tools" } ?: server.url, Icons.Outlined.Extension, server.enabled) {
                        vm.mcp.save(server.copy(enabled = it))
                    }
                    Divider()
                }
                LinkRow(if (vm.mcp.servers.isEmpty()) "Connect a service (MCP)" else "Manage connected tools", "GitLab, calendars, your own servers…",
                    Icons.Outlined.Link) { onAction(PanelAction.Mcp) }
            }
        }
        PanelSection("More") {
            Card {
                LinkRow("Skills", if (vm.skills.skills.isEmpty()) "Instructions for tasks you repeat" else "${vm.skills.skills.size} skills · use one with @",
                    Icons.Outlined.AutoFixHigh) { onAction(PanelAction.Skills) }
                Divider()
                LinkRow("Scheduled tasks", if (vm.tasks.tasks.isEmpty()) "Run prompts at set times" else "${vm.tasks.tasks.count { it.enabled }} active",
                    Icons.Outlined.Schedule) { onAction(PanelAction.Tasks) }
                Divider()
                LinkRow("Permissions", "What the assistant may do without asking", Icons.Outlined.PanTool) { onAction(PanelAction.Permissions) }
                Divider()
                LinkRow("Decide…", "Weigh options with the Clef decision model", Icons.Outlined.Balance) { onAction(PanelAction.Decide) }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.AlternateEmail, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(6.dp))
            Text("Type @ in a message to use a tool, skill, knowledge base or connected service just for that message.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun PanelSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
        content()
    }
}

@Composable
private fun Card(content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.surfaceVariant)) { content() }
}

@Composable
private fun Divider() = HorizontalDivider(Modifier.padding(start = 48.dp))

@Composable
private fun Tile(title: String, icon: ImageVector, modifier: Modifier, selected: Boolean = false, onClick: () -> Unit) {
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier.height(68.dp).clip(shape).then(if (selected) Modifier.background(Brand.gradient) else Modifier.background(MaterialTheme.colorScheme.surfaceVariant))
            .clickable(onClick = onClick).padding(6.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
    ) {
        val color = if (selected) Color.White else MaterialTheme.colorScheme.onSurface
        Icon(icon, null, tint = color)
        Text(title, style = MaterialTheme.typography.labelSmall, color = color, maxLines = 1)
    }
}

@Composable
private fun PanelRow(title: String, detail: String, icon: ImageVector, onClick: (() -> Unit)? = null, trailing: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier).padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, null, Modifier.size(22.dp), tint = Brand.violet)
        Column(Modifier.weight(1f)) {
            Text(title)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        trailing()
    }
}

@Composable
private fun ToggleRow(title: String, detail: String, icon: ImageVector, checked: Boolean, onChange: (Boolean) -> Unit) =
    PanelRow(title, detail, icon, onClick = { onChange(!checked) }) { Switch(checked, onChange) }

@Composable
private fun LinkRow(title: String, detail: String, icon: ImageVector, onClick: () -> Unit) =
    PanelRow(title, detail, icon, onClick = onClick) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) }
