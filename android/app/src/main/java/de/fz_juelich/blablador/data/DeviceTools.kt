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
    val names = setOf("calendar_list", "calendar_events", "create_event", "update_event", "delete_event", "find_free_time",
        "find_contacts", "current_location")

    /** The tools that change something; the rest only read (and what they read counts as outside content). */
    val writes = setOf("create_event", "update_event", "delete_event")

    private fun type(t: String, description: String? = null) = buildJsonObject {
        put("type", t); if (description != null) put("description", description)
    }

    private fun arrayProp(itemType: String, description: String) = buildJsonObject {
        put("type", "array"); put("items", buildJsonObject { put("type", itemType) }); put("description", description)
    }

    private fun eventFields(extra: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {}) = buildJsonObject {
        put("title", type("string"))
        put("start", Tools.stringProperty("ISO 8601 date-time, or a date for an all-day event."))
        put("end", Tools.stringProperty("ISO 8601; defaults to one hour after start (all day: the same day)."))
        put("location", type("string"))
        put("notes", type("string"))
        put("url", type("string"))
        put("calendar", Tools.stringProperty("Calendar name or id from calendar_list; the default calendar when left out."))
        put("alerts", arrayProp("integer", "Alerts, in minutes before the start, e.g. [10, 60]."))
        put("repeat", Tools.stringProperty("Repetition.", listOf("none", "daily", "weekdays", "weekly", "biweekly", "monthly", "yearly")))
        put("repeat_until", Tools.stringProperty("ISO 8601 date the repetition ends."))
        put("repeat_count", type("integer", "How many times it happens in all."))
        extra()
    }

    val definitions: List<JsonObject> = listOf(
        Tools.function("calendar_list", "The user's calendars from every account on the device (Google, Microsoft/Exchange, CalDAV…), with id, account and whether events can be added.", buildJsonObject {}, emptyList()),
        Tools.function("calendar_events", "List events in the user's calendars between two dates, with the id update_event and delete_event need.", buildJsonObject {
            put("from", Tools.stringProperty("Start, ISO 8601 date or date-time, e.g. 2026-11-02 or 2026-11-02T09:00."))
            put("to", Tools.stringProperty("End, ISO 8601; defaults to one day after from."))
            put("query", Tools.stringProperty("Only events whose title, place, notes or attendees contain this text."))
            put("calendars", arrayProp("string", "Only these calendars (names or ids)."))
        }, listOf("from")),
        Tools.function("create_event", "Add an event to one of the user's calendars. Inviting people isn't possible from here; mention them in the notes.", eventFields(), listOf("title", "start")),
        Tools.function("update_event", "Change or move an event: give its id (and for a repeating event its occurrence) and only the fields that change.", eventFields {
            put("id", Tools.stringProperty("The event's id from calendar_events."))
            put("occurrence", Tools.stringProperty("For a repeating event, the start of the occurrence meant (as calendar_events shows it)."))
            put("span", Tools.stringProperty("A repeating event: only this occurrence (default) or this and all future ones.", listOf("this", "future")))
        }, listOf("id")),
        Tools.function("delete_event", "Delete an event (for a repeating one, this occurrence or this and the future ones).", buildJsonObject {
            put("id", type("string")); put("occurrence", type("string"))
            put("span", Tools.stringProperty("this or future", listOf("this", "future")))
        }, listOf("id")),
        Tools.function("find_free_time", "Free slots in the user's calendars, for scheduling.", buildJsonObject {
            put("from", Tools.stringProperty("ISO 8601 date or date-time."))
            put("to", Tools.stringProperty("ISO 8601; defaults to 7 days after from."))
            put("minutes", type("integer", "Length needed, default 30."))
            put("day_start", Tools.stringProperty("Working hours start, HH:mm, default 09:00."))
            put("day_end", Tools.stringProperty("Working hours end, HH:mm, default 17:00."))
            put("weekends", type("boolean", "Include Saturdays and Sundays, default false."))
            put("calendars", arrayProp("string", "Only these calendars."))
        }, listOf("from")),
        Tools.function("find_contacts", "Look up people in the user's contacts by name, company or email.", buildJsonObject {
            put("query", buildJsonObject { put("type", "string") })
        }, listOf("query")),
        Tools.function("current_location", "The device's current place (town, address) and coordinates.", buildJsonObject {}, emptyList()),
    )

    const val SYSTEM_PROMPT = "You can use the user's calendars from every account on the device (calendar_list, calendar_events, create_event, update_event to change or move, delete_event, find_free_time), contacts (find_contacts) and location (current_location). Use local times. Changes may need the user's confirmation; before changing or deleting, find the event with calendar_events and use its id."

    /** Android permissions a tool needs. */
    fun permissions(name: String): List<String> = when (name) {
        "calendar_list", "calendar_events", "find_free_time" -> listOf(Manifest.permission.READ_CALENDAR)
        "create_event", "update_event", "delete_event" -> listOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)
        "find_contacts" -> listOf(Manifest.permission.READ_CONTACTS)
        "current_location" -> listOf(Manifest.permission.ACCESS_COARSE_LOCATION)
        else -> emptyList()
    }

    fun granted(context: Context, name: String) = permissions(name).all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

    /** Title and detail for the approval card of a tool that changes or shares something. */
    fun approval(name: String, arguments: JsonObject?, context: Context? = null): Pair<String, String>? {
        val title = jsonString(arguments?.get("title")).orEmpty()
        return when (name) {
            "create_event" -> "Add “$title” to your calendar?" to listOfNotNull(
                listOfNotNull(jsonString(arguments?.get("start")), jsonString(arguments?.get("end"))).joinToString(" – "),
                jsonString(arguments?.get("location")), jsonString(arguments?.get("notes")),
            ).filter { it.isNotEmpty() }.joinToString("\n")
            "update_event", "delete_event" -> {
                val existing = context?.takeIf { granted(it, "calendar_events") }?.let { describeExisting(it, arguments) }
                val event = existing?.first?.let { "“$it”" } ?: "this event"
                val future = if (jsonString(arguments?.get("span")) == "future") " and the repeats after it" else ""
                if (name == "delete_event") "Delete $event$future from your calendar?" to existing?.second.orEmpty()
                else "Change $event$future?" to (listOfNotNull(existing?.second?.let { "Now: $it" }) +
                    listOf("title", "start", "end", "location", "notes", "url", "calendar", "alerts", "repeat", "repeat_until", "repeat_count")
                        .mapNotNull { key -> arguments?.get(key)?.let { "${key.replace('_', ' ')}: ${jsonString(it) ?: it.toString()}" } }).joinToString("\n")
            }
            "current_location" -> "Share your current location with the assistant?" to "Your town and approximate coordinates are sent to the model."
            else -> null
        }
    }

    suspend fun run(context: Context, name: String, arguments: JsonObject?): String = withContext(Dispatchers.IO) {
        if (!granted(context, name)) throw IllegalStateException("No access. The user can allow it in the system settings for Blablador.")
        when (name) {
            "calendar_list" -> Calendars.list(context)
            "calendar_events" -> Calendars.events(context, arguments)
            "create_event" -> Calendars.create(context, arguments)
            "update_event" -> Calendars.update(context, arguments)
            "delete_event" -> Calendars.delete(context, arguments)
            "find_free_time" -> Calendars.freeTime(context, arguments)
            "find_contacts" -> contacts(context, jsonString(arguments?.get("query")).orEmpty())
            "current_location" -> location(context)
            else -> "Unknown tool $name."
        }
    }

    private fun describeExisting(context: Context, arguments: JsonObject?): Pair<String, String>? = try {
        Calendars.find(context, jsonString(arguments?.get("id")), jsonString(arguments?.get("occurrence")))?.let { it.title to Calendars.describe(it.begin, it.allDay) }
    } catch (e: Exception) { null }

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
