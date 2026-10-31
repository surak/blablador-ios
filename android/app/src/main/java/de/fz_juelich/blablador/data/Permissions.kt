package de.fz_juelich.blablador.data

import android.content.Context
import androidx.compose.runtime.mutableStateMapOf
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/**
 * What the assistant may do without asking: one rule per kind of tool, set in Settings → Permissions or with
 * "Always allow" on an approval card. "Never" also hides the tools from the model.
 */
class ToolPermissions(context: Context?, private val mcp: () -> List<McpServer> = { emptyList() }, private val saveServer: (McpServer) -> Unit = {}) {
    enum class Rule(val label: String) { allow("Allow"), ask("Ask"), never("Never") }

    data class Kind(val id: String, val name: String, val detail: String, val defaultRule: Rule)

    companion object {
        val kinds = listOf(
            Kind("web", "Web search and pages", "Search the web, find pictures, read pages", Rule.allow),
            Kind("python", "Run Python", "Code runs in a sandbox on this device", Rule.allow),
            Kind("memory", "Change memory", "Remember and forget facts", Rule.allow),
            Kind("chats", "Search earlier chats", "Look up what was said before", Rule.allow),
            Kind("calendar", "Read calendar", "Events on this device", Rule.allow),
            Kind("calendarWrite", "Add events", "Create new calendar events", Rule.ask),
            Kind("contacts", "Look up contacts", "Names, phone numbers, emails", Rule.allow),
            Kind("location", "Current location", "Where this device is, roughly", Rule.ask),
            Kind("schedule", "Schedule tasks", "Create tasks that run at set times", Rule.ask),
        )

        /** The kind a tool belongs to. */
        fun kind(tool: String): String? = when (tool) {
            "web_search", "image_search", "read_page" -> "web"
            "run_python" -> "python"
            "remember", "forget" -> "memory"
            "search_chats" -> "chats"
            "calendar_events", "list_reminders" -> "calendar"
            "create_event", "create_reminder" -> "calendarWrite"
            "find_contacts" -> "contacts"
            "current_location" -> "location"
            "schedule_task" -> "schedule"
            "write_file", "edit_file" -> "files"
            "run_command" -> "command"
            else -> null
        }

        fun toolName(tool: JsonObject): String? = runCatching { jsonString(tool["function"]?.jsonObject?.get("name")) }.getOrNull()
    }

    private val prefs = context?.getSharedPreferences("permissions", Context.MODE_PRIVATE)
    private val rules = mutableStateMapOf<String, Rule>().apply {
        prefs?.all?.forEach { (key, value) -> runCatching { Rule.valueOf(value as String) }.getOrNull()?.let { put(key, it) } }
    }

    /** The rule for a kind of tool, or for a connected server ("mcp:<id>"), whose default comes from its setting. */
    fun rule(id: String): Rule {
        rules[id]?.let { return it }
        if (id.startsWith("mcp:")) mcp().firstOrNull { "mcp:${it.id}" == id }?.let { return if (it.askBeforeCalls) Rule.ask else Rule.allow }
        return kinds.firstOrNull { it.id == id }?.defaultRule ?: Rule.ask
    }

    fun set(id: String, rule: Rule) {
        // A server's Allow or Ask is its own "Ask before each tool call" switch; only Never is kept here.
        if (id.startsWith("mcp:") && rule != Rule.never) rules.remove(id) else rules[id] = rule
        prefs?.edit()?.apply { if (rules[id] == null) remove(id) else putString(id, rule.name) }?.apply()
        if (id.startsWith("mcp:") && rule != Rule.never) {
            mcp().firstOrNull { "mcp:${it.id}" == id }?.takeIf { it.askBeforeCalls != (rule != Rule.allow) }
                ?.let { saveServer(it.copy(askBeforeCalls = rule != Rule.allow)) }
        }
    }

    fun resetAll() {
        rules.clear()
        prefs?.edit()?.clear()?.apply()
    }

    /** Removes tools whose rule is Never. */
    fun filter(tools: List<JsonObject>): List<JsonObject> = tools.filter { tool ->
        val kind = toolName(tool)?.let(::kind) ?: return@filter true
        rule(kind) != Rule.never
    }
}
