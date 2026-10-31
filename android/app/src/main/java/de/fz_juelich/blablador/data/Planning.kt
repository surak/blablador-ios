package de.fz_juelich.blablador.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.util.UUID

/** State of a tool call. */
@Serializable
enum class StepState { running, done, failed, denied }

/** One step of the plan the model keeps with update_plan for longer tasks. */
@Serializable
data class PlanItem(
    val id: String = UUID.randomUUID().toString(),
    val text: String,
    val status: Status = Status.pending,
) {
    @Serializable
    enum class Status { pending, active, done }
}

/** A tool call as recorded for the trace under a reply: what ran, with which arguments, how long it took. */
@Serializable
data class TraceCall(
    val id: String = UUID.randomUUID().toString(),
    val tool: String,
    /** Arguments as JSON, so the call can be run again. */
    val arguments: String,
    /** The start of what the tool returned to the model. */
    val result: String = "",
    val seconds: Double = 0.0,
    val state: StepState = StepState.running,
)

/** How a reply came about: model, time, tokens and every tool call. */
@Serializable
data class Trace(
    val model: String,
    val seconds: Double = 0.0,
    val promptTokens: Int = 0,
    val completionTokens: Int = 0,
    val rounds: Int = 0,
    val calls: List<TraceCall> = emptyList(),
)

/** A mention in the composer (@web, @skill, @knowledge base…), sent with the message and kept on it. */
@Serializable
data class Mention(
    val kind: Kind,
    /** Tool kind ("web", "python", "device"…), skill name, knowledge base or server id. */
    val value: String,
    val name: String,
) {
    @Serializable
    enum class Kind { tool, skill, knowledge, server }

    val id get() = "${kind.name}:$value"
}

object PlanTools {
    val tool: JsonObject = buildJsonObject {
        put("type", "function")
        put("function", buildJsonObject {
            put("name", "update_plan")
            put("description", "Show the user your plan for a task that needs several steps, and update it as you go. Send the whole list every time, with each step's status.")
            put("parameters", buildJsonObject {
                put("type", "object")
                put("properties", buildJsonObject {
                    put("steps", buildJsonObject {
                        put("type", "array")
                        put("items", buildJsonObject {
                            put("type", "object")
                            put("properties", buildJsonObject {
                                put("step", buildJsonObject { put("type", "string"); put("description", "What this step does, in a few words.") })
                                put("status", buildJsonObject {
                                    put("type", "string")
                                    put("enum", buildJsonArray { listOf("pending", "in_progress", "done").forEach { add(JsonPrimitive(it)) } })
                                })
                            })
                            put("required", buildJsonArray { add(JsonPrimitive("step")); add(JsonPrimitive("status")) })
                        })
                    })
                })
                put("required", buildJsonArray { add(JsonPrimitive("steps")) })
            })
        })
    }

    const val SYSTEM_PROMPT = "For a task that takes three or more steps or tool calls, first call update_plan with the steps, then call it again whenever a step is done or the plan changes (mark the current step in_progress). Work through the plan without stopping to ask unless you need the user's decision. Don't make a plan for simple questions."

    fun items(arguments: JsonObject?): List<PlanItem> =
        (arguments?.get("steps") as? JsonArray).orEmpty().mapNotNull { element ->
            val step = element as? JsonObject ?: return@mapNotNull null
            val text = jsonString(step["step"])?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val status = when (jsonString(step["status"])) {
                "done", "completed" -> PlanItem.Status.done
                "in_progress", "active" -> PlanItem.Status.active
                else -> PlanItem.Status.pending
            }
            PlanItem(text = text, status = status)
        }

    fun summary(items: List<PlanItem>): String =
        "Plan updated (${items.count { it.status == PlanItem.Status.done }} of ${items.size} done). Continue with the next step."
}

/** After a task of several steps, drafts a skill from what was done so the user can save it with one tap. */
object SkillDrafter {
    /** Tool calls (not counting the plan, memory and skills) that make a task worth turning into a skill. */
    const val MINIMUM_CALLS = 3

    fun worthDrafting(trace: Trace?): Boolean {
        trace ?: return false
        val skip = setOf("update_plan", "remember", "forget", "use_skill", "suggest_skill")
        return trace.calls.count { it.tool !in skip && it.state == StepState.done } >= MINIMUM_CALLS
    }

