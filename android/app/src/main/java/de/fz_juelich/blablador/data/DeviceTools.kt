package de.fz_juelich.blablador.data

import android.Manifest
import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.provider.CalendarContract
import android.provider.ContactsContract
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.text.DateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.coroutines.resume

/**
 * Tools for the device's calendar, contacts and location (Settings: Calendar, reminders, contacts and location).
 * Android has no system reminders, so list_reminders and create_reminder aren't offered here. What they return
 * counts as outside content (invitations and contact notes are written by other people).
 */
object DeviceTools {
    val names = setOf("calendar_events", "create_event", "find_contacts", "current_location")

    val definitions: List<JsonObject> = listOf(
        Tools.function("calendar_events", "List events in the user's calendars between two dates.", buildJsonObject {
            put("from", Tools.stringProperty("Start, ISO 8601 date or date-time, e.g. 2026-11-02 or 2026-11-02T09:00."))
            put("to", Tools.stringProperty("End, ISO 8601; defaults to one day after from."))
            put("query", Tools.stringProperty("Only events whose title, place or notes contain this text."))
        }, listOf("from")),
        Tools.function("create_event", "Add an event to the user's default calendar. The user is asked first.", buildJsonObject {
            put("title", buildJsonObject { put("type", "string") })
            put("start", Tools.stringProperty("ISO 8601 date-time, or a date for an all-day event."))
            put("end", Tools.stringProperty("ISO 8601; defaults to one hour after start."))
            put("location", buildJsonObject { put("type", "string") })
            put("notes", buildJsonObject { put("type", "string") })
        }, listOf("title", "start")),
        Tools.function("find_contacts", "Look up people in the user's contacts by name, company or email.", buildJsonObject {
            put("query", buildJsonObject { put("type", "string") })
        }, listOf("query")),
        Tools.function("current_location", "The device's current place (town, address) and coordinates.", buildJsonObject {}, emptyList()),
    )

    const val SYSTEM_PROMPT = "You can use the user's calendar (calendar_events, create_event), contacts (find_contacts) and location (current_location). Use local times; creating events shows the user a confirmation first."

