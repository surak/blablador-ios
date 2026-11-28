package de.fz_juelich.blablador.data

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.provider.CalendarContract.Attendees
import android.provider.CalendarContract.Calendars as Cal
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Instances
import android.provider.CalendarContract.Reminders
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The calendar tools on CalendarContract: every account the phone syncs (Google, Exchange, CalDAV apps such as
 * DAVx⁵) is in the same store, as EventKit is on iOS and the Mac (`DeviceTools.swift`). Same tools, same answers.
 */
object Calendars {
    private const val DAY = 24 * 3600_000L

    data class Calendar_(val id: Long, val name: String, val account: String, val writable: Boolean, val primary: Boolean)

    /** One occurrence of an event, as Instances gives it (all-day times already in local time). */
    data class Occurrence(val id: Long, val title: String, val begin: Long, val end: Long, val allDay: Boolean, val calendarId: Long,
                          val repeats: Boolean, val location: String, val notes: String, val calendar: String)

    fun describe(time: Long, allDay: Boolean = false): String =
        if (allDay) DateFormat.getDateInstance(DateFormat.FULL).format(Date(time))
        else DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(time))

    private fun time(t: Long) = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(t))

    fun iso(t: Long, allDay: Boolean = false): String =
        SimpleDateFormat(if (allDay) "yyyy-MM-dd" else "yyyy-MM-dd'T'HH:mm", Locale.US).format(Date(t))

    private fun badDate(text: String?) = IllegalArgumentException("Couldn't read the date \"${text.orEmpty()}\"; use ISO 8601 like 2026-11-02T09:00.")

    private fun string(a: JsonObject?, key: String) = jsonString(a?.get(key))
    private fun strings(a: JsonObject?, key: String) = (a?.get(key) as? JsonArray)?.mapNotNull { jsonString(it) }
    private fun int(a: JsonObject?, key: String) = (a?.get(key) as? JsonPrimitive)?.intOrNull

    /** All-day events are stored at UTC midnight; this moves them to local midnight and back. */
    private fun utcToLocal(t: Long) = t - TimeZone.getDefault().getOffset(t)
    private fun localToUtc(t: Long): Long {
        val local = Calendar.getInstance().apply { timeInMillis = t }
        return Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            clear(); set(local.get(Calendar.YEAR), local.get(Calendar.MONTH), local.get(Calendar.DAY_OF_MONTH))
        }.timeInMillis
    }

    fun calendars(context: Context): List<Calendar_> {
        val out = mutableListOf<Calendar_>()
        context.contentResolver.query(Cal.CONTENT_URI,
            arrayOf(Cal._ID, Cal.CALENDAR_DISPLAY_NAME, Cal.ACCOUNT_NAME, Cal.CALENDAR_ACCESS_LEVEL, Cal.IS_PRIMARY, Cal.VISIBLE),
            null, null, "${Cal.ACCOUNT_NAME}, ${Cal.CALENDAR_DISPLAY_NAME}")?.use {
            while (it.moveToNext()) {
                out += Calendar_(it.getLong(0), it.getString(1).orEmpty(), it.getString(2).orEmpty(),
                    it.getInt(3) >= Cal.CAL_ACCESS_CONTRIBUTOR, it.getInt(4) == 1)
            }
        }
        return out
    }

    fun list(context: Context): String {
        val all = calendars(context)
        if (all.isEmpty()) return "No calendars on this phone. Accounts are added in the system settings (Passwords & accounts)."
        val default = all.firstOrNull { it.writable && it.primary } ?: all.firstOrNull { it.writable }
        return all.joinToString("\n") {
            "- ${it.name} (id ${it.id}), account ${it.account}" + (if (it.writable) "" else ", read only") + (if (it == default) ", default" else "")
        }
    }

    private fun pick(context: Context, names: List<String>?): List<Calendar_>? {
        if (names.isNullOrEmpty()) return null
        val wanted = names.map { it.lowercase() }.toSet()
        return calendars(context).filter { it.name.lowercase() in wanted || it.id.toString() in wanted }.ifEmpty { null }
    }

    private fun range(a: JsonObject?, days: Int): Pair<Long, Long> {
        val fromText = string(a, "from")
        val from = ScheduledTask.parseDate(fromText) ?: throw badDate(fromText)
        val start = if (from.second) Calendar.getInstance().apply { timeInMillis = from.first; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis else from.first
        var end = ScheduledTask.parseDate(string(a, "to"))?.let { if (it.second) it.first + DAY else it.first } ?: (start + days * DAY)
        if (end <= start) end = start + days * DAY
        return start to minOf(end, start + 366 * DAY)
    }

    fun occurrences(context: Context, start: Long, end: Long, calendarIds: Set<Long>? = null, busyOnly: Boolean = false): List<Occurrence> {
        val uri = Instances.CONTENT_URI.buildUpon().also { ContentUris.appendId(it, start); ContentUris.appendId(it, end) }.build()
        val columns = arrayOf(Instances.EVENT_ID, Instances.TITLE, Instances.BEGIN, Instances.END, Instances.ALL_DAY, Instances.CALENDAR_ID,
            Instances.RRULE, Instances.EVENT_LOCATION, Instances.DESCRIPTION, Instances.CALENDAR_DISPLAY_NAME, Instances.AVAILABILITY, Instances.STATUS)
        val out = mutableListOf<Occurrence>()
        context.contentResolver.query(uri, columns, null, null, Instances.BEGIN + " ASC")?.use { c ->
            while (c.moveToNext()) {
                if (calendarIds != null && c.getLong(5) !in calendarIds) continue
                if (busyOnly && (c.getInt(10) == Events.AVAILABILITY_FREE || c.getInt(11) == Events.STATUS_CANCELED)) continue
                val allDay = c.getInt(4) == 1
                val begin = if (allDay) utcToLocal(c.getLong(2)) else c.getLong(2)
                val stop = if (allDay) utcToLocal(c.getLong(3)) else c.getLong(3)
                out += Occurrence(c.getLong(0), c.getString(1) ?: "(no title)", begin, stop, allDay, c.getLong(5),
                    !c.getString(6).isNullOrEmpty(), c.getString(7).orEmpty(), c.getString(8).orEmpty(), c.getString(9).orEmpty())
            }
        }
        return out
    }

    private fun attendees(context: Context, eventId: Long): List<String> {
        val out = mutableListOf<String>()
        context.contentResolver.query(Attendees.CONTENT_URI, arrayOf(Attendees.ATTENDEE_NAME, Attendees.ATTENDEE_EMAIL, Attendees.ATTENDEE_STATUS),
            "${Attendees.EVENT_ID} = ?", arrayOf(eventId.toString()), null)?.use {
            while (it.moveToNext() && out.size < 15) {
                val name = it.getString(0)?.takeIf { n -> n.isNotEmpty() } ?: it.getString(1).orEmpty()
                out += name + when (it.getInt(2)) {
                    Attendees.ATTENDEE_STATUS_ACCEPTED -> " (yes)"; Attendees.ATTENDEE_STATUS_DECLINED -> " (no)"
                    Attendees.ATTENDEE_STATUS_TENTATIVE -> " (maybe)"; else -> ""
                }
            }
        }
        return out
    }

    fun events(context: Context, a: JsonObject?): String {
        val (start, end) = range(a, 1)
        val query = string(a, "query")?.lowercase().orEmpty()
        val writable = calendars(context).associate { it.id to it.writable }
        val ids = pick(context, strings(a, "calendars"))?.map { it.id }?.toSet()
        val lines = mutableListOf<String>()
        for (o in occurrences(context, start, end, ids)) {
            if (lines.size >= 100) break
            val people = attendees(context, o.id)
            if (query.isNotEmpty() && (listOf(o.title, o.location, o.notes) + people).none { it.lowercase().contains(query) }) continue
            var line = "- ${o.title}: " + if (o.allDay) describe(o.begin, true) + " (all day)" else "${describe(o.begin)} – ${time(o.end)}"
            if (o.location.isNotEmpty()) line += ", at ${o.location}"
            line += " [${o.calendar}]\n  id ${o.id}"
            if (o.repeats) line += ", repeats, occurrence ${iso(o.begin, o.allDay)}"
            if (writable[o.calendarId] == false) line += ", read only"
            if (people.isNotEmpty()) line += "\n  With: " + people.joinToString(", ")
            if (o.notes.isNotEmpty()) line += "\n  Notes: ${o.notes.take(300)}"
            lines += line
        }
        return if (lines.isEmpty()) "No events between ${describe(start)} and ${describe(end)}." else lines.joinToString("\n")
    }

    /** An event by id; for a repeating one, the occurrence starting at `occurrence`. */
    fun find(context: Context, id: String?, occurrence: String?): Occurrence? {
        val eventId = id?.toLongOrNull() ?: return null
        val around = ScheduledTask.parseDate(occurrence)
        val (from, to) = if (around != null) (around.first - DAY) to (around.first + 2 * DAY) else {
            // The event's own start, to look its first occurrence up.
            val dtstart = context.contentResolver.query(ContentUris.withAppendedId(Events.CONTENT_URI, eventId), arrayOf(Events.DTSTART), null, null, null)
                ?.use { if (it.moveToFirst()) it.getLong(0) else null } ?: return null
            (dtstart - DAY) to (dtstart + 2 * DAY)
        }
        val matches = occurrences(context, from, to).filter { it.id == eventId }
        if (around == null) return matches.firstOrNull()
        return matches.firstOrNull { if (around.second) iso(it.begin, true) == iso(around.first, true) else kotlin.math.abs(it.begin - around.first) < 60_000 }
            ?: matches.firstOrNull()
    }

    private fun rrule(a: JsonObject?): String?? {
        val kind = string(a, "repeat") ?: return null
        val base = when (kind) {
            "daily" -> "FREQ=DAILY"; "weekdays" -> "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"; "weekly" -> "FREQ=WEEKLY"
            "biweekly" -> "FREQ=WEEKLY;INTERVAL=2"; "monthly" -> "FREQ=MONTHLY"; "yearly" -> "FREQ=YEARLY"
            else -> return "" // "none": no repetition
        }
        int(a, "repeat_count")?.let { return "$base;COUNT=$it" }
        ScheduledTask.parseDate(string(a, "repeat_until"))?.let {
            return "$base;UNTIL=" + SimpleDateFormat("yyyyMMdd'T'235959'Z'", Locale.US).format(Date(it.first))
        }
        return base
    }

    private fun writableCalendar(context: Context, a: JsonObject?, creating: Boolean): Calendar_? {
        val name = string(a, "calendar")
        if (name != null) {
            val calendar = pick(context, listOf(name))?.firstOrNull() ?: throw IllegalStateException("There is no calendar called $name; calendar_list shows them.")
            if (!calendar.writable) throw IllegalStateException("${calendar.name} is read only.")
            return calendar
        }
        if (!creating) return null
        val all = calendars(context)
        return all.firstOrNull { it.writable && it.primary } ?: all.firstOrNull { it.writable } ?: throw IllegalStateException("There is no calendar to add events to.")
    }

    /** Event columns for what `a` mentions, starting from `base` (the occurrence being changed), with the times always set. */
    private fun values(context: Context, a: JsonObject?, base: Occurrence?, creating: Boolean): ContentValues {
        val v = ContentValues()
        writableCalendar(context, a, creating)?.let { v.put(Events.CALENDAR_ID, it.id) }
        string(a, "title")?.let { v.put(Events.TITLE, it) } ?: if (creating) v.put(Events.TITLE, "Event") else Unit
        string(a, "location")?.let { v.put(Events.EVENT_LOCATION, it) }
        val notes = string(a, "notes")
        val url = string(a, "url")
        if (notes != null || url != null) v.put(Events.DESCRIPTION, listOfNotNull(notes ?: base?.notes?.takeIf { it.isNotEmpty() }, url).joinToString("\n\n"))
        var allDay = base?.allDay ?: false
        var begin = base?.begin
        var end = base?.end
        string(a, "start")?.let { text ->
            val s = ScheduledTask.parseDate(text) ?: throw badDate(text)
            val length = if (base != null && !creating) base.end - base.begin else 3600_000L
            allDay = s.second; begin = s.first
            end = if (s.second) s.first + DAY else s.first + (if (base?.allDay == true) 3600_000L else length)
        }
        string(a, "end")?.let { text ->
            val e = ScheduledTask.parseDate(text) ?: throw badDate(text)
            end = if (e.second) e.first + DAY else e.first
        }
        val b = begin ?: throw badDate(string(a, "start"))
        val e = end ?: (b + 3600_000L)
        if (e < b) throw IllegalArgumentException("The end is before the start.")
        val rule = rrule(a)
        v.put(Events.ALL_DAY, if (allDay) 1 else 0)
        v.put(Events.EVENT_TIMEZONE, if (allDay) "UTC" else TimeZone.getDefault().id)
        v.put(Events.DTSTART, if (allDay) localToUtc(b) else b)
        val repeating = rule?.isNotEmpty() ?: (base?.repeats == true && !creating)
        if (rule != null) v.put(Events.RRULE, rule.ifEmpty { null })
        if (repeating) {
            // A repeating event has a duration instead of an end.
            v.put(Events.DURATION, if (allDay) "P${maxOf(1, ((e - b + DAY - 1) / DAY))}D" else "P${(e - b) / 1000}S")
            v.putNull(Events.DTEND)
        } else {
            v.put(Events.DTEND, if (allDay) localToUtc(b) + maxOf(DAY, e - b) else e)
            v.putNull(Events.DURATION)
        }
        return v
    }

    private fun setAlerts(context: Context, eventId: Long, a: JsonObject?) {
        val alerts = (a?.get("alerts") as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.intOrNull } ?: return
        context.contentResolver.delete(Reminders.CONTENT_URI, "${Reminders.EVENT_ID} = ?", arrayOf(eventId.toString()))
        for (m in alerts) {
            context.contentResolver.insert(Reminders.CONTENT_URI, ContentValues().apply {
                put(Reminders.EVENT_ID, eventId); put(Reminders.MINUTES, m); put(Reminders.METHOD, Reminders.METHOD_ALERT)
            })
        }
    }

    fun create(context: Context, a: JsonObject?): String {
        if (string(a, "start") == null) throw badDate("")
        val v = values(context, a, null, true)
        val uri = context.contentResolver.insert(Events.CONTENT_URI, v) ?: throw IllegalStateException("The event couldn't be saved.")
        val id = ContentUris.parseId(uri)
        setAlerts(context, id, a)
        val name = calendars(context).firstOrNull { it.id == v.getAsLong(Events.CALENDAR_ID) }?.name.orEmpty()
        val start = v.getAsLong(Events.DTSTART).let { if (v.getAsInteger(Events.ALL_DAY) == 1) utcToLocal(it) else it }
        return "Added “${v.getAsString(Events.TITLE)}” on ${describe(start, v.getAsInteger(Events.ALL_DAY) == 1)} to $name (id $id)."
    }

    private fun existing(context: Context, a: JsonObject?): Occurrence {
        val o = find(context, string(a, "id"), string(a, "occurrence"))
            ?: throw IllegalStateException("No event with the id ${string(a, "id")}; look it up again with calendar_events.")
        if (calendars(context).firstOrNull { it.id == o.calendarId }?.writable == false) throw IllegalStateException("${o.calendar} is read only.")
        return o
    }

    private fun future(a: JsonObject?) = string(a, "span") == "future"

    /** Ends a repeating event's series just before `o`. */
    private fun endSeriesBefore(context: Context, o: Occurrence) {
        val rule = context.contentResolver.query(ContentUris.withAppendedId(Events.CONTENT_URI, o.id), arrayOf(Events.RRULE), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }.orEmpty()
        val until = SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date((if (o.allDay) localToUtc(o.begin) else o.begin) - 1000))
        val kept = rule.split(';').filter { !it.startsWith("UNTIL=") && !it.startsWith("COUNT=") && it.isNotEmpty() }
        context.contentResolver.update(ContentUris.withAppendedId(Events.CONTENT_URI, o.id),
            ContentValues().apply { put(Events.RRULE, (kept + "UNTIL=$until").joinToString(";")) }, null, null)
    }

    private fun originalTime(o: Occurrence) = if (o.allDay) localToUtc(o.begin) else o.begin

    fun update(context: Context, a: JsonObject?): String {
        val o = existing(context, a)
        val v = values(context, a, o, false)
        val id: Long
        when {
            !o.repeats -> {
                context.contentResolver.update(ContentUris.withAppendedId(Events.CONTENT_URI, o.id), v, null, null); id = o.id
            }
            future(a) -> {
                // A new series from this occurrence on, carrying what wasn't changed; the old one ends before it.
                val old = context.contentResolver.query(ContentUris.withAppendedId(Events.CONTENT_URI, o.id),
                    arrayOf(Events.TITLE, Events.EVENT_LOCATION, Events.DESCRIPTION, Events.CALENDAR_ID, Events.RRULE), null, null, null)
                    ?.use { if (it.moveToFirst()) listOf(it.getString(0), it.getString(1), it.getString(2), it.getLong(3).toString(), it.getString(4)) else null }
                    ?: throw IllegalStateException("The event is gone.")
                if (!v.containsKey(Events.TITLE)) v.put(Events.TITLE, old[0])
                if (!v.containsKey(Events.EVENT_LOCATION)) v.put(Events.EVENT_LOCATION, old[1])
                if (!v.containsKey(Events.DESCRIPTION)) v.put(Events.DESCRIPTION, old[2])
                if (!v.containsKey(Events.CALENDAR_ID)) v.put(Events.CALENDAR_ID, old[3]!!.toLong())
                if (!v.containsKey(Events.RRULE)) v.put(Events.RRULE, old[4])
                endSeriesBefore(context, o)
                id = ContentUris.parseId(context.contentResolver.insert(Events.CONTENT_URI, v) ?: throw IllegalStateException("The event couldn't be saved."))
            }
            else -> {
                // One occurrence: an exception to the series.
                v.remove(Events.RRULE); v.remove(Events.DURATION); v.remove(Events.CALENDAR_ID)
                if (!v.containsKey(Events.DTEND) || v.get(Events.DTEND) == null) {
                    v.put(Events.DTEND, v.getAsLong(Events.DTSTART) + (o.end - o.begin))
                }
                v.put(Events.ORIGINAL_INSTANCE_TIME, originalTime(o))
                val uri = context.contentResolver.insert(ContentUris.withAppendedId(Events.CONTENT_EXCEPTION_URI, o.id), v)
                    ?: throw IllegalStateException("The occurrence couldn't be changed.")
                id = ContentUris.parseId(uri)
            }
        }
        setAlerts(context, id, a)
        val changed = find(context, id.toString(), string(a, "start") ?: iso(o.begin, o.allDay)) ?: o
        return "Changed “${changed.title}”: now ${describe(changed.begin, changed.allDay)}" + (if (changed.allDay) "" else " – ${time(changed.end)}") + ", in ${changed.calendar}."
    }

    fun delete(context: Context, a: JsonObject?): String {
        val o = existing(context, a)
        when {
            !o.repeats -> context.contentResolver.delete(ContentUris.withAppendedId(Events.CONTENT_URI, o.id), null, null)
            future(a) -> endSeriesBefore(context, o)
            else -> context.contentResolver.insert(ContentUris.withAppendedId(Events.CONTENT_EXCEPTION_URI, o.id), ContentValues().apply {
                put(Events.ORIGINAL_INSTANCE_TIME, originalTime(o)); put(Events.STATUS, Events.STATUS_CANCELED)
            }) ?: throw IllegalStateException("The occurrence couldn't be deleted.")
        }
        return "Deleted “${o.title}” (${describe(o.begin, o.allDay)})" + (if (o.repeats && future(a)) " and its later repeats" else "") + "."
    }

    private fun minutes(text: String?, fallback: Int): Int {
        val parts = text?.split(":")?.mapNotNull { it.trim().toIntOrNull() } ?: return fallback
        return if (parts.size == 2) parts[0] * 60 + parts[1] else fallback
    }

    fun freeTime(context: Context, a: JsonObject?): String {
        val (start, end) = range(a, 7)
        val needed = maxOf(int(a, "minutes") ?: 30, 5) * 60_000L
        val dayStart = minutes(string(a, "day_start"), 9 * 60)
        val dayEnd = minutes(string(a, "day_end"), 17 * 60)
        val weekends = (a?.get("weekends") as? JsonPrimitive)?.booleanOrNull ?: false
        val ids = pick(context, strings(a, "calendars"))?.map { it.id }?.toSet()
        val busy = occurrences(context, start, end, ids, busyOnly = true).filter { !it.allDay }.map { it.begin to it.end }.sortedBy { it.first }
        return slots(start, end, busy, needed, dayStart, dayEnd, weekends).let {
            if (it.isEmpty()) "No free slot of ${needed / 60_000} minutes between ${describe(start)} and ${describe(end)}." else it.joinToString("\n")
        }
    }

    /** The free stretches of at least `needed` within working hours; pure, so the tests can check it. */
    fun slots(start: Long, end: Long, busy: List<Pair<Long, Long>>, needed: Long, dayStart: Int, dayEnd: Int, weekends: Boolean): List<String> {
        val out = mutableListOf<String>()
        val day = Calendar.getInstance().apply { timeInMillis = start; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
        val label = SimpleDateFormat("EEE d MMM", Locale.getDefault())
        while (day.timeInMillis < end && out.size < 40) {
            val weekday = day.get(Calendar.DAY_OF_WEEK)
            if (weekends || (weekday != Calendar.SATURDAY && weekday != Calendar.SUNDAY)) {
                val open = (day.clone() as Calendar).apply { set(Calendar.HOUR_OF_DAY, dayStart / 60); set(Calendar.MINUTE, dayStart % 60) }.timeInMillis
                val close = minOf((day.clone() as Calendar).apply { set(Calendar.HOUR_OF_DAY, dayEnd / 60); set(Calendar.MINUTE, dayEnd % 60) }.timeInMillis, end)
                var cursor = maxOf(open, start)
                for ((from, to) in busy) {
                    if (to <= cursor || from >= close) continue
                    if (from - cursor >= needed) out += "- ${label.format(Date(cursor))} ${time(cursor)} – ${time(from)} (${iso(cursor)})"
                    cursor = maxOf(cursor, to)
                }
                if (close - cursor >= needed) out += "- ${label.format(Date(cursor))} ${time(cursor)} – ${time(close)} (${iso(cursor)})"
            }
            day.add(Calendar.DAY_OF_MONTH, 1)
        }
        return out
    }
}
