package de.fz_juelich.blablador.data

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.compose.runtime.mutableStateListOf
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.text.DateFormat
import java.text.DateFormatSymbols
import java.util.Calendar
import java.util.UUID

/** A prompt that runs by itself at set times, e.g. "Every weekday at 8:00: summarise the news about HPC". */
@Serializable
data class ScheduledTask(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val prompt: String,
    val hour: Int = 8,
    val minute: Int = 0,
    /** Weekdays it runs on (1 = Sunday … 7 = Saturday, as in Calendar); empty runs once, on [date]. */
    val weekdays: Set<Int> = (1..7).toSet(),
    val date: Long? = null,
    val enabled: Boolean = true,
    val webSearch: Boolean = true,
    val lastRun: Long? = null,
    val lastChat: String? = null,
    /** Repeating tasks don't run for times before they were made. */
    val created: Long = System.currentTimeMillis(),
) {
    private fun timeOn(day: Calendar): Long = (day.clone() as Calendar).apply {
        set(Calendar.HOUR_OF_DAY, hour); set(Calendar.MINUTE, minute); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    /** The latest time at or before [now] it was due, or null if it hasn't been due since [after]. */
    fun due(now: Long = System.currentTimeMillis(), after: Long): Long? {
        if (!enabled) return null
        if (weekdays.isEmpty()) return date?.takeIf { it <= now && it > after }
        for (back in 0 until 8) {
            val day = Calendar.getInstance().apply { timeInMillis = now; add(Calendar.DAY_OF_YEAR, -back) }
            if (day.get(Calendar.DAY_OF_WEEK) !in weekdays) continue
            val time = timeOn(day)
            if (time <= now) return time.takeIf { it > after }
        }
        return null
    }

    /** The next time it runs. */
    fun next(now: Long = System.currentTimeMillis()): Long? {
        if (!enabled) return null
        if (weekdays.isEmpty()) return date?.takeIf { it > now }
        for (ahead in 0 until 8) {
            val day = Calendar.getInstance().apply { timeInMillis = now; add(Calendar.DAY_OF_YEAR, ahead) }
            if (day.get(Calendar.DAY_OF_WEEK) !in weekdays) continue
            val time = timeOn(day)
            if (time > now) return time
        }
        return null
    }

    val scheduleText: String
        get() {
            val time = "%02d:%02d".format(hour, minute)
            if (weekdays.isEmpty()) return date?.let { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(it) } ?: "Once"
            if (weekdays.size == 7) return "Every day at $time"
            if (weekdays == (2..6).toSet()) return "Weekdays at $time"
            if (weekdays == setOf(1, 7)) return "Weekends at $time"
            val symbols = DateFormatSymbols.getInstance().shortWeekdays
            return weekdays.sortedBy { (it + 5) % 7 }.joinToString(", ") { symbols[it] } + " at $time"
        }

    companion object {
        /** Parses ISO 8601 dates and date-times as local time; the flag tells an all-day date. */
        fun parseDate(text: String?): Pair<Long, Boolean>? {
            val value = text?.trim().orEmpty()
            if (value.isEmpty()) return null
            val formats = listOf("yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mmXXX", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm")
            for (format in formats) {
                val parser = java.text.SimpleDateFormat(format, java.util.Locale.US).apply { isLenient = false }
                val position = java.text.ParsePosition(0)
                val date = parser.parse(value, position)
                if (date != null && position.index == value.length) return date.time to false
            }
            val parser = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).apply { isLenient = false }
            val position = java.text.ParsePosition(0)
            val date = parser.parse(value, position)
            if (date != null && position.index == value.length) return date.time to true
            return null
        }

        val tool: JsonObject = Tools.function(
            "schedule_task",
            "Schedule a prompt to run by itself at a set time, once or on repeating weekdays, e.g. a daily news summary. Each run makes a new chat and a notification. The user confirms first.",
            buildJsonObject {
                put("title", Tools.stringProperty("Short name, e.g. \"Morning HPC news\"."))
                put("prompt", Tools.stringProperty("What to do at each run, written as a complete request."))
                put("time", Tools.stringProperty("Local time HH:MM."))
                put("days", buildJsonObject {
                    put("type", "array")
                    put("items", buildJsonObject {
                        put("type", "string")
                        put("enum", buildJsonArray { listOf("mon", "tue", "wed", "thu", "fri", "sat", "sun").forEach { add(JsonPrimitive(it)) } })
                    })
                    put("description", "Weekdays to repeat on; leave out for every day.")
                })
                put("date", Tools.stringProperty("For a single run: the date, YYYY-MM-DD; then days is ignored."))
            },
            listOf("title", "prompt", "time"),
        )

        fun fromArguments(arguments: JsonObject?): ScheduledTask? {
            val title = jsonString(arguments?.get("title")) ?: return null
            val prompt = jsonString(arguments?.get("prompt"))?.takeIf { it.isNotEmpty() } ?: return null
            val parts = jsonString(arguments?.get("time"))?.split(":")?.mapNotNull { it.trim().toIntOrNull() } ?: return null
            if (parts.size < 2 || parts[0] !in 0..23 || parts[1] !in 0..59) return null
            var task = ScheduledTask(title = title, prompt = prompt, hour = parts[0], minute = parts[1])
            val day = parseDate(jsonString(arguments?.get("date")))
            if (day != null) {
                val at = Calendar.getInstance().apply {
                    timeInMillis = day.first; set(Calendar.HOUR_OF_DAY, parts[0]); set(Calendar.MINUTE, parts[1]); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                }
                task = task.copy(weekdays = emptySet(), date = at.timeInMillis)
            } else {
                val numbers = mapOf("sun" to 1, "mon" to 2, "tue" to 3, "wed" to 4, "thu" to 5, "fri" to 6, "sat" to 7)
                val days = (arguments?.get("days") as? JsonArray).orEmpty().mapNotNull { numbers[jsonString(it)?.lowercase()?.take(3)] }.toSet()
                if (days.isNotEmpty()) task = task.copy(weekdays = days)
            }
            return task
        }
    }
}

/**
 * Keeps scheduled tasks (encrypted tasks.json). The app runs them when due while it is open, and on start for any
 * that were missed; an alarm at each time posts a notification that opens the app to run it.
 */
class TaskStore(private val context: Context) {
    private val file = File(context.filesDir, "tasks.json")
    private val serializer = ListSerializer(ScheduledTask.serializer())

    val tasks = mutableStateListOf<ScheduledTask>().apply {
        addAll(runCatching { BlabladorApi.json.decodeFromString(serializer, EncryptedStorage.read(context, file)!!) }.getOrDefault(emptyList()))
    }

    fun save(task: ScheduledTask) {
        val index = tasks.indexOfFirst { it.id == task.id }
        if (index >= 0) tasks[index] = task else tasks += task
        persist()
    }

    fun delete(id: String) { tasks.removeAll { it.id == id }; persist() }

    /** Tasks due now, oldest first. */
    fun due(now: Long = System.currentTimeMillis()): List<ScheduledTask> = tasks.filter { task ->
        task.due(now, task.lastRun ?: if (task.weekdays.isEmpty()) Long.MIN_VALUE else task.created) != null
    }

    fun persist() {
        EncryptedStorage.write(context, file, BlabladorApi.json.encodeToString(serializer, tasks.toList()))
        scheduleAlarm()
    }

    /** One inexact alarm for the next task time (no exact-alarm permission needed). */
    fun scheduleAlarm() {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val intent = PendingIntent.getBroadcast(context, 0, Intent(context, TaskAlarmReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val next = tasks.mapNotNull { it.next() }.minOrNull()
        if (next == null) alarms.cancel(intent) else alarms.setWindow(AlarmManager.RTC_WAKEUP, next, 60_000, intent)
    }
}

/** At a task's time: a notification that opens Blablador, which then runs the task. */
class TaskAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val store = TaskStore(context)
        val due = store.due()
        due.firstOrNull()?.let { Notifier.notify(context, it.title, "Scheduled task: open Blablador to run it.", null) }
        store.scheduleAlarm()
    }
}

/** Local notifications: finished replies and tasks, approvals waiting, task times; tapping opens the chat. */
object Notifier {
    private const val CHANNEL = "replies"

    fun allowed(context: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun notify(context: Context, title: String, body: String, chat: String?) {
        if (!allowed(context)) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Replies and tasks", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val open = Intent(Intent.ACTION_VIEW, Uri.parse(if (chat != null) "blablador://chat?id=$chat" else "blablador://tasks"))
            .setPackage(context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(context, (chat ?: title).hashCode(), open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body.take(200))
            .setStyle(NotificationCompat.BigTextStyle().bigText(body.take(500)))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(UUID.randomUUID().hashCode(), notification) }
    }
}
