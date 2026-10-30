package de.fz_juelich.blablador.ui

import android.content.Intent
import android.provider.OpenableColumns
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.FileOpen
import androidx.compose.material.icons.outlined.Share
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import de.fz_juelich.blablador.ChatViewModel
import de.fz_juelich.blablador.data.Skill

/** The skill library: a list, or one skill being edited. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SkillsScreen(vm: ChatViewModel, onClose: () -> Unit) {
    val library = vm.skills
    val context = LocalContext.current
    var editing by remember { mutableStateOf<Skill?>(null) }
    var importError by remember { mutableStateOf<String?>(null) }

    editing?.let { skill ->
        SkillEditor(skill, isNew = library.skills.none { it.id == skill.id },
            onSave = { library.save(it); editing = null },
            onDelete = { library.delete(skill); editing = null },
            onClose = { editing = null })
        return
    }
    BackHandler(onBack = onClose)

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        importError = null
        uris.forEach { uri ->
            val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: "Skill.md"
            val text = runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes().decodeToString() } }.getOrNull()
            val skill = text?.let { Skill.fromMarkdown(it, name) }
            if (skill != null) library.save(skill) else importError = "$name isn't a skill file."
        }
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Skills") },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        )
    }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Section("Skills", footer = "A skill is a set of instructions for one kind of task, such as how you like meeting notes or press releases. " +
                "The assistant sees each skill's name and description and loads the instructions when a task matches. Skills are Markdown files " +
                "with a name and description at the top, so you can share and import them. The assistant can also suggest new skills for you to save.") {
                if (library.skills.isEmpty()) Text("No skills yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                library.skills.forEach { skill ->
                    Row(Modifier.fillMaxWidth().clickable { editing = skill }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(skill.name)
                            Text(skill.description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
                        }
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null)
                    }
                }
                Row {
                    TextButton(onClick = { editing = Skill(name = "", description = "", instructions = "") }) {
                        Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(6.dp)); Text("New skill")
                    }
                    TextButton(onClick = { picker.launch(arrayOf("text/*", "application/octet-stream")) }) {
                        Icon(Icons.Outlined.FileOpen, null); Spacer(Modifier.width(6.dp)); Text("Import")
                    }
                }
                importError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SkillEditor(skill: Skill, isNew: Boolean, onSave: (Skill) -> Unit, onDelete: () -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    var name by remember { mutableStateOf(skill.name) }
    var description by remember { mutableStateOf(skill.description) }
    var instructions by remember { mutableStateOf(skill.instructions) }
    var confirmDelete by remember { mutableStateOf(false) }
    BackHandler(onBack = onClose)
    val edited = skill.copy(name = name.trim(), description = description.trim(), instructions = instructions.trim())

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(if (isNew) "New skill" else skill.name) },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Cancel") } },
            actions = {
                if (!isNew) {
                    IconButton(onClick = {
                        val send = Intent(Intent.ACTION_SEND).setType("text/markdown")
                            .putExtra(Intent.EXTRA_SUBJECT, edited.name).putExtra(Intent.EXTRA_TEXT, edited.markdown)
                        context.startActivity(Intent.createChooser(send, edited.name))
                    }) { Icon(Icons.Outlined.Share, "Share as Markdown") }
                    IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Outlined.DeleteOutline, "Delete skill") }
                }
                TextButton(onClick = { onSave(edited) }, enabled = name.isNotBlank() && instructions.isNotBlank()) { Text("Save") }
            },
        )
    }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Name") }, singleLine = true)
            OutlinedTextField(description, { description = it }, Modifier.fillMaxWidth(), label = { Text("When to use it") }, maxLines = 3)
            OutlinedTextField(instructions, { instructions = it }, Modifier.fillMaxWidth().heightIn(min = 240.dp), label = { Text("Instructions") },
                textStyle = TextStyle(fontFamily = FontFamily.Monospace))
        }
    }

    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Delete ${skill.name}?") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; onDelete() }) { Text("Delete", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}
