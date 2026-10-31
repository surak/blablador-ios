package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.DocumentExport
import de.fz_juelich.blablador.data.GoogleDocs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.zip.ZipInputStream

class DocumentTest {
    @Test
    fun googleLinks() {
        val doc = GoogleDocs.link("https://docs.google.com/document/d/1XzCHG9ONiNIYqx750-CxmGkOpuQI5thEvkuIwEdzoHY/edit?usp=sharing")
        assertEquals(GoogleDocs.Kind.document, doc?.kind)
        assertEquals(listOf("md", "txt"), GoogleDocs.exports(doc!!).map { it.second })
        val sheet = GoogleDocs.link("https://docs.google.com/spreadsheets/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/edit#gid=42")
        assertEquals("42", sheet?.gid)
        assertTrue(GoogleDocs.exports(sheet!!)[0].first.endsWith("export?format=csv&gid=42"))
        assertEquals(GoogleDocs.Kind.presentation, GoogleDocs.link("https://docs.google.com/presentation/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/edit")?.kind)
        assertNull(GoogleDocs.link("https://example.org/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"))
    }

    private val sample = """
        # Report
        Intro with **bold**, *italic* and a [link](https://fz-juelich.de). [3][4]

        - first
        - second

        | Name | Value |
        |---|---|
        | A | 1 |

        > A quote
    """.trimIndent()

    @Test
    fun htmlKeepsStructure() {
        val html = DocumentExport.html(sample)
        assertTrue(html.contains("<h1>Report</h1>"))
        assertTrue(html.contains("<strong>bold</strong>"))
        assertTrue(html.contains("<a href=\"https://fz-juelich.de\">link</a>"))
        assertFalse(html.contains("[3]"))
        assertTrue(html.contains("<ul><li>first</li><li>second</li></ul>"))
        assertTrue(html.contains("<th style=\"padding:4px 8px\">Name</th>"))
        assertTrue(html.contains("<blockquote>A quote</blockquote>"))
        assertTrue(DocumentExport.plain(sample).contains("• first"))
        assertEquals("Report", DocumentExport.fileName(sample))
    }

    @Test
    fun wordFileHasItsParts() {
        val entries = mutableMapOf<String, String>()
        ZipInputStream(DocumentExport.docx(sample).inputStream()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                entries[entry.name] = zip.readBytes().decodeToString()
            }
        }
        assertEquals(setOf("[Content_Types].xml", "_rels/.rels", "word/document.xml"), entries.keys)
        val document = entries.getValue("word/document.xml")
        listOf("Report", "bold", "second", "Value").forEach { assertTrue(it, document.contains(it)) }
    }
}
