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

    @Test
    fun excelAndPowerPoint() {
        val markdown = """
            # Flights in October
            Summary of **5,000 flights**.

            | Airline | Flights | On time |
            |---|---|---|
            | Lufthansa | 1,234 | 87 % |
            | Eurowings | 980.5 | 91% |

            ## Findings
            - Delays peak on Fridays
            - Morning flights are most punctual

            ## Next steps
            1. Ask for November data
        """.trimIndent()
        val office = de.fz_juelich.blablador.data.OfficeExport
        assertEquals(listOf("Lufthansa", "1,234", "87 %"), office.tables(markdown).first()[1])
        assertEquals(1234.0, office.number("1,234")!!, 0.0)
        assertEquals(0.87, office.number("87 %")!!, 1e-9)
        assertEquals(-3.0, office.number("−3")!!, 0.0)
        assertNull(office.number("Lufthansa"))
        assertNull(office.xlsx("No tables here."))
        val slides = office.slides(markdown)
        assertEquals(listOf("Flights in October", "Findings", "Next steps"), slides.map { it.first })
        assertEquals(listOf("Delays peak on Fridays", "Morning flights are most punctual"), slides[1].second)
        fun names(data: ByteArray) = ZipInputStream(data.inputStream()).use { zip -> generateSequence { zip.nextEntry?.name }.toSet() }
        assertTrue(names(office.xlsx(markdown)!!).containsAll(listOf("xl/workbook.xml", "xl/styles.xml", "xl/worksheets/sheet1.xml")))
        assertTrue(names(office.pptx(markdown)).containsAll(listOf("ppt/presentation.xml", "ppt/slides/slide3.xml", "ppt/theme/theme1.xml")))
    }
}
