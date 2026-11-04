package de.fz_juelich.blablador.data

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * How hard a model thinks before it answers. The app uses these names for every model; [candidates] turns them
 * into the request fields each kind of model understands.
 */
enum class ReasoningEffort {
    off, low, medium, high, max;

    val label: String get() = name.replaceFirstChar { it.uppercase() }

    private enum class Family { OpenAI, DeepSeek, Toggle }

    companion object {
        private val oSeries = Regex("(^|[^a-z0-9])o[134](-|$)")

        private fun family(model: String): Family? {
            val id = model.lowercase()
            if ("gpt-oss" in id || "gpt-5" in id || oSeries.containsMatchIn(id)) return Family.OpenAI
            if ("deepseek" in id && listOf("v3.1", "v3.2", "v4").any { it in id }) return Family.DeepSeek
            // Qwen3 and GLM switch thinking on or off; their instruct and coder versions don't think.
            if (listOf("qwen3", "glm-4.5", "glm-4.6", "glm-4.7", "glm-5").any { it in id } &&
                listOf("instruct", "coder", "thinking", "-vl").none { it in id }) return Family.Toggle
            return null
        }

        /** The levels a model takes, or none when its thinking can't be set. */
        fun levels(model: String): List<ReasoningEffort> = when (family(model)) {
            Family.OpenAI -> listOf(low, medium, high, max)
            Family.DeepSeek -> listOf(off, low, medium, high, max)
            Family.Toggle -> listOf(off, high)
            null -> emptyList()
        }

        /** Medium unless chosen otherwise: models left to themselves think long, which is slow for everyday questions. */
        fun defaultLevel(model: String): ReasoningEffort? = levels(model).let { if (medium in it) medium else it.lastOrNull() }

        /** The level for a model given the saved choice (by name), or its default. */
        fun level(model: String, saved: String?): ReasoningEffort? {
            val choice = entries.firstOrNull { it.name == saved }
            return if (choice != null && choice in levels(model)) choice else defaultLevel(model)
        }

        /**
         * Request fields to try, best first. Models name the levels differently: "max" may be "xhigh" or only "high",
         * and some switch thinking with chat template options. The last candidate sends nothing extra. The way that
         * was accepted last time ([worked], an index into all candidates) comes first.
         */
        fun candidates(model: String, level: ReasoningEffort, worked: Int? = null): List<JsonObject> {
            val all = allCandidates(model, level).toMutableList()
            if (worked != null && worked > 0 && worked < all.size) all.add(0, all.removeAt(worked))
            return all
        }

        /** Where a tried candidate sits among all candidates, to remember it. */
        fun position(model: String, level: ReasoningEffort, candidate: JsonObject): Int = allCandidates(model, level).indexOf(candidate)

        fun allCandidates(model: String, level: ReasoningEffort): List<JsonObject> {
            val result: List<JsonObject> = when (family(model)) {
                Family.OpenAI -> {
                    val names = if (level == max) listOf("max", "xhigh", "high") else if (level == off) listOf("minimal", "low") else listOf(level.name)
                    names.map { buildJsonObject { put("reasoning_effort", it) } }
                }
                Family.DeepSeek -> if (level == off) listOf(
                    buildJsonObject {
                        putJsonObject("chat_template_kwargs") { put("thinking", false) }
                        putJsonObject("thinking") { put("type", "disabled") }
                    },
                    buildJsonObject { putJsonObject("chat_template_kwargs") { put("thinking", false) } },
                ) else {
                    val names = if (level == max) listOf("max", "xhigh", "high") else listOf(level.name)
                    names.map { name ->
                        buildJsonObject {
                            put("reasoning_effort", name)
                            putJsonObject("chat_template_kwargs") { put("thinking", true); put("reasoning_effort", name) }
                        }
                    } + names.map { buildJsonObject { put("reasoning_effort", it) } }
                }
                Family.Toggle -> listOf(buildJsonObject { putJsonObject("chat_template_kwargs") { put("enable_thinking", level != off) } })
                null -> return listOf(JsonObject(emptyMap()))
            }
            return result + JsonObject(emptyMap())
        }
    }
}
