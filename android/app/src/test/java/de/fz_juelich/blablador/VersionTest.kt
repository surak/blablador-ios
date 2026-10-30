package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.ChatMessage
import de.fz_juelich.blablador.data.ChatRole
import de.fz_juelich.blablador.data.Conversation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VersionTest {
    private fun message(role: ChatRole, text: String) = ChatMessage(role = role, content = text)

    /** Edits the user message at [index] like ChatViewModel.edit, then appends a reply. */
    private fun edit(messages: List<ChatMessage>, index: Int, text: String, reply: String): List<ChatMessage> {
        val (alternatives, version) = versions(messages.drop(index))
        return messages.take(index) + message(ChatRole.user, text).copy(alternatives = alternatives, version = version) +
            message(ChatRole.assistant, reply)
    }

    @Test fun editKeepsEarlierVersionsAndSwitchingIsLossless() {
        val start = listOf(message(ChatRole.user, "Hi"), message(ChatRole.assistant, "Hello"),
            message(ChatRole.user, "Plot sin"), message(ChatRole.assistant, "Here is sin"))
        val third = edit(edit(start, 2, "Plot cos", "Here is cos"), 2, "Plot tan", "Here is tan")

        assertEquals(listOf("Hi", "Hello", "Plot tan", "Here is tan"), third.map { it.content })
        assertEquals(3, third[2].version)
        assertEquals(listOf(listOf("Plot sin", "Here is sin"), listOf("Plot cos", "Here is cos")),
            third[2].alternatives.map { tail -> tail.map { it.content } })

        val v2 = messagesShowingVersion(third, -1, 2)!!
        assertEquals(listOf("Hi", "Hello", "Plot cos", "Here is cos"), v2.map { it.content })
        val v1 = messagesShowingVersion(v2, -1, 2)!!
        assertEquals(listOf("Hi", "Hello", "Plot sin", "Here is sin"), v1.map { it.content })
        assertNull("no version before the first", messagesShowingVersion(v1, -1, 2))
        val back = messagesShowingVersion(messagesShowingVersion(v1, 1, 2)!!, 1, 2)!!
        assertEquals(third.map { it.content }, back.map { it.content })
        assertEquals("no version lost or duplicated", 2, back[2].alternatives.size)
        assertNull(messagesShowingVersion(back, 1, 2))
    }

    @Test fun editingAnOlderVersionAddsANewOneAtTheEnd() {
        val start = listOf(message(ChatRole.user, "A"), message(ChatRole.assistant, "a"))
        val first = messagesShowingVersion(edit(start, 0, "B", "b"), -1, 0)!!
        val third = edit(first, 0, "C", "c")
        assertEquals(3, third[0].version)
        assertEquals(setOf("A", "B"), third[0].alternatives.map { it.first().content }.toSet())
    }

    @Test fun allMessagesIncludesEveryVersion() {
        val conversation = Conversation(title = "t", model = "m",
            messages = edit(listOf(message(ChatRole.user, "old"), message(ChatRole.assistant, "old reply")), 0, "new", "new reply"))
        assertEquals(setOf("old", "old reply", "new", "new reply"), conversation.allMessages.map { it.content }.toSet())
    }

    @Test fun versionsSurviveSerialisation() {
        val messages = edit(listOf(message(ChatRole.user, "old"), message(ChatRole.assistant, "r")), 0, "new", "r2")
        val json = de.fz_juelich.blablador.data.BlabladorApi.json
        val serializer = kotlinx.serialization.builtins.ListSerializer(ChatMessage.serializer())
        val decoded = json.decodeFromString(serializer, json.encodeToString(serializer, messages))
        assertEquals(2, decoded[0].version)
        assertEquals("old", decoded[0].alternatives[0][0].content)
    }
}