    /** Android permissions a tool needs. */
    fun permissions(name: String): List<String> = when (name) {
        "calendar_events" -> listOf(Manifest.permission.READ_CALENDAR)
        "create_event" -> listOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)
        "find_contacts" -> listOf(Manifest.permission.READ_CONTACTS)
        "current_location" -> listOf(Manifest.permission.ACCESS_COARSE_LOCATION)
        else -> emptyList()
    }

    fun granted(context: Context, name: String) = permissions(name).all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

    /** Title and detail for the approval card of a tool that changes or shares something. */
    fun approval(name: String, arguments: JsonObject?): Pair<String, String>? {
        val title = jsonString(arguments?.get("title")).orEmpty()
        return when (name) {
            "create_event" -> "Add “$title” to your calendar?" to listOfNotNull(
                listOfNotNull(jsonString(arguments?.get("start")), jsonString(arguments?.get("end"))).joinToString(" – "),
                jsonString(arguments?.get("location")), jsonString(arguments?.get("notes")),
            ).filter { it.isNotEmpty() }.joinToString("\n")
            "current_location" -> "Share your current location with the assistant?" to "Your town and approximate coordinates are sent to the model."
            else -> null
        }
    }

    suspend fun run(context: Context, name: String, arguments: JsonObject?): String = withContext(Dispatchers.IO) {
        if (!granted(context, name)) throw IllegalStateException("No access. The user can allow it in the system settings for Blablador.")
        when (name) {
            "calendar_events" -> events(context, arguments)
            "create_event" -> createEvent(context, arguments)
            "find_contacts" -> contacts(context, jsonString(arguments?.get("query")).orEmpty())
            "current_location" -> location(context)
            else -> "Unknown tool $name."
        }
    }

    private fun describe(time: Long, allDay: Boolean = false): String =
        if (allDay) DateFormat.getDateInstance(DateFormat.FULL).format(Date(time))
        else DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(time))

    private fun badDate(text: String?) = IllegalArgumentException("Couldn't read the date \"${text.orEmpty()}\"; use ISO 8601 like 2026-11-02T09:00.")

    private fun events(context: Context, arguments: JsonObject?): String {
        val fromText = jsonString(arguments?.get("from"))
        val from = ScheduledTask.parseDate(fromText) ?: throw badDate(fromText)
        val start = if (from.second) Calendar.getInstance().apply { timeInMillis = from.first; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0) }.timeInMillis else from.first
        val day = 24 * 3600_000L
        var end = ScheduledTask.parseDate(jsonString(arguments?.get("to")))?.let { if (it.second) it.first + day else it.first } ?: (start + day)
        if (end <= start) end = start + day
        end = minOf(end, start + 366 * day)
        val query = jsonString(arguments?.get("query"))?.lowercase().orEmpty()
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
            android.content.ContentUris.appendId(it, start); android.content.ContentUris.appendId(it, end)
        }.build()
        val columns = arrayOf(CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN, CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY, CalendarContract.Instances.EVENT_LOCATION, CalendarContract.Instances.DESCRIPTION,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME)
        val lines = mutableListOf<String>()
        context.contentResolver.query(uri, columns, null, null, CalendarContract.Instances.BEGIN + " ASC")?.use { cursor ->
            while (cursor.moveToNext() && lines.size < 100) {
                val title = cursor.getString(0) ?: "(no title)"
                val location = cursor.getString(4).orEmpty()
                val notes = cursor.getString(5).orEmpty()
                if (query.isNotEmpty() && listOf(title, location, notes).none { it.lowercase().contains(query) }) continue
                val allDay = cursor.getInt(3) == 1
                // All-day events are stored in UTC.
                val begin = if (allDay) cursor.getLong(1) - TimeZone.getDefault().getOffset(cursor.getLong(1)) else cursor.getLong(1)
                var line = "- $title: " + if (allDay) describe(begin, true) + " (all day)"
                else "${describe(begin)} – ${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(cursor.getLong(2)))}"
                if (location.isNotEmpty()) line += ", at $location"
                line += " [${cursor.getString(6).orEmpty()}]"
                if (notes.isNotEmpty()) line += "\n  Notes: ${notes.take(300)}"
                lines += line
            }
        }
        return if (lines.isEmpty()) "No events between ${describe(start)} and ${describe(end)}." else lines.joinToString("\n")
    }

    private fun createEvent(context: Context, arguments: JsonObject?): String {
        val startText = jsonString(arguments?.get("start"))
        val start = ScheduledTask.parseDate(startText) ?: throw badDate(startText)
        val calendar = context.contentResolver.query(CalendarContract.Calendars.CONTENT_URI,
            arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.CALENDAR_DISPLAY_NAME),
            "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ${CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR}", null,
            "${CalendarContract.Calendars.IS_PRIMARY} DESC")?.use { if (it.moveToFirst()) it.getLong(0) to it.getString(1).orEmpty() else null }
            ?: throw IllegalStateException("There is no calendar to add events to.")
        val title = jsonString(arguments?.get("title")) ?: "Event"
        val values = ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calendar.first)
            put(CalendarContract.Events.TITLE, title)
            jsonString(arguments?.get("location"))?.let { put(CalendarContract.Events.EVENT_LOCATION, it) }
            jsonString(arguments?.get("notes"))?.let { put(CalendarContract.Events.DESCRIPTION, it) }
            if (start.second) {
                val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
                    val local = Calendar.getInstance().apply { timeInMillis = start.first }
                    clear(); set(local.get(Calendar.YEAR), local.get(Calendar.MONTH), local.get(Calendar.DAY_OF_MONTH))
                }.timeInMillis
                put(CalendarContract.Events.ALL_DAY, 1)
                put(CalendarContract.Events.DTSTART, utc)
                put(CalendarContract.Events.DTEND, utc + 24 * 3600_000L)
                put(CalendarContract.Events.EVENT_TIMEZONE, "UTC")
            } else {
                put(CalendarContract.Events.DTSTART, start.first)
                put(CalendarContract.Events.DTEND, ScheduledTask.parseDate(jsonString(arguments?.get("end")))?.first ?: (start.first + 3600_000L))
                put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
            }
        }
        context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values) ?: throw IllegalStateException("The event couldn't be saved.")
        return "Added “$title” on ${describe(start.first, start.second)} to ${calendar.second}."
    }

    private fun contacts(context: Context, query: String): String {
        val resolver = context.contentResolver
        val ids = linkedMapOf<Long, String>()
        val filter = android.net.Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_FILTER_URI, android.net.Uri.encode(query))
        resolver.query(filter, arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.DISPLAY_NAME), null, null, null)?.use {
            while (it.moveToNext() && ids.size < 20) ids[it.getLong(0)] = it.getString(1).orEmpty()
        }
        // Company names and emails aren't covered by the name filter.
        if (ids.isEmpty()) resolver.query(ContactsContract.Data.CONTENT_URI,
            arrayOf(ContactsContract.Data.CONTACT_ID, ContactsContract.Data.DISPLAY_NAME),
            "(${ContactsContract.Data.MIMETYPE} = ? AND ${ContactsContract.CommonDataKinds.Organization.COMPANY} LIKE ?) OR " +
                "(${ContactsContract.Data.MIMETYPE} = ? AND ${ContactsContract.CommonDataKinds.Email.ADDRESS} LIKE ?)",
            arrayOf(ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE, "%$query%", ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE, "%$query%"),
            null)?.use { while (it.moveToNext() && ids.size < 20) ids[it.getLong(0)] = it.getString(1).orEmpty() }
        if (ids.isEmpty()) return "No contacts match \"$query\"."
        return ids.entries.joinToString("\n") { (id, name) ->
            val lines = mutableListOf("- $name")
            resolver.query(ContactsContract.Data.CONTENT_URI,
                arrayOf(ContactsContract.Data.MIMETYPE, ContactsContract.Data.DATA1, ContactsContract.Data.DATA4),
                "${ContactsContract.Data.CONTACT_ID} = ?", arrayOf(id.toString()), null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val value = cursor.getString(1).orEmpty()
                    if (value.isEmpty()) continue
                    when (cursor.getString(0)) {
                        ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE -> lines += "  Phone: $value"
                        ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE -> lines += "  Email: $value"
                        ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE ->
                            lines += "  " + listOfNotNull(cursor.getString(2)?.takeIf { it.isNotEmpty() }, value).joinToString(", ")
                        ContactsContract.CommonDataKinds.StructuredPostal.CONTENT_ITEM_TYPE -> lines += "  Address: ${value.replace("\n", ", ")}"
                        ContactsContract.CommonDataKinds.Event.CONTENT_ITEM_TYPE -> lines += "  Date: $value"
                    }
                }
            }
            lines.joinToString("\n")
        }
    }

    @SuppressLint("MissingPermission")
    private suspend fun location(context: Context): String {
        val manager = context.getSystemService(LocationManager::class.java) ?: throw IllegalStateException("Location isn't available.")
        val providers = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER).filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
        var location: Location? = providers.mapNotNull { manager.getLastKnownLocation(it) }.maxByOrNull { it.time }
        if ((location == null || System.currentTimeMillis() - location.time > 10 * 60_000) && providers.isNotEmpty() && Build.VERSION.SDK_INT >= 30) {
            location = withTimeoutOrNull(20_000) {
                suspendCancellableCoroutine { continuation ->
                    manager.getCurrentLocation(providers.first(), null, context.mainExecutor) { continuation.resume(it) }
                }
            } ?: location
        }
        location ?: throw IllegalStateException("The location isn't known right now. Location services may be off.")
        var text = "Coordinates: %.4f, %.4f (accuracy about %.0f m).".format(Locale.US, location.latitude, location.longitude, location.accuracy)
        @Suppress("DEPRECATION")
        val place = runCatching { Geocoder(context).getFromLocation(location.latitude, location.longitude, 1)?.firstOrNull() }.getOrNull()
        if (place != null) {
            val parts = listOfNotNull(place.thoroughfare, place.locality, place.adminArea, place.countryName).filter { it.isNotEmpty() }
            if (parts.isNotEmpty()) text = "Place: ${parts.joinToString(", ")}. $text"
        }
        return text
    }
}
