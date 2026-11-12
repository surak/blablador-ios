package de.fz_juelich.blablador.data

import android.content.Context

/** What changed in a version, shown once after an update. */
data class WhatsNewItem(val icon: String, val title: String, val text: String, val tryIt: TryIt? = null) {
    sealed interface TryIt {
        /** A new chat with this text in the composer and the mention chip (not sent). */
        data class Prompt(val text: String, val mention: String?) : TryIt
        data object Panel : TryIt
        data object Permissions : TryIt
        data object Tasks : TryIt
    }
}

object WhatsNew {
    val releases: List<Pair<String, List<WhatsNewItem>>> = listOf(
        "3.8" to listOf(
            WhatsNewItem("cube", "A place in 3D",
                "Take photos all around a room and get a top-down map after every batch, then a 3D model you can turn with a finger. In the + panel: 3D room."),
            WhatsNewItem("terminal", "bla, an agent in the terminal",
                "On a computer, bla reads and edits files and runs commands for you, asking first. For Mac, Linux, Windows and Raspberry Pi, with the release."),
        ),
        "3.6" to listOf(
            WhatsNewItem("brain", "Choose how hard it thinks",
                "Pick Off, Low, Medium, High or Max for models that think, in the model menu or Settings. Medium is the new default, for quicker answers."),
            WhatsNewItem("queue", "Write while it answers",
                "Send another message while a reply is still coming: it waits above the composer. Steer sends it right away, or remove it."),
            WhatsNewItem("bolt", "Faster long answers",
                "Long replies stream smoothly and use less battery. Thinking shows just its latest line; tap it to read all of it."),
            WhatsNewItem("scroll", "Scroll while it writes",
                "Scroll up to read earlier messages while a reply is written; scroll back down or tap the arrow to follow it again.")
        ),
        "3.5" to listOf(
            WhatsNewItem("waveform", "Talk with Blablador",
                "Tap the waveform button and just talk. Blablador answers out loud in a Drama 3 voice, your cloned voice or the device's voice, and listens again."),
            WhatsNewItem("flag", "Goals",
                "Type /goal and what you want, and Blablador keeps working until it's done or needs you. It checks its results before showing them.",
                WhatsNewItem.TryIt.Prompt("/goal ", null)),
            WhatsNewItem("number", "# for knowledge",
                "Type # to answer from a knowledge base; @ is for tools, skills and connected services."),
            WhatsNewItem("zoom", "Zoom into plots",
                "Pinch or double-tap pictures and Python plots in answers to zoom in."),
        ),
        "3.4" to listOf(
            WhatsNewItem("doc", "Reads Google Docs",
                "Paste a link to a Google Doc, Sheet or Slides shared by link and ask about it. No Google account needed.",
                WhatsNewItem.TryIt.Prompt("Summarise this Google Doc: ", null)),
            WhatsNewItem("export", "Word, Excel and PowerPoint",
                "The doc button under an answer copies it into Google Docs or Word with its formatting, or saves and opens it as a document, a spreadsheet or slides."),
            WhatsNewItem("sparkles", "An example for everything",
                "A new chat shows what Blablador can do, from Python plots to cloned voices. Tap More ideas for others."),
            WhatsNewItem("text", "Cleaner answers",
                "Lists, headings and paragraphs are laid out for easier reading."),
        ),
        "3.3" to listOf(
            WhatsNewItem("checklist", "Plans and follows through",
                "For bigger tasks Blablador writes a plan, ticks off each step and keeps going until it's done. Afterwards it offers to save what it did as a skill.",
                WhatsNewItem.TryIt.Prompt("Plan a weekend trip to Jülich with a budget and a packing list", "plan")),
            WhatsNewItem("schedule", "Works while you're away",
                "Replies keep going when you switch chats, with a notification when they're ready. Schedule prompts to run by themselves.",
                WhatsNewItem.TryIt.Prompt("Every weekday at 8, summarise the top AI news for me", "schedule")),
            WhatsNewItem("calendar", "Your calendar and contacts",
                "Ask what's on tomorrow, add an event or look up a number. Nothing is added without your OK.",
                WhatsNewItem.TryIt.Prompt("What's on my calendar this week?", "device")),
            WhatsNewItem("hand", "You decide what it may do",
                "Allow, Ask or Never for each kind of tool. Every reply shows its tools, time and tokens.",
                WhatsNewItem.TryIt.Permissions),
            WhatsNewItem("at", "Everything one tap away",
                "The + button shows attachments, tools and knowledge at a glance. Type @ to use a tool or skill for one message.",
                WhatsNewItem.TryIt.Panel),
        ),
    )

    private const val SEEN_KEY = "whatsNewSeen"

    /** Compares dotted version numbers numerically ("3.10" is newer than "3.9"). */
    fun compare(a: String, b: String): Int {
        val x = a.split('.').map { it.toIntOrNull() ?: 0 }
        val y = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val c = (x.getOrElse(i) { 0 }).compareTo(y.getOrElse(i) { 0 })
            if (c != 0) return c
        }
        return 0
    }

    /** The newest release notes given what was seen; null when there's nothing new. Fresh installs see nothing. */
    fun unseen(seen: String?, hasChats: Boolean): Pair<String, List<WhatsNewItem>>? {
        val newest = releases.firstOrNull() ?: return null
        if (seen == null) return if (hasChats) newest else null
        return if (compare(seen, newest.first) < 0) newest else null
    }

    private fun prefs(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun unseen(context: Context, hasChats: Boolean): Pair<String, List<WhatsNewItem>>? {
        val seen = prefs(context).getString(SEEN_KEY, null)
        if (seen == null && !hasChats) markSeen(context)
        return unseen(seen, hasChats)
    }

    fun markSeen(context: Context) {
        releases.firstOrNull()?.let { prefs(context).edit().putString(SEEN_KEY, it.first).apply() }
    }
}
