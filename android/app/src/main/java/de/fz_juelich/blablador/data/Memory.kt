package de.fz_juelich.blablador.data

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File
import java.util.UUID

/** Something the assistant remembers about the user across chats. */
@Serializable
data class Memory(
    val id: String = UUID.randomUUID().toString(),
    val text: String,
    val date: Long = System.currentTimeMillis(),
    /** Embedding of the text (see Embeddings), base64, for finding the memories that matter to a question. */
    val vector: String? = null,
    /** The chat the memory was saved in. */
    val sourceChat: String? = null,
    val sourceTitle: String? = null,
    /**
     * People, projects, places, tools and other named things the fact is about, lowercased. Memories sharing one
     * are linked, so recall can follow a chain of facts. null until the helper model has named them.
     */
    val entities: List<String>? = null,
)

/** A fact from [MemoryStore.learn]: {"fact": …, "about": […]} (plain strings are accepted too). */
@Serializable
data class LearnedFact(val fact: String, val about: List<String>? = null)

/** Long-term memory: facts saved on the device with the remember tool and sent with every chat. */
class MemoryStore(private val context: Context) {
    companion object {
        /** Most memories kept; the oldest are dropped first. */
        const val MAX_MEMORIES = 500
        /** Up to this many memories are always sent; beyond it only the relevant ones. */
        const val ALWAYS_SENT = 30

        /** Lowercased words of three letters or more, for matching memories and chats to a question. */
        fun words(text: String): Set<String> =
            text.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.length >= 3 }.toSet()

        /**
         * The memory part of the system prompt. With many memories, only those sharing words with the
         * question plus the newest are sent, keeping their numbers so forget still works.
         */
        fun systemPrompt(memories: List<Memory>, question: String, questionVector: FloatArray? = null): String {
            var prompt = "You have a long-term memory of the user that lasts across chats. Call remember when the user shares something lasting about themselves (name, job, preferences, ongoing projects) or asks you to remember something; save one short fact per call, written in the third person. Call forget with a number when the user says a memory is wrong or asks you to forget it. Never save passwords, keys or other secrets."
            if (memories.isEmpty()) return "$prompt You don't remember anything yet."
            val numbered = memories.withIndex().toList()
            var shown = numbered
            if (numbered.size > ALWAYS_SENT) {
                val words = words(question)
                // Meaning (when embedded) plus a little for shared words; keywords alone otherwise. Unrelated texts
                // still score 0.3 to 0.5 with Qwen3 embeddings, so only those close to the best match count.
                val meanings = numbered.map { item ->
                    questionVector?.let { q -> item.value.vector?.let { Embeddings.similarity(Embeddings.decode(it), q) } }
                }
                val cutoff = maxOf(0.5f, (meanings.filterNotNull().maxOrNull() ?: 0f) - 0.2f)
                val relevant = numbered.map { item ->
                    val keywords = (words(item.value.text) intersect words).size.toFloat()
                    val meaning = meanings[item.index]
                    val score = if (meaning == null) keywords else if (meaning >= cutoff || keywords >= 2) meaning + 0.05f * keywords else 0f
                    item.index to score
                }.filter { it.second > 0 }.sortedByDescending { it.second }.take(20).map { it.first }
                val keep = relevant.toSet() + linked(relevant, memories, 10) + numbered.takeLast(10).map { it.index }
                shown = numbered.filter { it.index in keep }
            }
            prompt += " What you remember:\n" + shown.joinToString("\n") { "${it.index + 1}. ${it.value.text}" }
            if (shown.size < numbered.size) prompt += "\n(${numbered.size - shown.size} other memories aren't shown because they don't seem related to this message.)"
            return prompt
        }

        /**
         * Memories reached from [start] (indices) through shared entities, up to two steps away, nearest first.
         * "Maria leads the benchmark project" leads to "The benchmark project uses vLLM" and on to "Tom fixed vLLM".
         */
        fun linked(start: List<Int>, memories: List<Memory>, limit: Int): List<Int> {
            val byEntity = mutableMapOf<String, MutableList<Int>>()
            memories.forEachIndexed { index, memory -> memory.entities?.forEach { byEntity.getOrPut(it) { mutableListOf() } += index } }
            // Entities on most memories (usually the user) link everything to everything; leave them out.
            val common = maxOf(5, memories.size / 10)
            val seen = start.toMutableSet()
            var frontier = start
            val found = mutableListOf<Int>()
            repeat(2) {
                val next = mutableListOf<Int>()
                for (index in frontier) for (entity in memories[index].entities.orEmpty()) {
                    val others = byEntity[entity] ?: continue
                    if (others.size > common) continue
                    for (other in others.asReversed()) if (seen.add(other)) next += other
                }
                found += next
                frontier = next
            }
            return found.take(limit)
        }

        fun normalized(entities: List<String>): List<String> =
            entities.map { it.trim().lowercase() }.filter { it.isNotEmpty() && it !in setOf("user", "the user", "assistant") }.distinct()

