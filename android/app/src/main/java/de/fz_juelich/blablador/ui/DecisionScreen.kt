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
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.outlined.UnfoldMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
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
import de.fz_juelich.blablador.data.decide
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.roundToInt

/** Pick an example, edit the situation, and see the Clef decision model's answers with probabilities. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DecisionScreen(vm: ChatViewModel, onClose: () -> Unit) {
    val context = LocalContext.current
    val examples = remember { DecisionExample.load(context) }
    val categories = remember(examples) { examples.map { it.category }.distinct() }
    val scope = rememberCoroutineScope()
    var example by remember { mutableStateOf(examples.firstOrNull()) }
    var state by remember { mutableStateOf(examples.firstOrNull()?.state.orEmpty()) }
    var answers by remember { mutableStateOf<Map<String, DecisionAnswer>>(emptyMap()) }
    var running by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var choosing by remember { mutableStateOf(false) }
    BackHandler(onBack = onClose)

    fun run() {
        val current = example ?: return
        running = true
        error = null
        scope.launch {
            try {
                answers = vm.api.decide(state, current.questions)
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
                else TextButton(onClick = ::run, enabled = example != null && state.isNotBlank()) { Text("Decide", fontWeight = FontWeight.SemiBold) }
            },
        )
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Section("Example", footer = "${examples.size} examples in ${categories.size} categories. The decision model answers typed questions " +
                "with probabilities instead of text — for routing, triage and classification.") {
                Row(Modifier.fillMaxWidth().clickable { choosing = true }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(example?.name ?: "Choose an example")
                        example?.let { Text(it.category, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                    Icon(Icons.Outlined.UnfoldMore, null)
                }
                example?.description?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            Section(if (example?.json == true) "Situation (JSON)" else "Situation", footer = "Edit it to see how the decisions change.") {
                OutlinedTextField(state, { state = it }, Modifier.fillMaxWidth(), minLines = 3, maxLines = 12,
                    textStyle = if (example?.json == true) MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace)
                    else MaterialTheme.typography.bodyLarge)
            }
            example?.let { current ->
                Section("Questions") {
                    current.questions.forEachIndexed { index, question ->
                        if (index > 0) HorizontalDivider(Modifier.padding(vertical = 8.dp))
                        QuestionRow(question, answers[question.id])
                    }
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }

    if (choosing) AlertDialog(
        onDismissRequest = { choosing = false },
        title = { Text("Examples") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                categories.forEach { category ->
                    Text(category, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(top = 12.dp, bottom = 4.dp))
                    examples.filter { it.category == category }.forEach { item ->
                        Text(item.name, Modifier.fillMaxWidth().clickable {
                            example = item; state = item.state; answers = emptyMap(); error = null; choosing = false
                        }.padding(vertical = 8.dp))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { choosing = false }) { Text("Cancel") } },
    )
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
