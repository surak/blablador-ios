package de.fz_juelich.blablador.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

/** A goal set with /goal: Blablador keeps working on it until it's reached or it needs the user. */
@Serializable
data class Goal(
    val text: String,
    val status: Status = Status.active,
    /** What was done, or what the user needs to answer. */
    val summary: String? = null,
    val started: Long = System.currentTimeMillis(),
) {
    @Serializable
    enum class Status { active, done, blocked }
}

object GoalTools {
    /** Tool rounds for one reply that works on a goal. */
    const val MAX_ROUNDS = 60
    /** How often a reply that stops without settling the goal is told to keep going. */
    const val MAX_NUDGES = 3

    val tool: JsonObject = Tools.function(
        "goal_status",
        "Report the chat's goal as reached (done) or say you can't go on without the user (blocked).",
        buildJsonObject {
            put("status", Tools.stringProperty("done or blocked", listOf("done", "blocked")))
            put("summary", Tools.stringProperty("done: what was achieved, in one or two sentences. blocked: the question or decision the user has to answer."))
        },
        listOf("status", "summary"),
    )

    fun systemPrompt(goal: Goal) =
        "The user set a goal for this chat: \"${goal.text}\". Work towards it on your own, step by step, with update_plan and any tools you need, without stopping to ask unless you can't go on. " +
            "When the goal is fully reached, call goal_status with done; if you need the user's decision or information you can't find, call goal_status with blocked and your question."

    const val NUDGE = "The goal isn't reached yet. Keep working on it now, without asking. If it is reached, call goal_status with done; if you can't go on without the user, call goal_status with blocked."

    /** The goal in "/goal <text>"; "" for a bare /goal; null when the text isn't the command. */
    fun command(text: String): String? {
        val trimmed = text.trim()
        val lower = trimmed.lowercase()
        if (lower != "/goal" && !lower.startsWith("/goal ") && !lower.startsWith("/goal\n")) return null
        return trimmed.drop(5).trim()
    }

    val mention = Mention(Mention.Kind.tool, "goal", "Goal")
}

/** A second look before a task's answer goes to the user. */
object SelfCheck {
    @Serializable
    enum class Result { passed, corrected }

    val PROMPT = "Before this goes to the user, check your work against their request: is every part done, are numbers, names, dates and files right, did each tool really succeed, is anything claimed that a tool didn't confirm? " +
        "If the answer is complete and correct, reply with exactly CHECKED and nothing else. " +
        "Otherwise fix what's wrong (use tools if you need to) and then write the complete corrected answer, which replaces the previous one; don't mention this check."

    /** Replies worth checking: a plan, a goal or at least two real tool calls. */
    fun worthChecking(trace: Trace?, hasPlan: Boolean, goal: Boolean): Boolean {
        val calls = trace?.calls?.count { it.tool !in setOf("update_plan", "goal_status", "remember", "forget") } ?: 0
        return hasPlan || goal || calls >= 2
    }

    fun passed(answer: String): Boolean {
        val text = answer.trim { it.isWhitespace() || !it.isLetterOrDigit() }.uppercase()
        return text.isEmpty() || (text.startsWith("CHECKED") && text.length < 40)
    }
}
