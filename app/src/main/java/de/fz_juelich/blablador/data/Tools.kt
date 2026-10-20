package de.fz_juelich.blablador.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request

/** Tools the chat model can call. */
object Tools {
    private fun function(name: String, description: String, properties: JsonObject, required: List<String>) = buildJsonObject {
        put("type", "function")
        put("function", buildJsonObject {
            put("name", name)
            put("description", description)
            put("parameters", buildJsonObject {
                put("type", "object")
                put("properties", properties)
                put("required", buildJsonArray { required.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } })
            })
        })
    }

    private fun stringProperty(description: String, options: List<String>? = null) = buildJsonObject {
        put("type", "string")
        put("description", description)
        if (options != null) put("enum", buildJsonArray { options.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } })
    }

    val webSearch = function(
        "web_search",
        "Search the web for current information, news, facts or anything you are unsure about. Returns titles, URLs and snippets.",
        buildJsonObject {
            put("query", stringProperty("The search query. Use specific keywords, not dates."))
            put("category", stringProperty(
                "Use news for current events and headlines, science for papers, it for programming. Defaults to general.",
                listOf("general", "news", "science", "it")))
            put("time_range", stringProperty("Only return results from this period, e.g. day for today's news.",
                listOf("day", "week", "month", "year")))
        },
        listOf("query"),
    )

    val generateImage = function(
        "generate_image",
        "Create a new image from a text description. Use when the user asks to draw, create, generate or imagine a picture.",
        buildJsonObject { put("prompt", stringProperty("Detailed description of the image, in English.")) },
        listOf("prompt"),
    )

    val editImage = function(
        "edit_image",
        "Edit the most recent image in the conversation (attached by the user or generated earlier). Use when the user asks to change, modify or restyle that image.",
        buildJsonObject { put("prompt", stringProperty("Instruction describing the change, in English.")) },
        listOf("prompt"),
    )

    val generateSpeech = function(
        "generate_speech",
        "Speak a script aloud with the user's chosen voice (Drama 3 text-to-speech). Use when the user asks you to say, read, narrate, perform or voice something. " + SpeechMarkup.GUIDE,
        buildJsonObject { put("script", stringProperty("The exact words to speak, in the user's language, with optional Drama 3 controls.")) },
        listOf("script"),
    )
}

object WebSearch {
    private const val BASE_URL = "https://search.blablador.fz-juelich.de/search"
    private const val MAX_RESULTS = 6

    suspend fun search(query: String, category: String?, timeRange: String?): List<SearchResult> = withContext(Dispatchers.IO) {
        val url = BASE_URL.toHttpUrl().newBuilder()
            .addQueryParameter("q", query)
            .addQueryParameter("format", "json")
            .apply {
                if (category in listOf("general", "news", "science", "it")) addQueryParameter("categories", category)
                if (timeRange in listOf("day", "week", "month", "year")) addQueryParameter("time_range", timeRange)
            }
            .build()
        BlabladorApi.client.newCall(Request.Builder().url(url).build()).await().use { response ->
            if (!response.isSuccessful) throw BlabladorException(response.code, "Web search failed.")
            val results = BlabladorApi.json.parseToJsonElement(response.body!!.string()).jsonObject["results"]?.jsonArray.orEmpty()
            results.take(MAX_RESULTS).map {
                val item = it.jsonObject
                SearchResult(
                    title = item["title"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    url = item["url"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    content = item["content"]?.jsonPrimitive?.contentOrNull,
                )
            }
        }
    }

    /** Formats results as the tool response handed back to the model. */
    fun toolOutput(query: String, results: List<Pair<Int, SearchResult>>): String =
        if (results.isEmpty()) "No results for \"$query\"."
        else results.joinToString("\n\n") { (number, result) -> "[$number] ${result.title}\nURL: ${result.url}\n${result.content.orEmpty()}" }
}
