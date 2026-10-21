package de.fz_juelich.blablador.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private sealed interface Block {
    data class Text(val body: String) : Block
    data class Code(val language: String, val body: String) : Block
    data class Table(val header: List<String>, val alignments: List<TextAlign>, val rows: List<List<String>>) : Block
}

private fun cells(line: String): List<String> {
    var row = line.trim()
    if (row.startsWith("|")) row = row.drop(1)
    if (row.endsWith("|") && !row.endsWith("\\|")) row = row.dropLast(1)
    val cells = mutableListOf<String>()
    val current = StringBuilder()
    var previous = ' '
    for (c in row) {
        if (c == '|' && previous != '\\') { cells += current.toString(); current.clear() } else current.append(c)
        previous = c
    }
    cells += current.toString()
    return cells.map { it.replace("\\|", "|").trim() }
}

private val separatorPattern = Regex("""^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$""")

private fun separator(line: String): List<TextAlign>? {
    val trimmed = line.trim()
    if (!trimmed.contains("-") || !separatorPattern.matches(trimmed)) return null
    return cells(trimmed).map {
        when {
            it.startsWith(":") && it.endsWith(":") -> TextAlign.Center
            it.endsWith(":") -> TextAlign.End
            else -> TextAlign.Start
        }
    }
}

private fun parse(text: String): List<Block> {
    val result = mutableListOf<Block>()
    val buffer = mutableListOf<String>()
    var inCode = false
    var language = ""
    fun flush() {
        if (buffer.isEmpty()) return
        val joined = buffer.joinToString("\n")
        result += if (inCode) Block.Code(language, joined) else Block.Text(joined)
        buffer.clear()
    }
    val lines = text.split("\n")
    var index = 0
    while (index < lines.size) {
        val line = lines[index]
        val trimmed = line.trim()
        if (trimmed.startsWith("```")) {
            flush()
            if (!inCode) language = trimmed.drop(3)
            inCode = !inCode
        } else if (!inCode && trimmed.contains("|") && index + 1 < lines.size && separator(lines[index + 1]) != null) {
            flush()
            val alignments = separator(lines[index + 1])!!
            val header = cells(trimmed)
            val rows = mutableListOf<List<String>>()
            index += 2
            while (index < lines.size && lines[index].contains("|") && lines[index].isNotBlank()) {
                rows += cells(lines[index]); index++
            }
            val columns = maxOf(header.size, alignments.size)
            fun pad(row: List<String>) = (row + List(columns) { "" }).take(columns)
            result += Block.Table(pad(header), (alignments + List(columns) { TextAlign.Start }).take(columns), rows.map(::pad))
            continue
        } else buffer += line
        index++
    }
    flush()
    return result
}

/** Inline Markdown: **bold**, *italic*, `code`, ~~strike~~ and [links](url). */
fun inline(text: String, codeBackground: androidx.compose.ui.graphics.Color): AnnotatedString = buildAnnotatedString {
    val pattern = Regex("""\*\*(.+?)\*\*|__(.+?)__|(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?!\*)|`([^`]+)`|~~(.+?)~~|\[([^\]]+)]\(([^)\s]+)\)""")
    var last = 0
    for (match in pattern.findAll(text)) {
        append(text.substring(last, match.range.first))
        val g = match.groupValues
        when {
            g[1].isNotEmpty() || g[2].isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(inline(g[1].ifEmpty { g[2] }, codeBackground)) }
            g[3].isNotEmpty() -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(inline(g[3], codeBackground)) }
            g[4].isNotEmpty() -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = codeBackground)) { append(g[4]) }
            g[5].isNotEmpty() -> withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { append(g[5]) }
            g[6].isNotEmpty() && !isSafeLink(g[7]) -> append(g[6])
            g[6].isNotEmpty() -> withLink(androidx.compose.ui.text.LinkAnnotation.Url(g[7],
                androidx.compose.ui.text.TextLinkStyles(SpanStyle(color = Brand.blue)))) { append(g[6]) }
        }
        last = match.range.last + 1
    }
    append(text.substring(last))
}

