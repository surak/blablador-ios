package de.fz_juelich.blablador.data

import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Answers as documents: formatted text on the clipboard (pastes with headings, lists and tables into Google Docs,
 * Word or mail) and Word files. Works from the answer's Markdown, without Google or any server.
 */
object DocumentExport {
    sealed interface Block {
        data class Heading(val level: Int, val text: String) : Block
        data class Paragraph(val text: String) : Block
        data class Bullet(val text: String, val ordered: Int?) : Block
        data class Quote(val text: String) : Block
        data class Code(val text: String) : Block
        data class Table(val rows: List<List<String>>) : Block
        data object Rule : Block
    }

    fun blocks(markdown: String): List<Block> {
        val blocks = mutableListOf<Block>()
        val paragraph = mutableListOf<String>()
        var code: MutableList<String>? = null
        val table = mutableListOf<List<String>>()
        fun flushParagraph() { if (paragraph.isNotEmpty()) blocks += Block.Paragraph(paragraph.joinToString(" ")); paragraph.clear() }
        fun flushTable() { if (table.isNotEmpty()) blocks += Block.Table(table.toList()); table.clear() }
        for (raw in markdown.split("\n")) {
            val line = raw.trim()
            if (line.startsWith("```")) {
                flushParagraph(); flushTable()
                val current = code
                if (current != null) { blocks += Block.Code(current.joinToString("\n")); code = null } else code = mutableListOf()
                continue
            }
            val open = code
            if (open != null) { open += raw; continue }
            if (line.startsWith("|")) {
                flushParagraph()
                val cells = line.trim('|').split("|").map { it.trim() }
                if (!cells.all { Regex("""^:?-+:?$""").matches(it) }) table += cells
                continue
            }
            flushTable()
            val heading = Regex("""^(#{1,6})\s+""").find(line)
            val bullet = Regex("""^[-*+]\s+""").find(line)
            val ordered = Regex("""^(\d+)[.)]\s+""").find(line)
            when {
                line.isEmpty() -> flushParagraph()
                heading != null -> { flushParagraph(); blocks += Block.Heading(heading.groupValues[1].length, line.substring(heading.range.last + 1)) }
                Regex("""^([-*_])(\s*\1){2,}$""").matches(line) -> { flushParagraph(); blocks += Block.Rule }
                bullet != null -> { flushParagraph(); blocks += Block.Bullet(line.substring(bullet.range.last + 1), null) }
                ordered != null -> { flushParagraph(); blocks += Block.Bullet(line.substring(ordered.range.last + 1), ordered.groupValues[1].toIntOrNull()) }
                line.startsWith(">") -> { flushParagraph(); blocks += Block.Quote(line.drop(1).trim()) }
                else -> paragraph += line
            }
        }
        code?.let { blocks += Block.Code(it.joinToString("\n")) }
        flushParagraph(); flushTable()
        return blocks
    }

    /** Inline spans: bold, italic, code and links; source marks like [3] are dropped. */
    data class Span(val text: String, val bold: Boolean = false, val italic: Boolean = false, val code: Boolean = false, val link: String? = null)

    fun spans(text: String): List<Span> {
        val cleaned = text.replace(Regex("""\s?(\[\d{1,3}])+"""), "")
        val pattern = Regex("""\*\*(.+?)\*\*|__(.+?)__|\*(.+?)\*|_(.+?)_|`(.+?)`|\[([^\]]+)]\(([^)\s]+)\)""")
        val spans = mutableListOf<Span>()
        var last = 0
        for (match in pattern.findAll(cleaned)) {
            if (match.range.first > last) spans += Span(cleaned.substring(last, match.range.first))
            val g = match.groupValues
            spans += when {
                g[1].isNotEmpty() || g[2].isNotEmpty() -> Span(g[1].ifEmpty { g[2] }, bold = true)
                g[3].isNotEmpty() || g[4].isNotEmpty() -> Span(g[3].ifEmpty { g[4] }, italic = true)
                g[5].isNotEmpty() -> Span(g[5], code = true)
                else -> Span(g[6], link = g[7])
            }
            last = match.range.last + 1
        }
        if (last < cleaned.length) spans += Span(cleaned.substring(last))
        return spans
    }

    private fun escape(text: String) = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    fun inlineHtml(text: String): String = spans(text).joinToString("") { span ->
        var html = escape(span.text)
        if (span.code) html = "<code>$html</code>"
        if (span.italic) html = "<em>$html</em>"
        if (span.bold) html = "<strong>$html</strong>"
        span.link?.let { html = "<a href=\"${escape(it)}\">$html</a>" }
        html
    }

    fun html(markdown: String): String {
        val html = StringBuilder()
        var list: String? = null
        for (block in blocks(markdown)) {
            val tag = (block as? Block.Bullet)?.let { if (it.ordered == null) "ul" else "ol" }
            if (list != tag) {
                list?.let { html.append("</$it>") }
                tag?.let { html.append("<$it>") }
                list = tag
            }
            when (block) {
                is Block.Heading -> html.append("<h${block.level}>${inlineHtml(block.text)}</h${block.level}>")
                is Block.Paragraph -> html.append("<p>${inlineHtml(block.text)}</p>")
                is Block.Bullet -> html.append("<li>${inlineHtml(block.text)}</li>")
                is Block.Quote -> html.append("<blockquote>${inlineHtml(block.text)}</blockquote>")
                is Block.Code -> html.append("<pre><code>${escape(block.text)}</code></pre>")
                Block.Rule -> html.append("<hr>")
                is Block.Table -> {
                    html.append("<table border=\"1\" style=\"border-collapse:collapse\">")
                    block.rows.forEachIndexed { index, row ->
                        val cell = if (index == 0) "th" else "td"
                        html.append("<tr>" + row.joinToString("") { "<$cell style=\"padding:4px 8px\">${inlineHtml(it)}</$cell>" } + "</tr>")
                    }
                    html.append("</table>")
                }
            }
        }
        list?.let { html.append("</$it>") }
        return "<meta charset=\"utf-8\">$html"
    }

