package de.fz_juelich.blablador.data

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.util.UUID

/** Instructions for one kind of task, written once and loaded by the model when the task comes up. */
@Serializable
data class Skill(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    /** When to use it; this line is what the model sees in every chat. */
    val description: String,
    val instructions: String,
    val date: Long = System.currentTimeMillis(),
) {
    /** The skill as Markdown with a front matter, for sharing and importing. */
    val markdown get() = "---\nname: $name\ndescription: $description\n---\n\n$instructions\n"

    companion object {
        /**
         * Reads a skill file: a front matter with name and description, then the instructions.
         * Without a front matter the file name is the name and the first line the description.
         */
        fun fromMarkdown(markdown: String, fileName: String): Skill? {
            var name = fileName.substringBeforeLast('.')
            var description = ""
            var body = markdown
            if (markdown.startsWith("---")) {
                val end = markdown.indexOf("\n---", 3)
                if (end > 0) {
                    markdown.substring(3, end).lines().forEach { line ->
                        val parts = line.split(":", limit = 2).map { it.trim() }
                        if (parts.size == 2 && parts[0] == "name") name = parts[1]
                        if (parts.size == 2 && parts[0] == "description") description = parts[1]
                    }
                    body = markdown.substring(end + 4)
                }
            }
            body = body.trim()
            if (description.isEmpty()) description = body.lineSequence().firstOrNull().orEmpty()
            if (name.isBlank() || body.isEmpty()) return null
            return Skill(name = name, description = description, instructions = body)
        }
    }
}

/** The user's skills, saved encrypted on the device. */
class SkillLibrary(private val context: Context) {
    private val file = File(context.filesDir, "skills.json")
    private val serializer = ListSerializer(Skill.serializer())

    val skills = mutableStateListOf<Skill>().apply {
        addAll(runCatching { BlabladorApi.json.decodeFromString(serializer, EncryptedStorage.read(context, file)!!) }.getOrDefault(emptyList()))
    }

    fun skill(named: String): Skill? = skills.firstOrNull { it.name.equals(named.trim(), ignoreCase = true) }

    /** Adds a skill, or replaces the one with the same id or name. */
    fun save(skill: Skill) {
        val index = skills.indexOfFirst { it.id == skill.id || it.name.equals(skill.name, ignoreCase = true) }
        if (index >= 0) skills[index] = skill.copy(id = skills[index].id) else skills += skill
        skills.sortBy { it.name.lowercase() }
        persist()
    }

    fun delete(skill: Skill) { skills.removeAll { it.id == skill.id }; persist() }

    /** Added to the system prompt when there are skills. */
    val systemPrompt: String?
        get() = if (skills.isEmpty()) null
        else "The user has saved skills: instructions for particular tasks. Before doing a task that matches one, call use_skill with its name and follow the instructions it returns.\n" +
            skills.joinToString("\n") { "- ${it.name}: ${it.description}" }

    private fun persist() = EncryptedStorage.write(context, file, BlabladorApi.json.encodeToString(serializer, skills.toList()))

    companion object {
        const val SYSTEM_PROMPT = "When the user asks you to remember how to do a task, or after a task they will likely repeat, you can call suggest_skill; the user then decides whether to save it."
    }
}
