package de.fz_juelich.blablador.data

import de.fz_juelich.blablador.data.DocumentExport.Block
import de.fz_juelich.blablador.data.DocumentExport.xml

/** Answers as Excel workbooks (their tables) and PowerPoint slides (one per heading), next to Word in [DocumentExport]. */
object OfficeExport {
    /** The answer's tables (Markdown tables, or a CSV code block), each as rows of cells. */
    fun tables(markdown: String): List<List<List<String>>> {
        val blocks = DocumentExport.blocks(markdown)
        fun plain(text: String) = DocumentExport.spans(text).joinToString("") { it.text }
        val tables = blocks.filterIsInstance<Block.Table>().map { table -> table.rows.map { row -> row.map(::plain) } }.toMutableList()
        if (tables.isEmpty()) for (block in blocks) {
            if (block is Block.Code && ',' in block.text && block.text.split("\n").filter { it.isNotEmpty() }.size > 1) {
                tables += block.text.split("\n").filter { it.isNotEmpty() }.map(::csvCells)
            }
        }
        return tables
    }

    fun csvCells(line: String): List<String> {
        val cells = mutableListOf<String>()
        val current = StringBuilder()
        var quoted = false
        var i = 0
        while (i < line.length) {
            val c = line[i]
            when {
                c == '"' && quoted && i + 1 < line.length && line[i + 1] == '"' -> { current.append('"'); i++ }
                c == '"' -> quoted = !quoted
                c == ',' && !quoted -> { cells += current.toString(); current.clear() }
                else -> current.append(c)
            }
            i++
        }
        cells += current.toString()
        return cells.map { it.trim() }
    }

    private fun column(index: Int): String {
        var i = index
        var name = ""
        do {
            name = ('A' + i % 26) + name
            i = i / 26 - 1
        } while (i >= 0)
        return name
    }

    /** A number in a cell ("1,234.5", "12 %", "−3"), or null for text. */
    fun number(text: String): Double? {
        var value = text.trim().replace("−", "-")
        val percent = value.endsWith("%")
        if (percent) value = value.dropLast(1).trim()
        if (!Regex("""^-?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$""").matches(value)) return null
        val number = value.replace(",", "").toDoubleOrNull() ?: return null
        return if (percent) number / 100 else number
    }

