package de.fz_juelich.blablador.data

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.UUID

/** A question for the Clef decision model: "noul" (yes/no), "choice" or "score". */
@Serializable
data class DecisionQuestion(
    val id: String,
    val type: String,
    val instructions: String,
    val options: List<Option>? = null,
    val levels: List<String>? = null,
) {
    @Serializable
    data class Option(val key: String, val text: String)

    val wire: JsonObject
        get() = buildJsonObject {
            put("type", type)
            put("instructions", instructions)
            options?.let { put("criteria", buildJsonObject { it.forEach { option -> put(option.key, option.text) } }) }
            levels?.let { put("criteria", buildJsonArray { it.forEach { level -> add(JsonPrimitive(level)) } }) }
        }

    /** Ready to send: an instruction, and at least two options or levels where needed. */
    val isComplete: Boolean
        get() = instructions.isNotBlank() && when (type) {
            "choice" -> options.orEmpty().count { it.text.isNotBlank() } >= 2
            "score" -> levels.orEmpty().count { it.isNotBlank() } >= 2
            else -> true
        }

    /** Drops empty options and levels and gives choice options short unique keys. */
    fun cleaned(): DecisionQuestion {
        val used = mutableSetOf<String>()
        return copy(
            instructions = instructions.trim(),
            options = options?.mapNotNull { option ->
                val text = option.text.trim()
                if (text.isEmpty()) return@mapNotNull null
                val base = option.key.ifEmpty { keyFor(text) }
                var key = base
                var n = 2
                while (key in used) key = "${base}_${n++}"
                used += key
                Option(key, text)
            },
            levels = levels?.map { it.trim() }?.filter { it.isNotEmpty() },
        )
    }

    companion object {
        fun new(type: String) = DecisionQuestion(
            id = "q" + UUID.randomUUID().toString().take(8),
            type = type,
            instructions = "",
            options = if (type == "choice") listOf(Option("", ""), Option("", "")) else null,
            levels = if (type == "score") listOf("Low", "Medium", "High") else null,
        )

        private fun keyFor(text: String): String {
            val words = text.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.take(4)
            return if (words.isEmpty()) "option" else words.joinToString("_")
        }
    }
}

/**
 * A situation and typed questions. The examples come from decision-model-frontend (see
 * scripts/generate-decision-examples.js); the user's own are kept by [SavedDecisions].
 */
@Serializable
data class DecisionExample(
    val name: String,
    val category: String,
    val description: String? = null,
    val state: String,
    val json: Boolean = false,
    val questions: List<DecisionQuestion>,
) {
    companion object {
        const val MY_CATEGORY = "My decisions"

        fun blank() = DecisionExample("New decision", MY_CATEGORY, null, "", false, listOf(DecisionQuestion.new("noul")))

        fun load(context: Context): List<DecisionExample> = runCatching {
            val text = context.assets.open("decision-examples.json").use { it.readBytes().decodeToString() }
            BlabladorApi.json.decodeFromString(ListSerializer(serializer()), text)
        }.getOrDefault(emptyList())
    }
}

/** The user's own decisions, kept in shared preferences. */
object SavedDecisions {
    private const val KEY = "decisions"

    fun load(context: Context): List<DecisionExample> = runCatching {
        val text = context.getSharedPreferences("decisions", Context.MODE_PRIVATE).getString(KEY, null) ?: return emptyList()
        BlabladorApi.json.decodeFromString(ListSerializer(DecisionExample.serializer()), text)
    }.getOrDefault(emptyList())

    fun save(context: Context, decisions: List<DecisionExample>) {
        context.getSharedPreferences("decisions", Context.MODE_PRIVATE).edit()
            .putString(KEY, BlabladorApi.json.encodeToString(ListSerializer(DecisionExample.serializer()), decisions)).apply()
    }
}

/** One answer from `/v1/systemone`. */
@Serializable
data class DecisionAnswer(
    val type: String = "",
    /** Probability of yes, for "noul". */
    val noul: Double? = null,
    val choice: String? = null,
    /** Probability-weighted level, for "score". */
    val score: Double? = null,
    val confidence: Double? = null,
    val probabilities: Map<String, Double>? = null,
)
