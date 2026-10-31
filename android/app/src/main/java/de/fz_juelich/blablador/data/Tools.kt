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
    internal fun function(name: String, description: String, properties: JsonObject, required: List<String>) = buildJsonObject {
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

    internal fun stringProperty(description: String, options: List<String>? = null) = buildJsonObject {
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

    val readPage = function(
        "read_page",
        "Read the text of a web page or online PDF. Use it for links the user gives you and to read search results in full when the snippet is not enough.",
        buildJsonObject { put("url", stringProperty("The full http(s) address.")) },
        listOf("url"),
    )

    val imageSearch = function(
        "image_search",
        "Find pictures online of a person, place, animal, plant, building, artwork, product or anything easier to understand when seen. The pictures are shown to the user next to your answer.",
        buildJsonObject { put("query", stringProperty("What to find pictures of, e.g. a full name or place.")) },
        listOf("query"),
    )

    val remember = function(
        "remember",
        "Save a lasting fact about the user to long-term memory, available in future chats.",
        buildJsonObject { put("fact", stringProperty("One short fact in the third person, e.g. \"Works as a chemist in Jülich.\"")) },
        listOf("fact"),
    )

    val forget = function(
        "forget",
        "Delete a memory that is wrong or that the user wants forgotten.",
        buildJsonObject {
            put("number", buildJsonObject {
                put("type", "integer")
                put("description", "The memory's number in the list of what you remember.")
            })
        },
        listOf("number"),
    )

    val searchChats = function(
        "search_chats",
        "Search the user's earlier chats in this app, e.g. when they refer to something discussed before (\"what did we say about…\", \"like last time\").",
        buildJsonObject { put("query", stringProperty("Keywords to look for.")) },
        listOf("query"),
    )

    val useSkill = function(
        "use_skill",
        "Load the full instructions of one of the user's saved skills.",
        buildJsonObject { put("name", stringProperty("The skill's name as listed.")) },
        listOf("name"),
    )

    val suggestSkill = function(
        "suggest_skill",
        "Offer to save a reusable procedure as a skill, when the user asks for it or after finishing a task they will likely repeat the same way. The user decides whether to save it.",
        buildJsonObject {
            put("name", stringProperty("Short name, e.g. \"Meeting notes\"."))
            put("description", stringProperty("One line saying when to use it."))
            put("instructions", stringProperty("Step-by-step instructions in Markdown, written so they work without this chat."))
        },
        listOf("name", "description", "instructions"),
    )

    val runPython = function(
        "run_python",
        "Run Python code on the user's device (Pyodide: numpy, pandas, matplotlib, scipy, sympy, scikit-learn and more; other pure-Python packages via micropip). Use it for calculations, data analysis and plots. Print what you need to see; the value of the last line is returned too. Matplotlib figures are shown to the user automatically. Variables don't persist between calls.",
        buildJsonObject { put("code", stringProperty("The Python code to run.")) },
        listOf("code"),
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

    private const val MAX_IMAGES = 4

    const val SYSTEM_PROMPT = " You can use the web_search tool for current or uncertain information, and read_page to read a link the user gives you or a search result in full. Cite sources inline as [1], [2] matching the search results. When asked about a person, place or thing you don't know well, search the web first instead of saying you don't know. When the user asks about something that is easier to understand with a picture, such as a person, place, animal, building or artwork, also call image_search; the pictures are shown next to your answer, so don't include image links."

    /** Image search; only pictures served over HTTPS are kept. */
    suspend fun searchImages(query: String): List<WebImage> = withContext(Dispatchers.IO) {
        val url = BASE_URL.toHttpUrl().newBuilder()
            .addQueryParameter("q", query)
            .addQueryParameter("format", "json")
            .addQueryParameter("categories", "images")
            .build()
        BlabladorApi.client.newCall(Request.Builder().url(url).build()).await().use { response ->
            if (!response.isSuccessful) throw BlabladorException(response.code, "Image search failed.")
            val results = BlabladorApi.json.parseToJsonElement(response.body!!.string()).jsonObject["results"]?.jsonArray.orEmpty()
            fun JsonObject.https(key: String) = this[key]?.jsonPrimitive?.contentOrNull?.takeIf { it.startsWith("https://") }
            results.mapNotNull {
                val item = it.jsonObject
                val image = item.https("img_src") ?: return@mapNotNull null
                val page = item.https("url") ?: return@mapNotNull null
                WebImage(item["title"]?.jsonPrimitive?.contentOrNull.orEmpty(), page, image, item.https("thumbnail_src"))
            }.take(MAX_IMAGES)
        }
    }

    /** Formats results as the tool response handed back to the model. */
    fun toolOutput(query: String, results: List<Pair<Int, SearchResult>>): String =
        if (results.isEmpty()) "No results for \"$query\"."
        else results.joinToString("\n\n") { (number, result) -> "[$number] ${result.title}\nURL: ${result.url}\n${result.content.orEmpty()}" }
}