        /** The outermost JSON array in a model's answer, or null. */
        fun jsonArray(answer: String): String? {
            val start = answer.indexOf('['); val end = answer.lastIndexOf(']')
            return if (start < 0 || end <= start) null else answer.substring(start, end + 1)
        }

        /** Facts from learn's answer: objects with "fact" and "about", or plain strings. */
        fun learnedFacts(answer: String): List<LearnedFact> {
            val array = jsonArray(answer) ?: return emptyList()
            val items = runCatching { BlabladorApi.json.parseToJsonElement(array) as kotlinx.serialization.json.JsonArray }.getOrNull() ?: return emptyList()
            return items.mapNotNull { item ->
                if (item is kotlinx.serialization.json.JsonPrimitive && item.isString) LearnedFact(item.content)
                else runCatching { BlabladorApi.json.decodeFromJsonElement(LearnedFact.serializer(), item) }.getOrNull()
            }
        }
    }

    private val prefs = context.getSharedPreferences("memory", Context.MODE_PRIVATE)
    private val file = File(context.filesDir, "memories.json")
    private val serializer = ListSerializer(Memory.serializer())

    val memories = mutableStateListOf<Memory>().apply {
        addAll(runCatching { BlabladorApi.json.decodeFromString(serializer, EncryptedStorage.read(context, file)!!) }.getOrDefault(emptyList()))
    }

    var enabled by mutableStateOf(prefs.getBoolean("memoryEnabled", true))
        private set

    fun turn(on: Boolean) { enabled = on; prefs.edit().putBoolean("memoryEnabled", on).apply() }

    /** After each reply, save what's worth keeping from the exchange without being asked. */
    var learnsAutomatically by mutableStateOf(prefs.getBoolean("memoryLearnsAutomatically", true))
        private set

    fun learnAutomatically(on: Boolean) { learnsAutomatically = on; prefs.edit().putBoolean("memoryLearnsAutomatically", on).apply() }

    /**
     * Asks the model which facts from one exchange are worth keeping and saves them; returns the new ones.
     * With [reply] null (the reply read web pages or documents) only what the user wrote is used, so text planted
     * there can't write itself into memory.
     */
    suspend fun learn(question: String, reply: String?, api: BlabladorApi, model: String, from: Conversation? = null): List<String> {
        val today = java.text.DateFormat.getDateInstance(java.text.DateFormat.FULL).format(java.util.Date())
        var system = "You keep the long-term memory of an assistant. From the exchange below, pick out what is worth remembering " +
            "in future conversations: facts the user stated about themselves, their work, projects, people, plans and " +
            "preferences, and decisions, results and conclusions about the topics discussed that they are likely to come " +
            "back to. Skip general knowledge, small talk, one-off requests and anything already remembered. Never include " +
            "passwords, keys or other secrets. Write each fact as one short sentence that makes sense on its own, naming " +
            "things explicitly and giving dates where they matter (today is $today). Reply with only a JSON array of " +
            "objects like {\"fact\": \"Maria leads the JUWELS benchmark project.\", \"about\": [\"Maria\", \"JUWELS benchmark " +
            "project\"]}, where \"about\" lists the people, projects, places, tools and other specific things the fact is " +
            "about, by their usual name and spelled the same way as in earlier facts; or [] if there is nothing worth keeping."
        val known = memories.takeLast(60).map { it.text }
        if (known.isNotEmpty()) system += "\n\nAlready remembered:\n" + known.joinToString("\n") { "- $it" }
        val names = memories.flatMap { it.entities.orEmpty() }.toSortedSet().take(150)
        if (names.isNotEmpty()) system += "\n\nNames used so far: " + names.joinToString(", ")
        var exchange = "User: " + question.take(8000)
        if (reply != null) exchange += "\n\nAssistant: " + reply.take(8000) else system += "\n\nOnly use what the user wrote."
        val answer = api.complete(BlabladorApi.helperModel(model), system, exchange)
        val added = learnedFacts(answer).take(5).filter { add(it.fact, from, it.about) }.map { it.fact.trim() }
        if (added.isNotEmpty()) {
            embedMissing(api)
            linkMissing(api)
        }
        return added
    }

    /** Names the entities of memories saved without them (remember tool, edits, before 3.2), 40 at a time. */
    suspend fun linkMissing(api: BlabladorApi) {
        val missing = memories.filter { it.entities == null }.take(40)
        if (missing.isEmpty()) return
        val system = "For each numbered fact, list the people, organisations, projects, places, products, tools and other specific " +
            "things it is about, by their usual name (not \"the user\"). Reply with only a JSON array with one array of " +
            "strings per fact, in order, e.g. [[\"Maria\", \"JUWELS\"], []]."
        val list = missing.withIndex().joinToString("\n") { "${it.index + 1}. ${it.value.text}" }
        val answer = runCatching { api.complete(BlabladorApi.helperModel(BlabladorApi.DEFAULT_MODEL), system, list) }.getOrNull() ?: return
        val lists = jsonArray(answer)?.let {
            runCatching { BlabladorApi.json.decodeFromString(ListSerializer(ListSerializer(String.serializer())), it) }.getOrNull()
        } ?: return
        if (lists.size != missing.size) return
        missing.zip(lists).forEach { (memory, entities) ->
            val index = memories.indexOfFirst { it.id == memory.id && it.text == memory.text }
            if (index >= 0) memories[index] = memories[index].copy(entities = normalized(entities))
        }
        persist()
    }

    /** Embeds memories saved without a vector (new, edited, or from before 3.1). */
    suspend fun embedMissing(api: BlabladorApi) {
        val missing = memories.filter { it.vector == null }
        if (!Embeddings.available || missing.isEmpty()) return
        val vectors = runCatching { Embeddings.embed(missing.map { it.text }, api) }.getOrNull() ?: return
        missing.zip(vectors).forEach { (memory, vector) ->
            val index = memories.indexOfFirst { it.id == memory.id && it.text == memory.text }
            if (index >= 0) memories[index] = memories[index].copy(vector = Embeddings.encode(vector))
        }
        persist()
    }

    /** Like [systemPrompt], but with many memories picks the relevant ones by meaning when embeddings are available. */
    suspend fun systemPrompt(question: String, api: BlabladorApi): String {
        if (memories.size <= ALWAYS_SENT || !Embeddings.available) return systemPrompt(question)
        embedMissing(api)
        linkMissing(api)
        val questionVector = runCatching { Embeddings.embed(listOf(question), api).firstOrNull() }.getOrNull()
        return systemPrompt(memories.toList(), question, questionVector)
    }

    /** Saves a fact; returns false for an empty text or one already remembered. */
    fun add(text: String, from: Conversation? = null, entities: List<String>? = null): Boolean {
        val fact = text.trim()
        if (fact.isEmpty() || memories.any { it.text.equals(fact, ignoreCase = true) }) return false
        memories += Memory(text = fact, sourceChat = from?.id, sourceTitle = from?.title, entities = entities?.let(::normalized))
        while (memories.size > MAX_MEMORIES) memories.removeAt(0)
        persist()
        return true
    }

    fun update(memory: Memory, text: String) {
        val index = memories.indexOfFirst { it.id == memory.id }
        if (index < 0) return
        memories[index] = memories[index].copy(text = text, vector = null, entities = null)
        persist()
    }

    fun delete(memory: Memory) { memories.removeAll { it.id == memory.id }; persist() }

    /** Deletes memory number [number] as listed in the system prompt (1-based). */
    fun forget(number: Int): Memory? {
        if (number - 1 !in memories.indices) return null
        return memories.removeAt(number - 1).also { persist() }
    }

    fun deleteAll() { memories.clear(); persist() }

    /**
     * Added to the system prompt when memory is on. With many memories, only those sharing words with the
     * question plus the newest are sent, keeping their numbers so forget still works.
     */
    fun systemPrompt(question: String): String = systemPrompt(memories.toList(), question)

    private fun persist() = EncryptedStorage.write(context, file, BlabladorApi.json.encodeToString(serializer, memories.toList()))
}