@Composable
fun MarkdownText(text: String, modifier: Modifier = Modifier) {
    val blocks = remember(text) { parse(text) }
    val codeBackground = MaterialTheme.colorScheme.surfaceVariant
    SelectionContainer(modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            for (block in blocks) when (block) {
                is Block.Text -> Text(paragraphs(block.body, codeBackground), style = MaterialTheme.typography.bodyLarge)
                is Block.Code -> CodeBlock(block.language, block.body)
                is Block.Table -> MarkdownTable(block, codeBackground)
            }
        }
    }
}

private fun paragraphs(body: String, codeBackground: androidx.compose.ui.graphics.Color): AnnotatedString = buildAnnotatedString {
    val lines = body.split("\n").filter { it.isNotBlank() }
    lines.forEachIndexed { index, raw ->
        if (index > 0) append("\n")
        val trimmed = raw.trim()
        val heading = Regex("""^(#{1,6})\s+""").find(trimmed)
        val bullet = Regex("""^([-*+]|\d+\.)\s+""").find(trimmed)
        when {
            heading != null -> withStyle(SpanStyle(fontWeight = FontWeight.Bold, fontSize = if (heading.groupValues[1].length <= 2) 20.sp else 17.sp)) {
                append(inline(trimmed.substring(heading.range.last + 1), codeBackground))
            }
            bullet != null -> {
                val marker = bullet.groupValues[1]
                val indent = "    ".repeat(raw.takeWhile { it == ' ' }.length / 2)
                withStyle(SpanStyle(color = androidx.compose.ui.graphics.Color.Gray)) { append(indent + (if (marker.first().isDigit()) marker else "•") + " ") }
                append(inline(trimmed.substring(bullet.range.last + 1), codeBackground))
            }
            else -> append(inline(trimmed, codeBackground))
        }
    }
}

@Composable
private fun CodeBlock(language: String, code: String) {
    val clipboard = LocalClipboardManager.current
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Row(Modifier.fillMaxWidth().padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(language.ifEmpty { "code" }, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f))
            IconButton(onClick = { clipboard.setText(AnnotatedString(code)) }) {
                Icon(Icons.Outlined.ContentCopy, "Copy code", Modifier.padding(2.dp))
            }
        }
        Text(code, fontFamily = FontFamily.Monospace, fontSize = 13.sp,
            modifier = Modifier.horizontalScroll(rememberScrollState()).padding(start = 12.dp, end = 12.dp, bottom = 12.dp))
    }
}

@Composable
private fun MarkdownTable(table: Block.Table, codeBackground: androidx.compose.ui.graphics.Color) {
    val border = MaterialTheme.colorScheme.outlineVariant
    Column(
        Modifier.horizontalScroll(rememberScrollState())
            .clip(RoundedCornerShape(10.dp)).border(1.dp, border, RoundedCornerShape(10.dp))
            .width(IntrinsicSize.Max)
    ) {
        TableRow(table.header, table.alignments, codeBackground, header = true)
        table.rows.forEach {
            HorizontalDivider(color = border)
            TableRow(it, table.alignments, codeBackground, header = false)
        }
    }
}

@Composable
private fun TableRow(cells: List<String>, alignments: List<TextAlign>, codeBackground: androidx.compose.ui.graphics.Color, header: Boolean) {
    Row(
        Modifier.height(IntrinsicSize.Min).fillMaxWidth()
            .then(if (header) Modifier.background(MaterialTheme.colorScheme.surfaceVariant) else Modifier)
    ) {
        cells.forEachIndexed { column, cell ->
            Text(
                inline(cell.replace(Regex("""<br\s*/?>""", RegexOption.IGNORE_CASE), "\n"), codeBackground),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = if (header) FontWeight.SemiBold else null,
                textAlign = alignments[column],
                modifier = Modifier.weight(1f, fill = true).widthIn(min = 64.dp, max = 260.dp).padding(horizontal = 10.dp, vertical = 7.dp),
            )
        }
    }
}


/** Links from model output open only on the web or as email; other schemes (tel:, sms:, content:…) stay plain text. */
internal fun isSafeLink(url: String) = url.trim().substringBefore(':').lowercase() in setOf("http", "https", "mailto")
