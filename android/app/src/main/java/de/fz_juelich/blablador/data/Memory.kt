package de.fz_juelich.blablador.data

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.util.UUID

/** Something the assistant remembers about the user across chats. */
@Serializable
data class Memory(
    val id: String = UUID.randomUUID().toString(),
    val text: String,
    val date: Long = System.currentTimeMillis(),
)

/** Long-term memory: facts saved on the device with the remember tool and sent with every chat. */
class MemoryStore(private val context: Context) {
    companion object {
        /** Most memories kept; the oldest are dropped first. */
        const val MAX_MEMORIES = 100
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

    /** Saves a fact; returns false for an empty text or one already remembered. */
    fun add(text: String): Boolean {
        val fact = text.trim()
        if (fact.isEmpty() || memories.any { it.text.equals(fact, ignoreCase = true) }) return false
        memories += Memory(text = fact)
        while (memories.size > MAX_MEMORIES) memories.removeAt(0)
        persist()
        return true
    }

    fun update(memory: Memory, text: String) {
        val index = memories.indexOfFirst { it.id == memory.id }
        if (index < 0) return
        memories[index] = memories[index].copy(text = text)
        persist()
    }

    fun delete(memory: Memory) { memories.removeAll { it.id == memory.id }; persist() }

    /** Deletes memory number [number] as listed in the system prompt (1-based). */
    fun forget(number: Int): Memory? {
        if (number - 1 !in memories.indices) return null
        return memories.removeAt(number - 1).also { persist() }
    }

    fun deleteAll() { memories.clear(); persist() }

    /** Added to the system prompt when memory is on. */
    val systemPrompt: String
        get() {
            var prompt = "You have a long-term memory of the user that lasts across chats. Call remember when the user shares something lasting about themselves (name, job, preferences, ongoing projects) or asks you to remember something; save one short fact per call, written in the third person. Call forget with a number when the user says a memory is wrong or asks you to forget it. Never save passwords, keys or other secrets."
            prompt += if (memories.isEmpty()) " You don't remember anything yet."
            else " What you remember:\n" + memories.mapIndexed { index, memory -> "${index + 1}. ${memory.text}" }.joinToString("\n")
            return prompt
        }

    private fun persist() = EncryptedStorage.write(context, file, BlabladorApi.json.encodeToString(serializer, memories.toList()))
}
