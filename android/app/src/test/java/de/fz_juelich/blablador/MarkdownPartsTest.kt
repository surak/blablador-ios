package de.fz_juelich.blablador

import de.fz_juelich.blablador.ui.Part
import de.fz_juelich.blablador.ui.citationMark
import de.fz_juelich.blablador.ui.parts
import org.junit.Assert.assertEquals
import org.junit.Test

class MarkdownPartsTest {
    @Test
    fun textSplitsAtBlankLinesHeadingsRulesAndQuotes() {
        val text = "## News\nFirst line\nsecond line\n\nNext paragraph\n> quoted\n> more\n---\n### Small\nEnd"
        assertEquals(listOf(
            Part.Heading(2, "News"),
            Part.Paragraph("First line\nsecond line"),
            Part.Paragraph("Next paragraph"),
            Part.Quote("quoted\nmore"),
            Part.Rule,
            Part.Heading(3, "Small"),
            Part.Paragraph("End"),
        ), parts(text))
    }

    @Test
    fun citationRunsBecomeOneMark() {
        assertEquals("[27,29,30]", citationMark("[27][29][30]"))
    }

    @Test
    fun listsAndBoldLines() {
        val text = "**Steps:**\n- one\n  continued\n\n- two\n  * nested\n3) third\nAfter"
        assertEquals(listOf(
            Part.Heading(4, "Steps:".removeSuffix(":")),
            Part.Items(listOf(
                Part.ListItem("•", "one continued", 0),
                Part.ListItem("•", "two", 0),
                Part.ListItem("•", "nested", 1),
                Part.ListItem("3.", "third", 0),
            )),
            Part.Paragraph("After"),
        ), parts(text))
    }
}
