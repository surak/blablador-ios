package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.ChatMessage
import de.fz_juelich.blablador.data.ChatRole
import de.fz_juelich.blablador.data.ChatSearch
import de.fz_juelich.blablador.data.Conversation
import de.fz_juelich.blablador.data.Memory
import de.fz_juelich.blablador.data.MemoryStore
import de.fz_juelich.blablador.data.Skill
import de.fz_juelich.blablador.data.WebPage
import de.fz_juelich.blablador.ui.CodeFile
import de.fz_juelich.blablador.ui.MathDetection
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillTest {
    @Test fun frontMatterRoundTrip() {
        val skill = Skill(name = "Meeting notes", description = "When I paste a transcript", instructions = "1. Decisions\n2. Action items")
        val parsed = Skill.fromMarkdown(skill.markdown, "whatever.md")!!
        assertEquals("Meeting notes", parsed.name)
        assertEquals("When I paste a transcript", parsed.description)
        assertEquals("1. Decisions\n2. Action items", parsed.instructions)
    }

    @Test fun fileWithoutFrontMatterUsesFileNameAndFirstLine() {
        val parsed = Skill.fromMarkdown("Write short press releases.\n\nAlways add a quote.", "Press release.md")!!
        assertEquals("Press release", parsed.name)
        assertEquals("Write short press releases.", parsed.description)
    }

    @Test fun emptyFileIsRejected() = assertNull(Skill.fromMarkdown("---\nname: x\n---\n", "x.md"))
}

class MemoryTest {
    @Test fun words() = assertEquals(setOf("the", "gpu", "quota", "jupiter", "2027"), MemoryStore.words("The GPU-quota on JUPITER, 2027!"))

    @Test fun allMemoriesSentWhenFew() {
        val prompt = MemoryStore.systemPrompt((1..5).map { Memory(text = "Fact $it") }, "anything")
        assertTrue(prompt.contains("1. Fact 1"))
        assertTrue(prompt.contains("5. Fact 5"))
    }

    @Test fun onlyRelevantAndNewestSentWhenMany() {
        val memories = (1..60).map { Memory(text = "Unrelated fact number $it") }.toMutableList()
        memories[3] = Memory(text = "The user's cluster is JUPITER")
        val prompt = MemoryStore.systemPrompt(memories, "How busy is JUPITER today?")
        assertTrue("relevant memory keeps its number", prompt.contains("4. The user's cluster is JUPITER"))
        assertTrue("newest are always sent", prompt.contains("60. Unrelated fact number 60"))
        assertFalse(prompt.contains("10. Unrelated fact number 10\n"))
        assertTrue(prompt.contains("other memories aren't shown"))
    }

    @Test fun emptyMemory() = assertTrue(MemoryStore.systemPrompt(emptyList(), "hi").contains("don't remember anything yet"))
}

class ChatSearchTest {
    @Test fun findsEarlierChatButNotCurrent() {
        val gpu = Conversation(title = "GPU quota", model = "m",
            messages = listOf(ChatMessage(role = ChatRole.user, content = "We agreed to raise the GPU quota to 40 nodes in December.")))
        val current = Conversation(title = "Now", model = "m",
            messages = listOf(ChatMessage(role = ChatRole.user, content = "What did we decide about the GPU quota?")))
        val result = ChatSearch.search("GPU quota decision", listOf(gpu, current), current.id)
        assertTrue(result.contains("[GPU quota,"))
        assertTrue(result.contains("40 nodes"))
        assertFalse(result.contains("What did we decide"))
    }

    @Test fun nothingFound() = assertTrue(ChatSearch.search("zebra", emptyList(), null).contains("No earlier chats"))
}

class WebPageTest {
    @Test fun onlyPublicAddresses() {
        assertTrue(WebPage.isPublic("https://www.fz-juelich.de/en"))
        for (address in listOf("http://localhost:8080", "https://192.168.1.10/admin", "https://10.0.0.1", "https://printer.local",
            "https://172.20.0.5", "https://169.254.169.254/latest", "https://[::1]/", "file:///etc/passwd", "https://intranet")) {
            assertFalse(address, WebPage.isPublic(address))
        }
    }