    private const val HEAD = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private const val RELS_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
    private const val REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /** An Excel workbook with one sheet per table; the first row is bold and numbers are numbers. */
    fun xlsx(markdown: String): ByteArray? {
        val tables = tables(markdown)
        if (tables.isEmpty()) return null
        val files = mutableListOf<Pair<String, String>>()
        val sheets = StringBuilder(); val sheetRels = StringBuilder(); val overrides = StringBuilder()
        tables.forEachIndexed { index, rows ->
            val n = index + 1
            val data = StringBuilder()
            rows.forEachIndexed { r, row ->
                data.append("<row r=\"${r + 1}\">")
                row.forEachIndexed { c, cell ->
                    val reference = column(c) + (r + 1)
                    val style = if (r == 0) " s=\"1\"" else ""
                    val value = if (r > 0) number(cell) else null
                    if (value != null) data.append("<c r=\"$reference\"${if (cell.endsWith("%")) " s=\"2\"" else style}><v>$value</v></c>")
                    else data.append("<c r=\"$reference\" t=\"inlineStr\"$style><is><t xml:space=\"preserve\">${xml(cell)}</t></is></c>")
                }
                data.append("</row>")
            }
            val widths = (0 until (rows.maxOfOrNull { it.size } ?: 1)).joinToString("") { c ->
                val longest = rows.maxOfOrNull { if (c < it.size) it[c].length else 0 } ?: 8
                "<col min=\"${c + 1}\" max=\"${c + 1}\" width=\"${minOf(maxOf(longest + 2, 8), 60)}\" customWidth=\"1\"/>"
            }
            files += "xl/worksheets/sheet$n.xml" to HEAD + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetViews><sheetView workbookViewId=\"0\">" +
                "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><cols>$widths</cols><sheetData>$data</sheetData></worksheet>"
            sheets.append("<sheet name=\"${if (tables.size == 1) "Table" else "Table $n"}\" sheetId=\"$n\" r:id=\"rId$n\"/>")
            sheetRels.append("<Relationship Id=\"rId$n\" Type=\"$REL/worksheet\" Target=\"worksheets/sheet$n.xml\"/>")
            overrides.append("<Override PartName=\"/xl/worksheets/sheet$n.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>")
        }
        val styles = HEAD + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font>" +
            "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>" +
            "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFEDE9FE\"/><bgColor indexed=\"64\"/></patternFill></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>" +
            "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"3\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" +
            "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"/><xf numFmtId=\"10\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs>" +
            "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
        val workbook = HEAD + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"$REL\"><sheets>$sheets</sheets></workbook>"
        val workbookRels = HEAD + "<Relationships xmlns=\"$RELS_NS\">$sheetRels<Relationship Id=\"rId${tables.size + 1}\" Type=\"$REL/styles\" Target=\"styles.xml\"/></Relationships>"
        val contentTypes = HEAD + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" +
            "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>$overrides</Types>"
        val rels = HEAD + "<Relationships xmlns=\"$RELS_NS\"><Relationship Id=\"rId1\" Type=\"$REL/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        return DocumentExport.zip(listOf("[Content_Types].xml" to contentTypes, "_rels/.rels" to rels, "xl/workbook.xml" to workbook,
            "xl/_rels/workbook.xml.rels" to workbookRels, "xl/styles.xml" to styles) + files)
    }

    /** Slides from the answer: each heading starts a slide; its paragraphs and list items become bullets. */
    fun slides(markdown: String): List<Pair<String, List<String>>> {
        val slides = mutableListOf<Pair<String, MutableList<String>>>()
        fun plain(text: String) = DocumentExport.spans(text).joinToString("") { it.text }
        fun current(): MutableList<String> {
            if (slides.isEmpty()) slides += DocumentExport.fileName(markdown) to mutableListOf()
            return slides.last().second
        }
        for (block in DocumentExport.blocks(markdown)) when (block) {
            is Block.Heading -> slides += plain(block.text) to mutableListOf()
            is Block.Paragraph -> current() += plain(block.text)
            is Block.Bullet -> current() += plain(block.text)
            is Block.Quote -> current() += plain(block.text)
            is Block.Table -> current() += block.rows.map { row -> row.joinToString(" · ") { plain(it) } }
            else -> {}
        }
        // Long sections continue on a second slide rather than overflowing.
        return slides.flatMap { (title, bullets) ->
            if (bullets.size <= 7) listOf(title to bullets.toList())
            else bullets.chunked(7).mapIndexed { index, chunk -> (if (index == 0) title else "$title (continued)") to chunk }
        }
    }

    private const val DRAWING = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"$REL\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""

    private fun textBox(id: Int, name: String, x: Int, y: Int, width: Int, height: Int, paragraphs: String) =
        "<p:sp><p:nvSpPr><p:cNvPr id=\"$id\" name=\"$name\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"$x\" y=\"$y\"/><a:ext cx=\"$width\" cy=\"$height\"/></a:xfrm>" +
            "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"square\"><a:normAutofit/></a:bodyPr><a:lstStyle/>$paragraphs</p:txBody></p:sp>"

    /** A PowerPoint presentation (16:9), one slide per heading. */
    fun pptx(markdown: String): ByteArray {
        val slides = slides(markdown).ifEmpty { listOf(DocumentExport.fileName(markdown) to emptyList()) }
        val emptyTree = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree>"
        val files = mutableListOf<Pair<String, String>>()
        val slideIds = StringBuilder(); val presentationRels = StringBuilder(); val overrides = StringBuilder()
        slides.forEachIndexed { index, (title, bullets) ->
            val n = index + 1
            val titleXml = "<a:p><a:r><a:rPr lang=\"en-US\" sz=\"3600\" b=\"1\"><a:solidFill><a:srgbClr val=\"4C1D95\"/></a:solidFill></a:rPr><a:t>${xml(title)}</a:t></a:r></a:p>"
            val bulletXml = if (bullets.isEmpty()) "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>" else bullets.joinToString("") {
                "<a:p><a:pPr marL=\"342900\" indent=\"-342900\"><a:spcBef><a:spcPts val=\"900\"/></a:spcBef><a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/></a:pPr>" +
                    "<a:r><a:rPr lang=\"en-US\" sz=\"2000\"/><a:t>${xml(it)}</a:t></a:r></a:p>"
            }
            val shapes = textBox(2, "Title", 609600, 457200, 10972800, 1143000, titleXml) + textBox(3, "Content", 609600, 1714500, 10972800, 4572000, bulletXml)
            files += "ppt/slides/slide$n.xml" to HEAD + "<p:sld $DRAWING><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>$shapes</p:spTree></p:cSld>" +
                "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            files += "ppt/slides/_rels/slide$n.xml.rels" to HEAD + "<Relationships xmlns=\"$RELS_NS\"><Relationship Id=\"rId1\" Type=\"$REL/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/></Relationships>"
            slideIds.append("<p:sldId id=\"${255 + n}\" r:id=\"rId${n + 1}\"/>")
            presentationRels.append("<Relationship Id=\"rId${n + 1}\" Type=\"$REL/slide\" Target=\"slides/slide$n.xml\"/>")
            overrides.append("<Override PartName=\"/ppt/slides/slide$n.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>")
        }
        val themeId = slides.size + 2
        val presentation = HEAD + "<p:presentation $DRAWING><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>$slideIds</p:sldIdLst>" +
            "<p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        val presentationRelsXml = HEAD + "<Relationships xmlns=\"$RELS_NS\"><Relationship Id=\"rId1\" Type=\"$REL/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>$presentationRels" +
            "<Relationship Id=\"rId$themeId\" Type=\"$REL/theme\" Target=\"theme/theme1.xml\"/></Relationships>"
        val master = HEAD + "<p:sldMaster $DRAWING><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>$emptyTree</p:cSld>" +
            "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>" +
            "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>"
        val masterRels = HEAD + "<Relationships xmlns=\"$RELS_NS\"><Relationship Id=\"rId1\" Type=\"$REL/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" +
            "<Relationship Id=\"rId2\" Type=\"$REL/theme\" Target=\"../theme/theme1.xml\"/></Relationships>"
        val layout = HEAD + "<p:sldLayout $DRAWING type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\">$emptyTree</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        val layoutRels = HEAD + "<Relationships xmlns=\"$RELS_NS\"><Relationship Id=\"rId1\" Type=\"$REL/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>"
        val colors = listOf("dk1" to "000000", "lt1" to "FFFFFF", "dk2" to "1F2937", "lt2" to "F3F4F6", "accent1" to "6366F1", "accent2" to "8B5CF6",
            "accent3" to "EC4899", "accent4" to "10B981", "accent5" to "F59E0B", "accent6" to "3B82F6", "hlink" to "2563EB", "folHlink" to "7C3AED")
            .joinToString("") { (name, value) -> "<a:$name><a:srgbClr val=\"$value\"/></a:$name>" }
        val fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        val line = "<a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
        val theme = HEAD + "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Blablador\"><a:themeElements><a:clrScheme name=\"Blablador\">$colors</a:clrScheme>" +
            "<a:fontScheme name=\"Blablador\"><a:majorFont><a:latin typeface=\"Helvetica Neue\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Helvetica Neue\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>" +
            "<a:fmtScheme name=\"Blablador\"><a:fillStyleLst>$fill$fill$fill</a:fillStyleLst><a:lnStyleLst>$line$line$line</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle>" +
            "<a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>$fill$fill$fill</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
        val contentTypes = HEAD + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>" +
            "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>" +
            "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>" +
            "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>$overrides</Types>"
        val rels = HEAD + "<Relationships xmlns=\"$RELS_NS\"><Relationship Id=\"rId1\" Type=\"$REL/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>"
        return DocumentExport.zip(listOf("[Content_Types].xml" to contentTypes, "_rels/.rels" to rels, "ppt/presentation.xml" to presentation,
            "ppt/_rels/presentation.xml.rels" to presentationRelsXml, "ppt/slideMasters/slideMaster1.xml" to master,
            "ppt/slideMasters/_rels/slideMaster1.xml.rels" to masterRels, "ppt/slideLayouts/slideLayout1.xml" to layout,
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels" to layoutRels, "ppt/theme/theme1.xml" to theme) + files)
    }
}
