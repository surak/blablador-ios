package de.fz_juelich.blablador.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.animation.core.animateFloat
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.material.icons.outlined.AutoFixHigh
import androidx.compose.material.icons.outlined.Brush
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.HelpOutline
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.ManageSearch
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.material.icons.outlined.Timelapse
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.fz_juelich.blablador.data.Mention
import de.fz_juelich.blablador.data.Mentions
import de.fz_juelich.blablador.data.PlanItem
import de.fz_juelich.blablador.data.SelfCheck
import de.fz_juelich.blablador.data.RemoteModel
import de.fz_juelich.blablador.data.StepState
import de.fz_juelich.blablador.data.Trace

/**
 * The icon for scheduled tasks: the Blablador avatar with a small clock at the top right whose glow fades in and
 * out (1.6 s each way). Nothing moves or scales.
 */
@Composable
fun ScheduleIcon(size: androidx.compose.ui.unit.Dp = 22.dp) {
    val glow by androidx.compose.animation.core.rememberInfiniteTransition(label = "schedule").animateFloat(
        initialValue = 0.55f, targetValue = 1f,
        animationSpec = androidx.compose.animation.core.infiniteRepeatable(
            androidx.compose.animation.core.tween(1600, easing = androidx.compose.animation.core.FastOutSlowInEasing),
            androidx.compose.animation.core.RepeatMode.Reverse),
        label = "glow",
    )
    androidx.compose.foundation.layout.Box(Modifier.size(size)) {
        androidx.compose.foundation.Image(androidx.compose.ui.res.painterResource(de.fz_juelich.blablador.R.drawable.avatar), "Scheduled task", Modifier.size(size))
        Icon(Icons.Filled.Schedule, null, tint = Brand.violet,
            modifier = Modifier.align(Alignment.TopEnd).size(size * 0.5f)
                .shadow((size * 0.25f) * glow, CircleShape, ambientColor = Brand.violet, spotColor = Brand.violet)
                .background(MaterialTheme.colorScheme.surface, CircleShape)
                .alpha(glow))
    }
}

/** A mention's icon; the schedule tool shows [ScheduleIcon]. */
@Composable
fun MentionIcon(mention: Mention, size: androidx.compose.ui.unit.Dp, tint: Color) {
    if (mention.kind == Mention.Kind.tool && mention.value == "schedule") ScheduleIcon(size)
    else Icon(mentionIcon(mention), null, Modifier.size(size), tint = tint)
}

fun mentionIcon(mention: Mention): ImageVector = when (mention.kind) {
    Mention.Kind.skill -> Icons.Outlined.AutoFixHigh
    Mention.Kind.knowledge -> Icons.AutoMirrored.Outlined.LibraryBooks
    Mention.Kind.server -> Icons.Outlined.Extension
    Mention.Kind.tool -> when (mention.value) {
        "web" -> Icons.Outlined.Language
        "python" -> Icons.Outlined.Code
        "device" -> Icons.Outlined.Event
        "chats" -> Icons.Outlined.ManageSearch
        "memory" -> Icons.Outlined.Psychology
        "image" -> Icons.Outlined.Brush
        "speech" -> Icons.Outlined.GraphicEq
        "schedule" -> Icons.Outlined.Schedule
        "goal" -> Icons.Outlined.Flag
        else -> Icons.Outlined.Checklist
    }
}