    /** Plain text for apps that don't take formatting. */
    fun plain(markdown: String): String = blocks(markdown).joinToString("\n\n") { block ->
        fun text(value: String) = spans(value).joinToString("") { it.text }
        when (block) {
            is Block.Heading -> text(block.text)
            is Block.Paragraph -> text(block.text)
            is Block.Bullet -> (block.ordered?.let { "$it. " } ?: "• ") + text(block.text)
            is Block.Quote -> "“" + text(block.text) + "”"
            is Block.Code -> block.text
            is Block.Table -> block.rows.joinToString("\n") { row -> row.joinToString("\t") { text(it) } }
            Block.Rule -> "———"
        }
    }

    internal fun xml(text: String) = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    private fun runs(text: String, size: Int? = null, bold: Boolean = false, mono: Boolean = false): String = spans(text).joinToString("") { span ->
        var properties = ""
        if (bold || span.bold) properties += "<w:b/>"
        if (span.italic) properties += "<w:i/>"
        if (mono || span.code) properties += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/>"
        if (span.link != null) properties += "<w:color w:val=\"1A56DB\"/><w:u w:val=\"single\"/>"
        size?.let { properties += "<w:sz w:val=\"$it\"/>" }
        "<w:r><w:rPr>$properties</w:rPr><w:t xml:space=\"preserve\">${xml(span.text)}</w:t></w:r>"
    }

    private fun paragraph(content: String, spacingAfter: Int = 160, indent: Int? = null, style: String = "") =
        "<w:p><w:pPr>$style<w:spacing w:after=\"$spacingAfter\"/>${indent?.let { "<w:ind w:left=\"$it\" w:hanging=\"260\"/>" } ?: ""}</w:pPr>$content</w:p>"

    fun documentXml(markdown: String): String {
        val body = StringBuilder()
        for (block in blocks(markdown)) when (block) {
            is Block.Heading -> {
                val size = mapOf(1 to 36, 2 to 30, 3 to 26)[block.level] ?: 24
                body.append(paragraph(runs(block.text, size, bold = true), 120, style = "<w:pStyle w:val=\"Heading${minOf(block.level, 6)}\"/><w:keepNext/>"))
            }
            is Block.Paragraph -> body.append(paragraph(runs(block.text)))
            is Block.Bullet -> body.append(paragraph("<w:r><w:t xml:space=\"preserve\">${block.ordered?.let { "$it." } ?: "•"}\t</w:t></w:r>" + runs(block.text), 60, 520))
            is Block.Quote -> body.append("<w:p><w:pPr><w:ind w:left=\"520\"/><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"8B5CF6\"/></w:pBdr></w:pPr>${runs(block.text)}</w:p>")
            is Block.Code -> block.text.split("\n").forEach { body.append(paragraph(runs(it, mono = true), 0)) }
            Block.Rule -> body.append("<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BBBBBB\"/></w:pBdr></w:pPr></w:p>")
            is Block.Table -> {
                body.append("<w:tbl><w:tblPr><w:tblBorders>" + listOf("top", "left", "bottom", "right", "insideH", "insideV")
                    .joinToString("") { "<w:$it w:val=\"single\" w:sz=\"4\" w:color=\"BBBBBB\"/>" } + "</w:tblBorders></w:tblPr>")
                block.rows.forEachIndexed { index, row ->
                    body.append("<w:tr>" + row.joinToString("") { "<w:tc><w:p>${runs(it, bold = index == 0)}</w:p></w:tc>" } + "</w:tr>")
                }
                body.append("</w:tbl>" + paragraph(""))
            }
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
            "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>$body" +
            "<w:sectPr><w:pgMar w:top=\"1200\" w:right=\"1200\" w:bottom=\"1200\" w:left=\"1200\"/></w:sectPr></w:body></w:document>"
    }

    /** A Word document from Markdown: headings, paragraphs, bold/italic, lists, quotes, code and tables. */
    fun docx(markdown: String): ByteArray {
        val contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"
        val rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" " +
            "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, text) in listOf("[Content_Types].xml" to contentTypes, "_rels/.rels" to rels, "word/document.xml" to documentXml(markdown))) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(text.toByteArray())
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    /** A ZIP of text files, as Office files are. */
    internal fun zip(files: List<Pair<String, String>>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, text) in files) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(text.toByteArray())
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    /** A file name from the answer's first heading or words. */
    fun fileName(markdown: String): String {
        val first = blocks(markdown).firstNotNullOfOrNull { block ->
            when (block) {
                is Block.Heading -> block.text
                is Block.Paragraph -> block.text
                else -> null
            }?.let { text -> spans(text).joinToString("") { it.text } }
        } ?: "Blablador"
        val name = first.filterNot { it in "/\\:?*\"<>|" }.take(60).trim()
        return name.ifEmpty { "Blablador" }
    }
}
