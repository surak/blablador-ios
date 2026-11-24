package de.fz_juelich.blablador.data

import java.util.UUID
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * A question asked aside with /btw while a reply is being written: it is answered in a chat of its own, reading the
 * open chat up to the point where the long reply started, so the reply itself is not disturbed.
 */
data class Aside(
    val id: String = UUID.randomUUID().toString(),
    val question: String,
    /** The chat the aside was asked in. */
    val chat: String,
    val answer: String = "",
    /** Shows it is still being answered: a potato verb, "Searching the web…". */
    val status: String? = null,
    val isError: Boolean = false,
    /** The chat the answer is kept in, once it has one. */
    val answerChat: String? = null,
) {
    /** The answer as shown in the card, without what only matters while streaming. */
    val shown: String get() = answer.trim()
}

object AsideTools {
    /** Tool rounds for one aside: a question asked aside wants an answer quickly. */
    const val MAX_ROUNDS = 4

    private const val COMMAND = "/btw"

    /** The question in "/btw <text>"; "" for a bare /btw; null when the text isn't the command. */
    fun command(text: String): String? {
        val trimmed = text.trim()
        val lower = trimmed.lowercase()
        if (lower != COMMAND && !lower.startsWith("$COMMAND ") && !lower.startsWith("$COMMAND\n")) return null
        return trimmed.drop(COMMAND.length).trim()
    }

    private const val SYSTEM_PROMPT =
        "The user asks you something aside (/btw) while you are writing a longer answer in the chat; the question is " +
            "answered on its own, so it must not be about finishing that answer. Answer briefly and directly, in the " +
            "user's language, with a tool only when the question really needs one. What was said in the chat before is " +
            "below for context; the answer you are writing there is not part of it."

    /** How the model is asked, with what was said in the chat before: the aside shares the chat up to the question the long reply is answering, and never sees that reply, which is only half written. */
    fun prompt(question: String, context: List<JsonObject>): List<JsonObject> {
        fun message(role: String, text: String) = buildJsonObject { put("role", role); put("content", text) }
        return listOf(message("system", SYSTEM_PROMPT)) + context + listOf(message("user", question))
    }

    /** What the reply that keeps running is told, so the aside doesn't pull it off its task. */
    private const val RESUME =
        "While you were writing, the user asked something aside (in a separate window): \"{{question}}\". That is " +
            "answered separately and is not part of this answer. Don't answer it here; continue your answer where it " +
            "stopped and finish it."

    /** The note is needed the other way round too: the long reply must not answer the question asked aside, and must not drift off because a tap on the screen raced ahead of it. */
    fun resumeNote(question: String): String = RESUME.replace("{{question}}", question.take(500))
}
