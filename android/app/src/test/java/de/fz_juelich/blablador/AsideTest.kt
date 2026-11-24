package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.AsideTools
import de.fz_juelich.blablador.data.ChatMessage
import de.fz_juelich.blablador.data.ChatRole
import de.fz_juelich.blablador.data.Conversation
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** /btw: a question answered aside while a long reply keeps being written. */
class AsideTest {
    private fun wire(message: ChatMessage) = buildJsonObject { put("role", message.role.name); put("content", message.content) }

    @Test fun commandParsing() {
        assertEquals("what is JUPITER?", AsideTools.command("/btw what is JUPITER?"))
        assertEquals("Write it in German", AsideTools.command("  /BTW  Write it in German "))
        assertEquals("and that?", AsideTools.command("/btw\nand that?"))
        assertEquals("", AsideTools.command("/btw"))
        assertNull(AsideTools.command("/btwish"))
        assertNull(AsideTools.command("so /btw what"))
        assertNull(AsideTools.command("/goal do it"))
    }

    /** The aside reads the chat up to where the long reply started, and never that reply itself, which is only half written. */
    @Test fun promptSeesTheChatBeforeTheReplyBeingWritten() {
        val conversation = chatHistory("You are Blablador.", Conversation(title = "x", model = "m"), ::wire)
        val prompt = AsideTools.prompt("And what is JUPITER?", conversation)
        assertEquals("system", prompt.first()["role"]!!.jsonPrimitive.content)
        assertEquals("And what is JUPITER?", prompt.last()["content"]!!.jsonPrimitive.content)
        assertTrue(prompt.first()["content"]!!.jsonPrimitive.content.contains("aside"))
        assertFalse(prompt.any { it["content"]?.jsonPrimitive?.content == "The first half of a long answer" })
    }

    /** The note that keeps the long reply on its own task names the aside, so the model can ignore it. */
    @Test fun resumeNoteNamesTheQuestion() {
        val note = AsideTools.resumeNote("what is JUPITER?")
        assertTrue(note.contains("what is JUPITER?"))
        assertFalse(note.contains("{{question}}"))
        // A model that quotes the question at length can't push its own answer out of the window.
        assertTrue(AsideTools.resumeNote("x".repeat(5_000)).length < 1_000)
    }

    /** A chat asked aside carries the chat it came from, so it can be followed up like any other. */
    @Test fun keptAsideChatCarriesItsContext() {
        val aside = Conversation(
            title = "And what is JUPITER?", model = "m",
            messages = listOf(
                ChatMessage(role = ChatRole.user, content = "And what is JUPITER?"),
                ChatMessage(role = ChatRole.assistant, content = "A JUWELS Booster partition at JSC."),
            ),
            context = listOf(
                ChatMessage(role = ChatRole.user, content = "Write a long report on our clusters."),
                ChatMessage(role = ChatRole.assistant, content = "Here is the first part…"),
            ),
        )
        val history = chatHistory("You are Blablador.", aside, ::wire).map { it["content"]!!.jsonPrimitive.content }
        assertEquals("You are Blablador.", history.first())
        assertEquals(listOf("Write a long report on our clusters.", "Here is the first part…"), history.drop(1).take(2))
        assertEquals("A JUWELS Booster partition at JSC.", history.last())
    }
}