    @Test fun readableTextSkipsScriptsAndMenus() {
        val html = """
            <html><head><title>Test &amp; page</title><script>var secret = 1;</script></head>
            <body><nav>Home | About</nav><article><h1>Heading</h1><p>First &quot;paragraph&quot; with enough words to count as the article body,
            repeated so that it is long enough. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut
            labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo
            consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.</p>
            <ul><li>One</li><li>Two &#8211; three</li></ul></article><footer>Imprint</footer></body></html>
        """.trimIndent()
        assertEquals("Test & page", WebPage.title(html))
        val text = WebPage.readableText(html)
        assertTrue(text, text.contains("## Heading"))
        assertTrue(text, text.contains("First \"paragraph\""))
        assertTrue(text, text.contains("- One"))
        assertTrue(text, text.contains("- Two – three"))
        assertFalse(text.contains("secret"))
        assertFalse(text.contains("Imprint"))
        assertFalse(text.contains("Home | About"))
    }
}

class RenderingTest {
    @Test fun inlineMathButNotPrices() {
        assertTrue(MathDetection.hasInlineMath("The energy is \$E = mc^2\$."))
        assertTrue(MathDetection.hasInlineMath("Inline \\(a^2 + b^2\\) too"))
        assertFalse(MathDetection.hasInlineMath("It costs \$5 and \$10."))
        assertFalse(MathDetection.hasInlineMath("Use \$HOME and \$PATH in the shell"))
        assertFalse(MathDetection.hasInlineMath("No maths here."))
    }

    @Test fun codeFileExtensions() {
        assertEquals("py", CodeFile.fileExtension("Python"))
        assertEquals("sh", CodeFile.fileExtension("bash"))
        assertEquals("txt", CodeFile.fileExtension(""))
        assertEquals("zig", CodeFile.fileExtension("zig"))
    }
}

class HistoryTest {
    private fun wire(message: ChatMessage) = buildJsonObject { put("role", message.role.name); put("content", message.content) }

    @Test fun historyReplacesSummarisedMessages() {
        val conversation = Conversation(title = "Long", model = "m",
            messages = (1..12).map { ChatMessage(role = if (it % 2 == 1) ChatRole.user else ChatRole.assistant, content = "Message $it") },
            summary = "They discussed the JUPITER move.", summaryCount = 4)
        val history = chatHistory("Be brief.", conversation, ::wire)
        assertEquals(1 + 8, history.size)
        val system = history[0]["content"]!!.jsonPrimitive.content
        assertTrue(system.startsWith("Be brief."))
        assertTrue(system.contains("They discussed the JUPITER move."))
        assertEquals("Message 5", history[1]["content"]!!.jsonPrimitive.content)
        assertTrue(requestSize(history) > 0)
    }

    @Test fun historyWithoutSummarySendsEverything() {
        val conversation = Conversation(title = "Short", model = "m", messages = listOf(ChatMessage(role = ChatRole.user, content = "Hi")))
        assertEquals(2, chatHistory("S", conversation, ::wire).size)
    }
}

class DataFilesTest {
    @org.junit.Test
    fun describesTextAndBinaryFiles() {
        val csv = de.fz_juelich.blablador.data.DataFiles.describe("quota.csv", "year,nodes\n2025,10\n2026,40\n".encodeToByteArray())
        org.junit.Assert.assertTrue(csv.contains("/data/quota.csv"))
        org.junit.Assert.assertTrue(csv.contains("year,nodes"))
        val xlsx = de.fz_juelich.blablador.data.DataFiles.describe("Book.xlsx", ByteArray(10))
        org.junit.Assert.assertTrue(xlsx.contains("Binary file"))
        org.junit.Assert.assertTrue(de.fz_juelich.blablador.data.DataFiles.supports("Book.XLSX"))
        org.junit.Assert.assertFalse(de.fz_juelich.blablador.data.DataFiles.supports("app.exe"))
    }
}
