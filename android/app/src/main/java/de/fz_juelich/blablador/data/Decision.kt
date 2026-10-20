package de.fz_juelich.blablador.data

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

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
}

/** A ready-made decision from decision-model-frontend; see scripts/generate-decision-examples.js. */
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
        fun load(context: Context): List<DecisionExample> = runCatching {
            val text = context.assets.open("decision-examples.json").use { it.readBytes().decodeToString() }
            BlabladorApi.json.decodeFromString(ListSerializer(serializer()), text)
        }.getOrDefault(emptyList())
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