    /** Only the user's request, the tool names and arguments and the final answer are used, not what tools returned. */
    suspend fun draft(request: String, trace: Trace, answer: String, existing: List<String>, api: BlabladorApi, model: String): Skill? {
        val calls = trace.calls.joinToString("\n") { "- ${it.tool} ${it.arguments.take(300)}" }
        var system = "You turn a task an assistant just completed into a reusable skill: instructions it can follow the next time " +
            "the user asks for something similar. Generalise from this one case (no specific names, dates or numbers " +
            "unless they always apply), list the steps and tools to use and what the result should look like. If the task " +
            "is a one-off that won't come back, reply with {}. Otherwise reply with only JSON: {\"name\": \"Short name\", " +
            "\"description\": \"When to use it, one sentence\", \"instructions\": \"Markdown steps\"}."
        if (existing.isNotEmpty()) system += "\n\nSkills that already exist (don't repeat them): " + existing.joinToString(", ")
        val user = "Request:\n${request.take(4_000)}\n\nTool calls:\n${calls.take(6_000)}\n\nFinal answer (start):\n${answer.take(2_000)}"
        val text = runCatching { api.complete(BlabladorApi.helperModel(model), system, user) }.getOrNull() ?: return null
        val reply = splitThinking(text).second
        val start = reply.indexOf('{'); val end = reply.lastIndexOf('}')
        if (start < 0 || end <= start) return null
        val obj = runCatching { BlabladorApi.json.parseToJsonElement(reply.substring(start, end + 1)).jsonObject }.getOrNull() ?: return null
        val name = jsonString(obj["name"])?.trim().orEmpty()
        val instructions = jsonString(obj["instructions"]).orEmpty()
        if (name.isEmpty() || instructions.isEmpty() || existing.any { it.equals(name, ignoreCase = true) }) return null
        return Skill(name = name, description = jsonString(obj["description"]).orEmpty(), instructions = instructions)
    }
}

/** Splits a `<think>…</think>` block some models put at the start of their answer from the answer itself. */
fun splitThinking(text: String): Pair<String, String> {
    val trimmed = text.trimStart()
    if (!trimmed.startsWith("<think>")) return "" to text
    val body = trimmed.removePrefix("<think>")
    val end = body.indexOf("</think>")
    return if (end < 0) body to "" else body.substring(0, end) to body.substring(end + "</think>".length).trim()
}

/** Everything that can be mentioned with @ in the composer, and what mentions add to the system prompt. */
object Mentions {
    /** Tool mentions with their Material icon names (see ui/ToolsPanel.kt). */
    val tools = listOf(
        Mention(Mention.Kind.tool, "web", "Web search"),
        Mention(Mention.Kind.tool, "python", "Python"),
        Mention(Mention.Kind.tool, "device", "Calendar & contacts"),
        Mention(Mention.Kind.tool, "chats", "Earlier chats"),
        Mention(Mention.Kind.tool, "memory", "Memory"),
        Mention(Mention.Kind.tool, "image", "Image"),
        Mention(Mention.Kind.tool, "schedule", "Schedule"),
        Mention(Mention.Kind.tool, "plan", "Plan"),
    )

    val toolHints = mapOf(
        "web" to "web search (web_search, read_page)",
        "python" to "Python (run_python)",
        "device" to "the user's calendar, reminders, contacts or location",
        "chats" to "earlier chats (search_chats)",
        "memory" to "long-term memory (remember what matters)",
        "image" to "image creation (generate_image, edit_image)",
        "schedule" to "a scheduled task (schedule_task)",
        "plan" to "a plan (update_plan), working through it step by step",
    )

    fun all(skills: List<Skill>, bases: List<Pair<String, String>>, servers: List<McpServer>): List<Mention> =
        tools + skills.map { Mention(Mention.Kind.skill, it.name, it.name) } +
            bases.map { Mention(Mention.Kind.knowledge, it.first, it.second) } +
            servers.filter { it.enabled }.map { Mention(Mention.Kind.server, it.id, it.name) }

    fun matches(query: String, all: List<Mention>): List<Mention> {
        val q = query.lowercase()
        if (q.isEmpty()) return all
        val starts = all.filter { it.name.lowercase().startsWith(q) }
        return starts + all.filter { !it.name.lowercase().startsWith(q) && it.name.lowercase().contains(q) }
    }

    fun kindName(kind: Mention.Kind) = when (kind) {
        Mention.Kind.tool -> "Tool"
        Mention.Kind.skill -> "Skill"
        Mention.Kind.knowledge -> "Knowledge"
        Mention.Kind.server -> "Connected"
    }

    fun prompt(mentions: List<Mention>, skill: (String) -> Skill? = { null }, server: (String) -> McpServer? = { null }): String? {
        val parts = mentions.mapNotNull { mention ->
            when (mention.kind) {
                Mention.Kind.tool -> toolHints[mention.value] ?: mention.name
                Mention.Kind.skill -> skill(mention.value)?.let { "the skill \"${it.name}\", whose instructions are:\n${it.instructions}\n" }
                Mention.Kind.knowledge -> "the knowledge base \"${mention.name}\" (relevant excerpts are below)"
                Mention.Kind.server -> server(mention.value)?.let { "the tools of ${it.name} (named ${it.slug}__…)" }
            }
        }
        return if (parts.isEmpty()) null else "For this message the user asked you to use " + parts.joinToString("; ") + "."
    }
}
