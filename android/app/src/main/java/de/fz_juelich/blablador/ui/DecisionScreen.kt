package de.fz_juelich.blablador.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.RemoveCircleOutline
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.outlined.UnfoldMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.fz_juelich.blablador.ChatViewModel
import de.fz_juelich.blablador.data.DecisionAnswer
import de.fz_juelich.blablador.data.DecisionExample
import de.fz_juelich.blablador.data.DecisionQuestion
import de.fz_juelich.blablador.data.SavedDecisions
import de.fz_juelich.blablador.data.decide
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.roundToInt

/** Write a situation and typed questions, or start from an example, and see the Clef decision model's answers with probabilities. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DecisionScreen(vm: ChatViewModel, onClose: () -> Unit) {
    val context = LocalContext.current
    val examples = remember { DecisionExample.load(context) }
    val categories = remember(examples) { examples.map { it.category }.distinct() }
    val scope = rememberCoroutineScope()
    var saved by remember { mutableStateOf(SavedDecisions.load(context)) }
    var decision by remember { mutableStateOf(examples.firstOrNull() ?: DecisionExample.blank()) }
    var answers by remember { mutableStateOf<Map<String, DecisionAnswer>>(emptyMap()) }
    var running by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var choosing by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<DecisionQuestion?>(null) }
    var adding by remember { mutableStateOf(false) }
    var naming by remember { mutableStateOf(false) }
    BackHandler(onBack = onClose)

    val isSaved = decision.category == DecisionExample.MY_CATEGORY && saved.any { it.name == decision.name }
    val canRun = !running && decision.state.isNotBlank() && decision.questions.isNotEmpty() && decision.questions.all { it.isComplete }

    fun select(item: DecisionExample) {
        decision = item; answers = emptyMap(); error = null; choosing = false
    }

    fun save(name: String) {
        val copy = decision.copy(name = name.trim(), category = DecisionExample.MY_CATEGORY, questions = decision.questions.map { it.cleaned() })
        saved = (saved.filter { it.name != copy.name } + copy).sortedBy { it.name.lowercase() }
        SavedDecisions.save(context, saved)
        decision = copy
    }

    fun run() {
        val questions = decision.questions.map { it.cleaned() }
        decision = decision.copy(questions = questions)
        running = true
        error = null
        scope.launch {
            try {
                answers = vm.api.decide(decision.state, questions)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message
            } finally {
                running = false
            }
        }
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Decide") },
            navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Done") } },
            actions = {
                if (running) CircularProgressIndicator(Modifier.padding(horizontal = 16.dp).size(20.dp), strokeWidth = 2.dp)
                else TextButton(onClick = ::run, enabled = canRun) { Text("Decide", fontWeight = FontWeight.SemiBold) }
            },
        )
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Section("Decision", footer = "Start a new decision, open one you saved, or try one of ${examples.size} examples. The decision model " +
                "answers typed questions with probabilities instead of text — for routing, triage and classification.") {
                Row(Modifier.fillMaxWidth().clickable { choosing = true }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(decision.name)
                        Text(decision.category, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Icon(Icons.Outlined.UnfoldMore, null)
                }
                decision.description?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            Section(if (decision.json) "Situation (JSON)" else "Situation", footer = "Plain text or JSON. Edit it to see how the decisions change.") {
                OutlinedTextField(decision.state, { decision = decision.copy(state = it); answers = emptyMap() }, Modifier.fillMaxWidth(),
                    minLines = 3, maxLines = 12,
                    placeholder = { Text("Describe the situation: a message, a record, a request…") },
                    textStyle = if (decision.json) MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace)
                    else MaterialTheme.typography.bodyLarge)
            }
            Section("Questions", footer = "Tap a question to edit it. Yes/no gives the probability of yes; choice picks one option; " +
                "score rates on your levels from lowest to highest.") {
                decision.questions.forEachIndexed { index, question ->
                    if (index > 0) HorizontalDivider(Modifier.padding(vertical = 8.dp))
                    Row(Modifier.fillMaxWidth().clickable { editing = question }, verticalAlignment = Alignment.Top) {
                        Box(Modifier.weight(1f)) { QuestionRow(question, answers[question.id]) }
                        IconButton(onClick = {
                            decision = decision.copy(questions = decision.questions.filter { it.id != question.id })
                            answers = answers - question.id
                        }) { Icon(Icons.Outlined.Delete, "Delete question") }
                    }
                }
                TextButton(onClick = { adding = true }) {
                    Icon(Icons.Outlined.AddCircleOutline, null, Modifier.size(18.dp))
                    Text("Add question", Modifier.padding(start = 8.dp))
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { if (isSaved) save(decision.name) else naming = true }) {
                    Text(if (isSaved) "Save changes" else "Save as my decision")
                }
                if (isSaved) TextButton(onClick = {
                    saved = saved.filter { it.name != decision.name }
                    SavedDecisions.save(context, saved)
                    select(DecisionExample.blank())
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }

    if (choosing) AlertDialog(
        onDismissRequest = { choosing = false },
        title = { Text("Decisions") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text("New decision", Modifier.fillMaxWidth().clickable { select(DecisionExample.blank()) }.padding(vertical = 8.dp),
                    fontWeight = FontWeight.SemiBold)
                val groups = (if (saved.isEmpty()) emptyList() else listOf(DecisionExample.MY_CATEGORY to saved)) +
                    categories.map { category -> category to examples.filter { it.category == category } }
                groups.forEach { (category, items) ->
                    Text(category, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(top = 12.dp, bottom = 4.dp))
                    items.forEach { item ->
                        Text(item.name, Modifier.fillMaxWidth().clickable { select(item) }.padding(vertical = 8.dp))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { choosing = false }) { Text("Cancel") } },
    )

    if (adding) AlertDialog(
        onDismissRequest = { adding = false },
        title = { Text("Add question") },
        text = {
            Column {
                listOf("noul" to "Yes or no", "choice" to "Choice between options", "score" to "Score on a scale").forEach { (type, label) ->
                    Text(label, Modifier.fillMaxWidth().clickable { adding = false; editing = DecisionQuestion.new(type) }.padding(vertical = 12.dp))
                }
            }
        },
        confirmButton = { TextButton(onClick = { adding = false }) { Text("Cancel") } },
    )

    editing?.let { question ->
        QuestionEditor(question, onDismiss = { editing = null }) { updated ->
            val exists = decision.questions.any { it.id == updated.id }
            decision = decision.copy(questions = if (exists) decision.questions.map { if (it.id == updated.id) updated else it } else decision.questions + updated)
            answers = answers - updated.id
            editing = null
        }
    }

    if (naming) {
        var name by remember { mutableStateOf(if (decision.category == DecisionExample.MY_CATEGORY && decision.name != "New decision") decision.name else "") }
        AlertDialog(
            onDismissRequest = { naming = false },
            title = { Text("Save decision") },
            text = { OutlinedTextField(name, { name = it }, singleLine = true, label = { Text("Name") }) },
            confirmButton = { TextButton(onClick = { save(name); naming = false }, enabled = name.isNotBlank()) { Text("Save") } },
            dismissButton = { TextButton(onClick = { naming = false }) { Text("Cancel") } },
        )
    }
}

/** Edits one question: its type, wording, and the options or levels. */
@Composable
private fun QuestionEditor(question: DecisionQuestion, onDismiss: () -> Unit, onSave: (DecisionQuestion) -> Unit) {
    var draft by remember { mutableStateOf(question) }
    fun setType(type: String) {
        draft = draft.copy(
            type = type,
            options = if (type == "choice") draft.options ?: listOf(DecisionQuestion.Option("", ""), DecisionQuestion.Option("", "")) else null,
            levels = if (type == "score") draft.levels ?: listOf("Low", "Medium", "High") else null,
        )
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (question.instructions.isEmpty()) "New question" else "Edit question") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf("noul" to "Yes/no", "choice" to "Choice", "score" to "Score").forEach { (type, label) ->
                        FilterChip(selected = draft.type == type, onClick = { setType(type) }, label = { Text(label) })
                    }
                }
                OutlinedTextField(draft.instructions, { draft = draft.copy(instructions = it) }, Modifier.fillMaxWidth(),
                    label = { Text("Question") }, minLines = 2,
                    placeholder = { Text(when (draft.type) { "choice" -> "Which option fits best?"; "score" -> "How urgent is this?"; else -> "Is this spam?" }) })
                draft.options?.let { options ->
                    Text("Options", style = MaterialTheme.typography.labelLarge)
                    options.forEachIndexed { index, option ->
                        EditableLine(option.text, "Option ${index + 1}",
                            onChange = { text -> draft = draft.copy(options = options.toMutableList().also { it[index] = DecisionQuestion.Option("", text) }) },
                            onRemove = { draft = draft.copy(options = options.filterIndexed { i, _ -> i != index }) })
                    }
                    TextButton(onClick = { draft = draft.copy(options = options + DecisionQuestion.Option("", "")) }) { Text("Add option") }
                }
                draft.levels?.let { levels ->
                    Text("Levels, lowest first", style = MaterialTheme.typography.labelLarge)
                    levels.forEachIndexed { index, level ->
                        EditableLine(level, "Level $index",
                            onChange = { text -> draft = draft.copy(levels = levels.toMutableList().also { it[index] = text }) },
                            onRemove = { draft = draft.copy(levels = levels.filterIndexed { i, _ -> i != index }) })
                    }
                    TextButton(onClick = { draft = draft.copy(levels = levels + "") }) { Text("Add level") }
                }
            }
        },
        confirmButton = { TextButton(onClick = { onSave(draft.cleaned()) }, enabled = draft.isComplete) { Text("Done") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun EditableLine(value: String, label: String, onChange: (String) -> Unit, onRemove: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(value, onChange, Modifier.weight(1f), singleLine = true, placeholder = { Text(label) })
        IconButton(onClick = onRemove) { Icon(Icons.Outlined.RemoveCircleOutline, "Remove", tint = MaterialTheme.colorScheme.error) }
    }
}

private data class Bar(val label: String, val probability: Double, val winner: Boolean)

@Composable
private fun QuestionRow(question: DecisionQuestion, answer: DecisionAnswer?) {
    val bars = answer?.let { bars(question, it) }.orEmpty()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(when (question.type) { "noul" -> Icons.Outlined.CheckCircle; "choice" -> Icons.AutoMirrored.Outlined.List; else -> Icons.Outlined.Speed },
                null, tint = Brand.violet, modifier = Modifier.size(20.dp))
            Text(question.instructions, style = MaterialTheme.typography.titleSmall)
        }
        val summary = answer?.let { summary(question, it) }
        if (summary != null) {
            Text(summary, style = MaterialTheme.typography.titleMedium.copy(brush = Brand.gradient), fontWeight = FontWeight.SemiBold)
            bars.forEach { ProbabilityBar(it) }
        } else {
            Text(optionsText(question), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private fun pretty(key: String) = key.replace('_', ' ')
private fun percent(value: Double) = "${(value * 100).roundToInt()}%"

/** Option labels with their probabilities, in the question's order. */
private fun bars(question: DecisionQuestion, answer: DecisionAnswer): List<Bar> = when (question.type) {
    "noul" -> {
        val yes = answer.noul ?: 0.0
        listOf(Bar("Yes", yes, yes >= 0.5), Bar("No", 1 - yes, yes < 0.5))
    }
    "choice" -> question.options.orEmpty().map { Bar(pretty(it.key), answer.probabilities?.get(it.key) ?: 0.0, it.key == answer.choice) }
    else -> {
        val best = answer.probabilities?.maxByOrNull { it.value }?.key
        question.levels.orEmpty().mapIndexed { index, level -> Bar(level, answer.probabilities?.get(index.toString()) ?: 0.0, index.toString() == best) }
    }
}

private fun summary(question: DecisionQuestion, answer: DecisionAnswer): String? = when (question.type) {
    "noul" -> {
        val yes = answer.noul ?: 0.0
        if (yes >= 0.5) "Yes · ${percent(yes)}" else "No · ${percent(1 - yes)}"
    }
    "choice" -> answer.choice?.let { "${pretty(it)} · ${percent(answer.confidence ?: 0.0)}" }
    else -> {
        val levels = question.levels.orEmpty()
        answer.score?.takeIf { levels.isNotEmpty() }?.let { score ->
            val level = levels[score.roundToInt().coerceIn(0, levels.size - 1)]
            "$level · ${String.format(Locale.ROOT, "%.2f", score)} of ${levels.size - 1}"
        }
    }
}

private fun optionsText(question: DecisionQuestion) = when (question.type) {
    "noul" -> "Yes or no"
    "choice" -> question.options.orEmpty().joinToString(" · ") { pretty(it.key) }
    else -> question.levels.orEmpty().joinToString(" → ")
}

@Composable
private fun ProbabilityBar(bar: Bar) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(bar.label, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.width(110.dp))
        Box(Modifier.weight(1f).height(8.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant)) {
            Box(Modifier.fillMaxHeight().fillMaxWidth(bar.probability.toFloat().coerceIn(0.02f, 1f)).clip(CircleShape)
                .then(if (bar.winner) Modifier.background(Brand.gradient) else Modifier.background(MaterialTheme.colorScheme.outline)))
        }
        Text(percent(bar.probability), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(40.dp))
    }
}