/** The plan as a checklist at the top of a reply. */
@Composable
fun PlanCard(items: List<PlanItem>) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.surfaceVariant).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Checklist, null, Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text("Plan", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text("${items.count { it.status == PlanItem.Status.done }}/${items.size}", style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        items.forEach { item ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                when (item.status) {
                    PlanItem.Status.done -> Icon(Icons.Filled.CheckCircle, null, Modifier.size(16.dp), tint = Color(0xFF34A853))
                    PlanItem.Status.active -> Icon(Icons.Outlined.Timelapse, null, Modifier.size(16.dp), tint = Brand.violet)
                    PlanItem.Status.pending -> Icon(Icons.Outlined.Circle, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(item.text, style = MaterialTheme.typography.bodyMedium,
                    color = if (item.status == PlanItem.Status.done) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                    textDecoration = if (item.status == PlanItem.Status.done) TextDecoration.LineThrough else null,
                    fontWeight = if (item.status == PlanItem.Status.active) FontWeight.SemiBold else null)
            }
        }
    }
}

fun traceDuration(seconds: Double): String = when {
    seconds < 10 -> "%.1f s".format(seconds)
    seconds < 120 -> "${Math.round(seconds)} s"
    else -> "${(seconds / 60).toInt()} min ${seconds.toInt() % 60} s"
}

fun traceSummary(trace: Trace): String = buildList {
    if (trace.calls.isNotEmpty()) add("${trace.calls.size} tool${if (trace.calls.size == 1) "" else "s"}")
    add(traceDuration(trace.seconds))
    val tokens = trace.promptTokens + trace.completionTokens
    if (tokens > 0) add("%,d tokens".format(tokens))
    trace.check?.let { add(if (it == SelfCheck.Result.passed) "checked" else "corrected after a check") }
}.joinToString(" · ")

/** "4 tools · 12 s · 3,210 tokens" under a reply; opens the full trace. */
@Composable
fun TraceLine(trace: Trace, canRerun: (String) -> Boolean, onRerun: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.clickable { open = true }, verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Outlined.TaskAlt, null, Modifier.size(12.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(4.dp))
        Text(traceSummary(trace), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (open) {
        var expanded by remember { mutableStateOf(setOf<String>()) }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { open = false },
            confirmButton = { TextButton(onClick = { open = false }) { Text("Done") } },
            title = { Text("How this reply was made") },
            text = {
                Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Model: ${RemoteModel(trace.model).displayName}", style = MaterialTheme.typography.bodySmall)
                    Text("Time: ${traceDuration(trace.seconds)} · model calls: ${trace.rounds}", style = MaterialTheme.typography.bodySmall)
                    if (trace.promptTokens + trace.completionTokens > 0) {
                        Text("Tokens in: %,d · out: %,d".format(trace.promptTokens, trace.completionTokens), style = MaterialTheme.typography.bodySmall)
                    }
                    HorizontalDivider()
                    if (trace.calls.isEmpty()) Text("No tools used", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    trace.calls.forEach { call ->
                        Row(Modifier.fillMaxWidth().clickable { expanded = if (call.id in expanded) expanded - call.id else expanded + call.id },
                            verticalAlignment = Alignment.CenterVertically) {
                            Text(when (call.state) { StepState.done -> "✓"; StepState.failed -> "⚠"; StepState.denied -> "✋"; StepState.running -> "…" },
                                Modifier.width(22.dp))
                            Text(call.tool, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                            Text(if (call.state == StepState.running) "…" else traceDuration(call.seconds), style = MaterialTheme.typography.labelSmall)
                        }
                        if (call.id in expanded) SelectionContainer {
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(call.arguments, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall)
                                Text(call.result.ifEmpty { "(no output)" }, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        if (call.id in expanded && canRerun(call.tool)) TextButton(onClick = { onRerun(call.id) }, enabled = call.state != StepState.running) {
                            Icon(Icons.Outlined.Refresh, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text("Run again")
                        }
                    }
                }
            },
        )
    }
}

/** Mentions as chips: removable in the composer, plain on a sent message. */
@Composable
fun MentionChips(mentions: List<Mention>, onRemove: ((Mention) -> Unit)? = null) {
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = if (onRemove != null) 8.dp else 0.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        mentions.forEach { mention ->
            val modifier = if (onRemove != null) Modifier.clip(CircleShape).background(Brand.gradient)
            else Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant)
            val color = if (onRemove != null) Color.White else MaterialTheme.colorScheme.onSurfaceVariant
            Row(modifier.padding(horizontal = 10.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                MentionIcon(mention, 14.dp, color)
                Text("@" + mention.name, style = MaterialTheme.typography.labelMedium, color = color, maxLines = 1)
                if (onRemove != null) Icon(Icons.Filled.Close, "Remove ${mention.name}", Modifier.size(14.dp).clickable { onRemove(mention) }, tint = color)
            }
        }
    }
}

/** Suggestions for an "@name" being typed. */
@Composable
fun MentionSuggestions(query: String, all: List<Mention>, onPick: (Mention) -> Unit) {
    val matches = Mentions.matches(query, all)
    Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp).clip(RoundedCornerShape(14.dp))
        .background(MaterialTheme.colorScheme.background.copy(alpha = 0.6f)).heightIn(max = 240.dp).verticalScroll(rememberScrollState())) {
        if (matches.isEmpty()) Text("Nothing called “$query”. Type @ for tools, skills and connected services, # for knowledge bases.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(10.dp))
        matches.take(30).forEach { mention ->
            Row(Modifier.fillMaxWidth().clickable { onPick(mention) }.padding(horizontal = 12.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                MentionIcon(mention, 18.dp, Brand.violet)
                Text(mention.name, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(Mentions.kindName(mention.kind), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** The open chat's goal above the composer: what it is, how it's going, and Continue or End. */
@Composable
fun GoalBanner(goal: de.fz_juelich.blablador.data.Goal, running: Boolean, onContinue: () -> Unit, onEnd: () -> Unit) {
    val status = when (goal.status) {
        de.fz_juelich.blablador.data.Goal.Status.active -> if (running) "Working on the goal…" else "Goal · paused"
        de.fz_juelich.blablador.data.Goal.Status.done -> "Goal reached"
        de.fz_juelich.blablador.data.Goal.Status.blocked -> "Goal · needs you"
    }
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).clip(RoundedCornerShape(14.dp))
        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f)).padding(10.dp),
        verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(when (goal.status) {
            de.fz_juelich.blablador.data.Goal.Status.active -> Icons.Outlined.Flag
            de.fz_juelich.blablador.data.Goal.Status.done -> Icons.Outlined.CheckCircle
            de.fz_juelich.blablador.data.Goal.Status.blocked -> Icons.Outlined.HelpOutline
        }, null, tint = Brand.violet)
        Column(Modifier.weight(1f)) {
            Text(status, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(goal.text, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (goal.status != de.fz_juelich.blablador.data.Goal.Status.active) goal.summary?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
        }
        if (goal.status != de.fz_juelich.blablador.data.Goal.Status.done && !running) {
            androidx.compose.material3.TextButton(onClick = onContinue) { Text("Continue") }
        }
        androidx.compose.material3.IconButton(onClick = onEnd, modifier = Modifier.size(28.dp)) {
            Icon(Icons.Outlined.Close, if (goal.status == de.fz_juelich.blablador.data.Goal.Status.done) "Dismiss goal" else "End goal",
                tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Commands offered while "/" is typed as the whole draft. */
@Composable
fun SlashSuggestions(query: String, onPick: (String) -> Unit) {
    val commands = listOf(Triple("goal", Icons.Outlined.Flag, "Keep working until it's done")).filter { query.isEmpty() || it.first.startsWith(query.lowercase()) }
    if (commands.isEmpty()) return
    Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)) {
        commands.forEach { (name, icon, text) ->
            Row(Modifier.fillMaxWidth().clickable { onPick(name) }.padding(horizontal = 12.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(icon, null, Modifier.size(18.dp), tint = Brand.violet)
                Text("/$name", fontWeight = androidx.compose.ui.text.font.FontWeight.Bold)
                Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Knowledge bases offered while "#name" is typed. */
@Composable
fun KnowledgeSuggestions(query: String, bases: List<de.fz_juelich.blablador.data.KnowledgeBase>, onPick: (de.fz_juelich.blablador.data.KnowledgeBase) -> Unit) {
    val q = query.lowercase()
    val matches = bases.filter { q.isEmpty() || it.name.lowercase().contains(q) }.sortedBy { !it.name.lowercase().startsWith(q) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp).clip(RoundedCornerShape(14.dp))
        .background(MaterialTheme.colorScheme.background.copy(alpha = 0.6f)).heightIn(max = 240.dp).verticalScroll(rememberScrollState())) {
        if (matches.isEmpty()) Text(if (bases.isEmpty()) "No knowledge bases yet. Make one with + → New knowledge base." else "No knowledge base called “$query”.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(10.dp))
        matches.take(30).forEach { base ->
            Row(Modifier.fillMaxWidth().clickable { onPick(base) }.padding(horizontal = 12.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.AutoMirrored.Outlined.LibraryBooks, null, Modifier.size(18.dp), tint = Brand.violet)
                Text(base.name, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("Knowledge", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