/** Keyword search over earlier chats, for the search_chats tool. */
object ChatSearch {
    private const val MAX_RESULTS = 6

    /** The best matching messages, with chat title, date and an excerpt around the first match. */
    fun search(query: String, conversations: List<Conversation>, excluding: String?): String {
        val words = MemoryStore.words(query)
        if (words.isEmpty()) return "No keywords to search for."
        data class Hit(val score: Int, val conversation: Conversation, val message: ChatMessage)
        val hits = conversations.filter { it.id != excluding }.flatMap { conversation ->
            conversation.messages.filter { !it.isError && it.content.isNotEmpty() }.mapNotNull { message ->
                val score = (MemoryStore.words(message.content) intersect words).size + (MemoryStore.words(conversation.title) intersect words).size
                if (score > 0) Hit(score, conversation, message) else null
            }
        }
        val best = hits.sortedWith(compareByDescending<Hit> { it.score }.thenByDescending { it.message.date }).take(MAX_RESULTS)
        if (best.isEmpty()) return "No earlier chats mention \"$query\"."
        val format = java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM)
        return best.joinToString("\n\n") { hit ->
            val who = if (hit.message.role == ChatRole.user) "User" else "Assistant"
            "[${hit.conversation.title}, ${format.format(java.util.Date(hit.message.date))}] $who: ${excerpt(hit.message.content, words)}"
        }
    }

    private fun excerpt(text: String, words: Set<String>): String {
        val lower = text.lowercase()
        val first = words.mapNotNull { lower.indexOf(it).takeIf { index -> index >= 0 } }.minOrNull() ?: 0
        val start = (first - 200).coerceAtLeast(0)
        val slice = text.drop(start).take(600)
        return (if (start > 0) "…" else "") + slice + (if (slice.length == 600) "…" else "")
    }
}
