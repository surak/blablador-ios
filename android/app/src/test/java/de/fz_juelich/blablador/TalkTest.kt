package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.Talk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TalkTest {
    @Test
    fun wordsAndJoining() {
        assertEquals(listOf("it", "s", "25", "c", "sunny"), Talk.words("It's 25 °C, sunny!"))
        assertEquals("hi", Talk.joined("", "hi"))
        assertEquals("a b", Talk.joined("a", "b"))
    }

    @Test
    fun echoDoesNotInterruptButNewWordsDo() {
        val spoken = Talk.words("The weather in Jülich is sunny today").toSet()
        assertFalse(Talk.interrupts("sunny today", spoken))
        assertFalse(Talk.interrupts("Jülich", spoken))
        assertTrue(Talk.interrupts("what about tomorrow", spoken))
        assertTrue(Talk.interrupts("is sunny stop", spoken))
        assertTrue(Talk.onlyStopWord("is sunny stop", spoken))
        assertEquals(listOf("what", "about", "tomorrow"), Talk.fresh("sunny what about tomorrow", spoken))
    }

    @Test
    fun replyIsCutIntoSentences() {
        val text = "Hello there. It is sunny in Jülich and warm for the season! More"
        // Device voice: every finished sentence.
        assertEquals("Hello there. It is sunny in Jülich and warm for the season! ",
            Talk.nextChunk(text, 0, finished = false, device = true, first = true))
        // Drama 3: the first piece needs 30 characters, later ones 90.
        assertEquals("Hello there. It is sunny in Jülich and warm for the season! ",
            Talk.nextChunk(text, 0, finished = false, device = false, first = true))
        assertNull(Talk.nextChunk("Hi there. More", 0, finished = false, device = false, first = true))
        assertNull(Talk.nextChunk(text, 0, finished = false, device = false, first = false))
        assertEquals("More", Talk.nextChunk(text, text.length - 4, finished = true, device = false, first = false))
        assertNull(Talk.nextChunk(text, text.length, finished = true, device = true, first = true))
    }

    @Test
    fun speakableTextHasNoMarkdown() {
        assertEquals("Title\nBold and link  done", Talk.speakable("## Title\n**Bold** and [link](https://x.y) [1] done"))
        assertEquals("Answer", Talk.speakable("<think>hmm</think>Answer").trim())
    }
}
