package de.fz_juelich.blablador.data

import java.io.File
import java.net.URI
import java.net.URLDecoder

/** Something handed to the app from outside: shared text and files, a blablador:// link, or a shortcut. */
sealed interface Incoming {
    /** blablador://ask?q=… sends the question in a new chat. */
    data class Ask(val question: String) : Incoming
    /** blablador://new?text=…&url=… and shares: a new chat with this in the composer, never sent by itself. */
    data class Share(val text: String, val files: List<File> = emptyList(), val focus: Boolean = true) : Incoming
    /** The "Add to memory" shortcut. */
    data object AddMemory : Incoming
    /** blablador://chat?id=… from a notification. */
    data class OpenChat(val id: String) : Incoming
    /** blablador://tasks from a task's notification: run tasks that are due. */
    data object Tasks : Incoming

    companion object {
        /** Parses a blablador:// link; null for anything else. */
        fun parse(link: String): Incoming? {
            val uri = runCatching { URI(link) }.getOrNull() ?: return null
            if (uri.scheme != "blablador") return null
            val query = uri.rawQuery.orEmpty().split("&").filter { "=" in it }.associate {
                val (key, value) = it.split("=", limit = 2)
                key to URLDecoder.decode(value, "UTF-8")
            }
            return when (uri.host) {
                "ask" -> query["q"]?.takeIf { it.isNotBlank() }?.let(::Ask)
                "new" -> Share(listOfNotNull(query["text"], query["url"]).filter { it.isNotBlank() }.joinToString("\n"))
                "memory" -> AddMemory
                "chat" -> query["id"]?.takeIf { it.isNotBlank() }?.let(::OpenChat)
                "tasks" -> Tasks
                else -> null
            }
        }
    }
}
