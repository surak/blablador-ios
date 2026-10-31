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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.fz_juelich.blablador.ChatViewModel
import de.fz_juelich.blablador.data.ScheduledTask
import de.fz_juelich.blablador.data.ToolPermissions
import java.text.DateFormat
import java.text.DateFormatSymbols
import java.util.Calendar
import java.util.Date

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PermissionsScreen(vm: ChatViewModel, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    Scaffold(topBar = {
        TopAppBar(title = { Text("Permissions") }, navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Section("Tools", footer = "Ask shows a card before each use, with Allow, Allow for this chat and Always allow. Never hides the tool from the assistant. " +
                "Android may still ask for access to your calendar, contacts or location the first time.") {
                ToolPermissions.kinds.forEach { kind -> RuleRow(vm, kind.id, kind.name, kind.detail) }
            }
            if (vm.mcp.servers.isNotEmpty()) Section("Connected tools") {
                vm.mcp.servers.forEach { server -> RuleRow(vm, "mcp:${server.id}", server.name, server.url) }
            }
            TextButton(onClick = { vm.permissions.resetAll() }) { Text("Reset to defaults", color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
private fun RuleRow(vm: ChatViewModel, id: String, name: String, detail: String) {
    var menu by remember { mutableStateOf(false) }
    val rule = vm.permissions.rule(id)
    Row(Modifier.fillMaxWidth().clickable { menu = true }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(name)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        Column {
            Text("${rule.label} ▾", color = MaterialTheme.colorScheme.primary)
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                ToolPermissions.Rule.entries.forEach { choice ->
                    DropdownMenuItem(text = { Text(choice.label) }, onClick = { vm.permissions.set(id, choice); menu = false })
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TasksScreen(vm: ChatViewModel, onClose: () -> Unit) {
    var editing by remember { mutableStateOf<ScheduledTask?>(null) }
    editing?.let { task ->
        TaskEditor(vm, task, isNew = vm.tasks.tasks.none { it.id == task.id }, onClose = { editing = null })
        return
    }
    BackHandler(onBack = onClose)
    Scaffold(topBar = {
        TopAppBar(title = { Text("Scheduled tasks") }, navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Section("Tasks", footer = "Each run makes a new chat and a notification. At the set time a notification appears; the task runs while Blablador is open, " +
                "or when you open it.") {
                if (vm.tasks.tasks.isEmpty()) Text("No tasks yet. Add one here, or ask in a chat, e.g. “Every weekday at 8, summarise the news about supercomputing.”",
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                vm.tasks.tasks.forEach { task ->
                    Row(Modifier.fillMaxWidth().clickable { editing = task }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(task.title, color = if (task.enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(if (task.enabled) task.scheduleText else "Off", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null)
                    }
                }
                TextButton(onClick = { editing = ScheduledTask(title = "", prompt = "") }) {
                    Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(6.dp)); Text("Add task")
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TaskEditor(vm: ChatViewModel, initial: ScheduledTask, isNew: Boolean, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    var task by remember { mutableStateOf(initial) }
    var pickingTime by remember { mutableStateOf(false) }
    var pickingDate by remember { mutableStateOf(false) }
    fun save() {
        vm.tasks.save(if (task.title.isBlank()) task.copy(title = task.prompt.take(40)) else task)
        vm.wantsNotifications = true
    }
    Scaffold(topBar = {
        TopAppBar(
            title = { Text(if (task.title.isEmpty()) "New task" else task.title) },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Cancel") } },
            actions = { TextButton(onClick = { save(); onClose() }, enabled = task.prompt.isNotBlank()) { Text("Save") } },
        )
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            OutlinedTextField(task.title, { task = task.copy(title = it) }, Modifier.fillMaxWidth(), label = { Text("Name") }, singleLine = true)
            OutlinedTextField(task.prompt, { task = task.copy(prompt = it) }, Modifier.fillMaxWidth(), label = { Text("What should Blablador do?") }, minLines = 3)
            Section("When") {
                val once = task.weekdays.isEmpty()
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    SegmentedButton(!once, { task = task.copy(weekdays = (1..7).toSet()) }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("On days") }
                    SegmentedButton(once, {
                        val tomorrow = Calendar.getInstance().apply {
                            add(Calendar.DAY_OF_YEAR, 1); set(Calendar.HOUR_OF_DAY, task.hour); set(Calendar.MINUTE, task.minute); set(Calendar.SECOND, 0)
                        }.timeInMillis
                        task = task.copy(weekdays = emptySet(), date = task.date ?: tomorrow)
                    }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("Once") }
                }
                Row(Modifier.fillMaxWidth().clickable { pickingTime = true }.padding(vertical = 10.dp)) {
                    Text("Time", Modifier.weight(1f)); Text("%02d:%02d".format(task.hour, task.minute), color = MaterialTheme.colorScheme.primary)
                }
                if (once) Row(Modifier.fillMaxWidth().clickable { pickingDate = true }.padding(vertical = 10.dp)) {
                    Text("Date", Modifier.weight(1f))
                    Text(task.date?.let { DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(it)) } ?: "", color = MaterialTheme.colorScheme.primary)
                } else Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    val symbols = DateFormatSymbols.getInstance().shortWeekdays
                    listOf(2, 3, 4, 5, 6, 7, 1).forEach { day ->
                        val on = day in task.weekdays
                        FilterChip(on, {
                            task = task.copy(weekdays = if (on && task.weekdays.size > 1) task.weekdays - day else task.weekdays + day)
                        }, label = { Text(symbols[day].take(2)) }, modifier = Modifier.weight(1f), shape = CircleShape)
                    }
                }
            }
            Section("Options") {
                Toggle("Search the web", task.webSearch) { task = task.copy(webSearch = it) }
                Toggle("On", task.enabled) { task = task.copy(enabled = it) }
            }
            if (!isNew) Row {
                TextButton(onClick = { save(); vm.runTaskNow(task); onClose() }) { Text("Run now") }
                TextButton(onClick = { vm.tasks.delete(task.id); onClose() }) { Text("Delete task", color = MaterialTheme.colorScheme.error) }
            }
        }
    }
    if (pickingTime) {
        val state = rememberTimePickerState(task.hour, task.minute, is24Hour = true)
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { pickingTime = false },
            confirmButton = {
                TextButton(onClick = {
                    task = task.copy(hour = state.hour, minute = state.minute, date = task.date?.let {
                        Calendar.getInstance().apply { timeInMillis = it; set(Calendar.HOUR_OF_DAY, state.hour); set(Calendar.MINUTE, state.minute) }.timeInMillis
                    })
                    pickingTime = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { pickingTime = false }) { Text("Cancel") } },
            text = { TimePicker(state) },
        )
    }
    if (pickingDate) {
        val state = androidx.compose.material3.rememberDatePickerState(task.date)
        androidx.compose.material3.DatePickerDialog(
            onDismissRequest = { pickingDate = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { utc ->
                        val day = Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply { timeInMillis = utc }
                        task = task.copy(date = Calendar.getInstance().apply {
                            clear(); set(day.get(Calendar.YEAR), day.get(Calendar.MONTH), day.get(Calendar.DAY_OF_MONTH), task.hour, task.minute)
                        }.timeInMillis)
                    }
                    pickingDate = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { pickingDate = false }) { Text("Cancel") } },
        ) { androidx.compose.material3.DatePicker(state) }
    }
}
