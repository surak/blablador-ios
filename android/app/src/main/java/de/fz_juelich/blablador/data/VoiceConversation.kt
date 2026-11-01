package de.fz_juelich.blablador.data

/** The pure parts of talking with Blablador: words, interrupting and cutting the streaming reply into pieces to speak. */
object Talk {
    /** Seconds of quiet after speech that end the user's turn. */
    const val PAUSE_MS = 1_200L

    const val SYSTEM_PROMPT = "The user is talking with you by voice and your answer is read aloud while you write it. Answer like in a conversation: short, natural spoken sentences in the user's language, no Markdown, headings, lists, tables, emoji, code or links unless they ask; write numbers, units and abbreviations the way they are spoken. Ask a short question back when it helps. You can still use tools."

    private val stopWords = setOf("stop", "wait", "stopp", "warte", "halt", "arrête")
    private val sentenceEnd = Regex("""[.!?…:;](\s|$)|\n""")

    fun words(text: String): List<String> =
        text.lowercase().split(Regex("""[^\p{L}\p{N}]+""")).filter { it.isNotEmpty() }

    fun joined(first: String, second: String) = listOf(first, second).filter { it.isNotEmpty() }.joinToString(" ")

    /** Words heard over the reply that weren't in what was spoken (its echo). */
    fun fresh(heard: String, spoken: Set<String>) = words(heard).filter { it !in spoken }

    /** Two new words, or a stop word at the end, interrupt the reply. */
    fun interrupts(heard: String, spoken: Set<String>): Boolean {
        val last = words(heard).lastOrNull()
        return fresh(heard, spoken).size >= 2 || (last != null && last in stopWords && last !in spoken)
    }

    /** Whether the interruption was only a stop word (nothing to carry into the next turn). */
    fun onlyStopWord(heard: String, spoken: Set<String>): Boolean = fresh(heard, spoken).size < 2

    /**
     * The next piece of [text] to speak after [consumed] characters, or null to wait for more.
     * Drama 3 takes a few seconds per request: the first piece is short, later ones bigger; the device voice speaks every sentence.
     */
    fun nextChunk(text: String, consumed: Int, finished: Boolean, device: Boolean, first: Boolean): String? {
        if (text.length <= consumed) return null
        val rest = text.substring(consumed)
        val end = if (finished) rest.length else sentenceEnd.findAll(rest).lastOrNull()?.range?.last?.plus(1) ?: return null
        val chunk = rest.substring(0, end)
        val minimum = if (device) 1 else if (first) 30 else 90
        if (!finished && chunk.length < minimum) return null
        return chunk
    }

    /** Text as it is read out: no thinking, code, citation marks, links or Markdown symbols. */
    fun speakable(content: String) = splitThinking(content).second
        .replace(Regex("""```[\s\S]*?```"""), " ")
        .replace(Regex("""\[\d+]"""), "")
        .replace(Regex("""\[([^\]]+)]\([^)]+\)"""), "$1")
        .replace(Regex("""(?m)^\s*(#{1,6}|[-*+]|\d+\.)\s+"""), "")
        .replace(Regex("""[*_`>|]+"""), "")
}
