import Contacts
import CoreLocation
import EventKit
import Foundation

/// Tools for the device's calendar, reminders, contacts and location (Settings: Calendar & contacts). The
/// system asks for access the first time; what they return counts as outside content (invitations and contact
/// notes are written by other people).
@MainActor
enum DeviceTools {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "deviceToolsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "deviceToolsEnabled") }
    }

    static let names: Set<String> = ["calendar_list", "calendar_events", "create_event", "update_event", "delete_event", "find_free_time",
                                     "list_reminders", "create_reminder", "find_contacts", "current_location"]

    /// The tools that change something; the rest only read (and what they read counts as outside content).
    static let writes: Set<String> = ["create_event", "update_event", "delete_event", "create_reminder"]

    private static let eventFields: [String: Any] = [
        "title": ["type": "string"],
        "start": ["type": "string", "description": "ISO 8601 date-time, or a date for an all-day event."],
        "end": ["type": "string", "description": "ISO 8601; defaults to one hour after start (all day: the same day)."],
        "location": ["type": "string"],
        "notes": ["type": "string"],
        "url": ["type": "string"],
        "calendar": ["type": "string", "description": "Calendar name or id from calendar_list; the default calendar when left out."],
        "alerts": ["type": "array", "items": ["type": "integer"], "description": "Alerts, in minutes before the start, e.g. [10, 60]."],
        "repeat": ["type": "string", "enum": ["none", "daily", "weekdays", "weekly", "biweekly", "monthly", "yearly"]],
        "repeat_until": ["type": "string", "description": "ISO 8601 date the repetition ends."],
        "repeat_count": ["type": "integer", "description": "How many times it happens in all."]
    ]

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                          "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    static let definitions: [[String: Any]] = [
        function("calendar_list", "The user's calendars from every account on the device (iCloud, Google, Microsoft/Exchange, CalDAV…), with id, account and whether events can be added.", [:]),
        function("calendar_events", "List events in the user's calendars between two dates, with the id update_event and delete_event need.", [
            "from": ["type": "string", "description": "Start, ISO 8601 date or date-time, e.g. 2026-11-02 or 2026-11-02T09:00."],
            "to": ["type": "string", "description": "End, ISO 8601; defaults to one day after from."],
            "query": ["type": "string", "description": "Only events whose title, place, notes or attendees contain this text."],
            "calendars": ["type": "array", "items": ["type": "string"], "description": "Only these calendars (names or ids)."]
        ], required: ["from"]),
        function("create_event", "Add an event to one of the user's calendars. Inviting people isn't possible from here; mention them in the notes.", eventFields, required: ["title", "start"]),
        function("update_event", "Change or move an event: give its id (and for a repeating event its occurrence) and only the fields that change.",
                 eventFields.merging([
                    "id": ["type": "string", "description": "The event's id from calendar_events."],
                    "occurrence": ["type": "string", "description": "For a repeating event, the start of the occurrence meant (as calendar_events shows it)."],
                    "span": ["type": "string", "enum": ["this", "future"], "description": "A repeating event: only this occurrence (default) or this and all future ones."]
                 ]) { $1 }, required: ["id"]),
        function("delete_event", "Delete an event (for a repeating one, this occurrence or this and the future ones).", [
            "id": ["type": "string"], "occurrence": ["type": "string"],
            "span": ["type": "string", "enum": ["this", "future"]]
        ], required: ["id"]),
        function("find_free_time", "Free slots in the user's calendars, for scheduling.", [
            "from": ["type": "string", "description": "ISO 8601 date or date-time."],
            "to": ["type": "string", "description": "ISO 8601; defaults to 7 days after from."],
            "minutes": ["type": "integer", "description": "Length needed, default 30."],
            "day_start": ["type": "string", "description": "Working hours start, HH:mm, default 09:00."],
            "day_end": ["type": "string", "description": "Working hours end, HH:mm, default 17:00."],
            "weekends": ["type": "boolean", "description": "Include Saturdays and Sundays, default false."],
            "calendars": ["type": "array", "items": ["type": "string"]]
        ], required: ["from"]),
        function("list_reminders", "List the user's open reminders, optionally with completed ones.", [
            "include_completed": ["type": "boolean"]
        ]),
        function("create_reminder", "Add a reminder to the user's default list. The user is asked first.", [
            "title": ["type": "string"],
            "due": ["type": "string", "description": "ISO 8601 date or date-time, optional."],
            "notes": ["type": "string"]
        ], required: ["title"]),
        function("find_contacts", "Look up people in the user's contacts by name, company or email.", [
            "query": ["type": "string"]
        ], required: ["query"]),
        function("current_location", "The device's current place (town, address) and coordinates.", [:])
    ]

    static let systemPrompt = "You can use the user's calendars from every account on the device (calendar_list, calendar_events, create_event, update_event to change or move, delete_event, find_free_time), reminders (list_reminders, create_reminder), contacts (find_contacts) and location (current_location). Use local times. Changes may need the user's confirmation; before changing or deleting, find the event with calendar_events and use its id."

    enum DeviceError: LocalizedError {
        case denied(String), badDate(String), unavailable(String)
        var errorDescription: String? {
            switch self {
            case let .denied(what): "No access to \(what). The user can allow it in the system settings for Blablador."
            case let .badDate(text): "Couldn't read the date \"\(text)\"; use ISO 8601 like 2026-11-02T09:00."
            case let .unavailable(text): text
            }
        }
    }

    private static let store = EKEventStore()

    /// Title and detail for the approval card of a tool that changes something.
    static func approval(_ name: String, _ arguments: [String: Any]) -> (title: String, detail: String)? {
        let title = arguments["title"] as? String ?? ""
        switch name {
        case "create_event":
            let when = [arguments["start"] as? String, arguments["end"] as? String].compactMap { $0 }.joined(separator: " – ")
            return ("Add “\(title)” to your calendar?", [when, arguments["location"] as? String ?? "", arguments["notes"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
        case "update_event", "delete_event":
            let existing = (arguments["id"] as? String).flatMap { find($0, occurrence: arguments["occurrence"] as? String) }
            let event = existing.map { "“\($0.title ?? "")”" } ?? "this event"
            let when = existing.map { describe($0.startDate, allDay: $0.isAllDay) } ?? ""
            let future = (arguments["span"] as? String) == "future" ? " and the repeats after it" : ""
            if name == "delete_event" {
                return ("Delete \(event)\(future) from your calendar?", when)
            }
            let changes = ["title", "start", "end", "location", "notes", "url", "calendar", "alerts", "repeat", "repeat_until", "repeat_count"]
                .compactMap { key in arguments[key].map { "\(key.replacingOccurrences(of: "_", with: " ")): \($0)" } }
            return ("Change \(event)\(future)?", ([when.isEmpty ? "" : "Now: \(when)"] + changes).filter { !$0.isEmpty }.joined(separator: "\n"))
        case "create_reminder":
            return ("Add the reminder “\(title)”?", [arguments["due"] as? String ?? "", arguments["notes"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
        case "current_location":
            return ("Share your current location with the assistant?", "Your town and approximate coordinates are sent to the model.")
        default:
            return nil
        }
    }

    static func run(_ name: String, _ arguments: [String: Any]) async throws -> String {
        switch name {
        case "calendar_list": return try await calendars()
        case "calendar_events": return try await events(arguments)
        case "create_event": return try await createEvent(arguments)
        case "update_event": return try await updateEvent(arguments)
        case "delete_event": return try await deleteEvent(arguments)
        case "find_free_time": return try await freeTime(arguments)
        case "list_reminders": return try await reminders(includeCompleted: arguments["include_completed"] as? Bool ?? false)
        case "create_reminder": return try await createReminder(arguments)
        case "find_contacts": return try await contacts(arguments["query"] as? String ?? "")
        case "current_location": return try await location()
        default: return "Unknown tool \(name)."
        }
    }

    // MARK: Dates

    static func date(_ text: String?) -> (date: Date, allDay: Bool)? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return (date, false) }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: text) { return (date, true) }
        return nil
    }

    private static func describe(_ date: Date, allDay: Bool = false) -> String {
        allDay ? date.formatted(date: .complete, time: .omitted) : date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Calendar and reminders

    private static func requestEvents() async throws {
        guard (try? await store.requestFullAccessToEvents()) == true else { throw DeviceError.denied("the calendar") }
    }

    private static func requestReminders() async throws {
        guard (try? await store.requestFullAccessToReminders()) == true else { throw DeviceError.denied("reminders") }
    }

    private static func iso(_ date: Date, allDay: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    private static func sourceName(_ calendar: EKCalendar) -> String {
        calendar.source?.title ?? ""
    }

    private static func calendars() async throws -> String {
        try await requestEvents()
        let all = store.calendars(for: .event).sorted { (sourceName($0), $0.title) < (sourceName($1), $1.title) }
        guard !all.isEmpty else { return "No calendars on this device. Accounts are added in the system settings (Internet Accounts / Calendar → Accounts)." }
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return all.map { calendar in
            var line = "- \(calendar.title) (id \(calendar.calendarIdentifier)), account \(sourceName(calendar))"
            line += calendar.allowsContentModifications ? "" : ", read only"
            if calendar.calendarIdentifier == defaultID { line += ", default" }
            return line
        }.joined(separator: "\n")
    }

    /// Calendars named by title or id; nil means all of them.
    private static func pick(_ names: [String]?) -> [EKCalendar]? {
        guard let names, !names.isEmpty else { return nil }
        let wanted = Set(names.map { $0.lowercased() })
        let found = store.calendars(for: .event).filter { wanted.contains($0.title.lowercased()) || wanted.contains($0.calendarIdentifier.lowercased()) }
        return found.isEmpty ? nil : found
    }

    private static func range(_ arguments: [String: Any], days: Int) throws -> (Date, Date) {
        let fromText = arguments["from"] as? String
        guard let from = date(fromText) else { throw DeviceError.badDate(fromText ?? "") }
        let start = from.allDay ? Calendar.current.startOfDay(for: from.date) : from.date
        var end = date(arguments["to"] as? String).map { $0.allDay ? Calendar.current.date(byAdding: .day, value: 1, to: $0.date)! : $0.date }
            ?? Calendar.current.date(byAdding: .day, value: days, to: start)!
        if end <= start { end = Calendar.current.date(byAdding: .day, value: days, to: start)! }
        return (start, min(end, Calendar.current.date(byAdding: .year, value: 1, to: start)!))
    }

    private static func events(_ arguments: [String: Any]) async throws -> String {
        let (start, end) = try range(arguments, days: 1)
        try await requestEvents()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: pick(arguments["calendars"] as? [String]))
        var events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if let query = (arguments["query"] as? String)?.lowercased(), !query.isEmpty {
            events = events.filter { event in
                ([event.title, event.location, event.notes] + (event.attendees ?? []).map { $0.name })
                    .compactMap { $0?.lowercased() }.contains { $0.contains(query) }
            }
        }
        guard !events.isEmpty else { return "No events between \(describe(start)) and \(describe(end))." }
        return events.prefix(100).map { event in
            var line = "- \(event.title ?? "(no title)"): "
            line += event.isAllDay ? describe(event.startDate, allDay: true) + " (all day)" : "\(describe(event.startDate)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
            if let location = event.location, !location.isEmpty { line += ", at \(location)" }
            line += " [\(event.calendar.title), \(sourceName(event.calendar))]"
            line += "\n  id \(event.calendarItemIdentifier)"
            if event.hasRecurrenceRules { line += ", repeats, occurrence \(iso(event.startDate, allDay: event.isAllDay))" }
            if !event.calendar.allowsContentModifications { line += ", read only" }
            if let attendees = event.attendees, !attendees.isEmpty {
                line += "\n  With: " + attendees.prefix(15).map { person in
                    let name = person.name ?? person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    switch person.participantStatus {
                    case .accepted: return name + " (yes)"
                    case .declined: return name + " (no)"
                    case .tentative: return name + " (maybe)"
                    default: return name
                    }
                }.joined(separator: ", ")
            }
            if let notes = event.notes, !notes.isEmpty { line += "\n  Notes: \(notes.prefix(300))" }
            return line
        }.joined(separator: "\n")
    }

    /// An event by id; for a repeating one, the occurrence starting at `occurrence`.
    static func find(_ id: String, occurrence: String?) -> EKEvent? {
        guard let event = store.calendarItem(withIdentifier: id) as? EKEvent ?? store.event(withIdentifier: id) else { return nil }
        guard event.hasRecurrenceRules, let at = date(occurrence) else { return event }
        let dayStart = Calendar.current.startOfDay(for: at.date)
        let matches = store.events(matching: store.predicateForEvents(withStart: dayStart, end: dayStart.addingTimeInterval(86_400 * 2), calendars: [event.calendar]))
            .filter { $0.calendarItemIdentifier == event.calendarItemIdentifier }
        return matches.first { at.allDay ? Calendar.current.isDate($0.startDate, inSameDayAs: at.date) : abs($0.startDate.timeIntervalSince(at.date)) < 60 } ?? event
    }

    private static func recurrence(_ arguments: [String: Any]) -> EKRecurrenceRule?? {
        guard let kind = arguments["repeat"] as? String else { return .none }
        let end: EKRecurrenceEnd? = (arguments["repeat_count"] as? Int).map { EKRecurrenceEnd(occurrenceCount: $0) }
            ?? date(arguments["repeat_until"] as? String).map { EKRecurrenceEnd(end: Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: $0.date) ?? $0.date) }
        switch kind {
        case "daily": return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: end)
        case "weekdays":
            let days = [EKWeekday.monday, .tuesday, .wednesday, .thursday, .friday].map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days, daysOfTheMonth: nil, monthsOfTheYear: nil,
                                    weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
        case "weekly": return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: end)
        case "biweekly": return EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: end)
        case "monthly": return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: end)
        case "yearly": return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: end)
        default: return .some(nil)
        }
    }

    /// Sets whatever `arguments` mentions; `creating` fills in the defaults a new event needs.
    private static func apply(_ arguments: [String: Any], to event: EKEvent, creating: Bool) throws {
        if let name = arguments["calendar"] as? String {
            guard let calendar = pick([name])?.first else { throw DeviceError.unavailable("There is no calendar called \(name); calendar_list shows them.") }
            guard calendar.allowsContentModifications else { throw DeviceError.unavailable("\(calendar.title) is read only.") }
            event.calendar = calendar
        } else if creating {
            guard let calendar = store.defaultCalendarForNewEvents else { throw DeviceError.unavailable("There is no calendar to add events to.") }
            event.calendar = calendar
        }
        if let title = arguments["title"] as? String { event.title = title }
        let length = event.endDate.map { $0.timeIntervalSince(event.startDate) } ?? 3600
        if let text = arguments["start"] as? String {
            guard let start = date(text) else { throw DeviceError.badDate(text) }
            event.isAllDay = start.allDay
            event.startDate = start.date
            if arguments["end"] == nil { event.endDate = start.date.addingTimeInterval(start.allDay ? 0 : (creating ? 3600 : max(length, 0))) }
        }
        if let text = arguments["end"] as? String {
            guard let end = date(text) else { throw DeviceError.badDate(text) }
            event.endDate = end.date
        }
        if event.endDate < event.startDate { throw DeviceError.unavailable("The end is before the start.") }
        if let location = arguments["location"] as? String { event.location = location }
        if let notes = arguments["notes"] as? String { event.notes = notes }
        if let url = arguments["url"] as? String { event.url = URL(string: url) }
        if let alerts = arguments["alerts"] as? [Int] {
            event.alarms = alerts.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
        }
        if case let .some(rule) = recurrence(arguments) {
            event.recurrenceRules = rule.map { [$0] }
        }
    }

    private static func createEvent(_ arguments: [String: Any]) async throws -> String {
        guard arguments["start"] is String else { throw DeviceError.badDate("") }
        try await requestEvents()
        let event = EKEvent(eventStore: store)
        if arguments["title"] == nil { event.title = "Event" }
        try apply(arguments, to: event, creating: true)
        try store.save(event, span: .thisEvent)
        return "Added “\(event.title ?? "")” on \(describe(event.startDate, allDay: event.isAllDay)) to \(event.calendar.title) (id \(event.calendarItemIdentifier))."
    }

    private static func span(_ arguments: [String: Any]) -> EKSpan {
        (arguments["span"] as? String) == "future" ? .futureEvents : .thisEvent
    }

    private static func existing(_ arguments: [String: Any]) async throws -> EKEvent {
        try await requestEvents()
        let id = arguments["id"] as? String ?? ""
        guard let event = find(id, occurrence: arguments["occurrence"] as? String) else {
            throw DeviceError.unavailable("No event with the id \(id); look it up again with calendar_events.")
        }
        guard event.calendar.allowsContentModifications else { throw DeviceError.unavailable("\(event.calendar.title) is read only.") }
        return event
    }

    private static func updateEvent(_ arguments: [String: Any]) async throws -> String {
        let event = try await existing(arguments)
        try apply(arguments, to: event, creating: false)
        try store.save(event, span: span(arguments))
        return "Changed “\(event.title ?? "")”: now \(describe(event.startDate, allDay: event.isAllDay))\(event.isAllDay ? "" : " – " + event.endDate.formatted(date: .omitted, time: .shortened)), in \(event.calendar.title)."
    }

    private static func deleteEvent(_ arguments: [String: Any]) async throws -> String {
        let event = try await existing(arguments)
        let title = event.title ?? ""
        let when = describe(event.startDate, allDay: event.isAllDay)
        try store.remove(event, span: span(arguments))
        return "Deleted “\(title)” (\(when))\(span(arguments) == .futureEvents ? " and its later repeats" : "")."
    }

    /// "09:30" as minutes after midnight.
    private static func minutes(_ text: Any?, _ fallback: Int) -> Int {
        guard let parts = (text as? String)?.split(separator: ":").compactMap({ Int($0) }), parts.count == 2 else { return fallback }
        return parts[0] * 60 + parts[1]
    }

    private static func freeTime(_ arguments: [String: Any]) async throws -> String {
        let (start, end) = try range(arguments, days: 7)
        try await requestEvents()
        let needed = TimeInterval(max(arguments["minutes"] as? Int ?? 30, 5) * 60)
        let dayStart = minutes(arguments["day_start"], 9 * 60), dayEnd = minutes(arguments["day_end"], 17 * 60)
        let weekends = arguments["weekends"] as? Bool ?? false
        let busy = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: pick(arguments["calendars"] as? [String])))
            .filter { !$0.isAllDay && $0.availability != .free && $0.status != .canceled }
            .map { ($0.startDate!, $0.endDate!) }.sorted { $0.0 < $1.0 }
        let calendar = Calendar.current
        var slots: [String] = []
        var day = calendar.startOfDay(for: start)
        while day < end, slots.count < 40 {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day)! }
            if !weekends, calendar.isDateInWeekend(day) { continue }
            var cursor = max(day.addingTimeInterval(TimeInterval(dayStart * 60)), start)
            let close = min(day.addingTimeInterval(TimeInterval(dayEnd * 60)), end)
            for (from, to) in busy where to > cursor && from < close {
                if from.timeIntervalSince(cursor) >= needed { slots.append(slot(cursor, from)) }
                cursor = max(cursor, to)
            }
            if close.timeIntervalSince(cursor) >= needed { slots.append(slot(cursor, close)) }
        }
        return slots.isEmpty ? "No free slot of \(Int(needed / 60)) minutes between \(describe(start)) and \(describe(end))." : slots.joined(separator: "\n")
    }

    private static func slot(_ from: Date, _ to: Date) -> String {
        "- \(from.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) \(from.formatted(date: .omitted, time: .shortened)) – \(to.formatted(date: .omitted, time: .shortened)) (\(iso(from)))"
    }

    private static func reminders(includeCompleted: Bool) async throws -> String {
        try await requestReminders()
        let predicate = includeCompleted ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        guard !reminders.isEmpty else { return "No reminders." }
        return reminders.prefix(100).map { reminder in
            var line = "- \(reminder.isCompleted ? "[done] " : "")\(reminder.title ?? "(no title)")"
            if let due = reminder.dueDateComponents?.date { line += ", due \(describe(due))" }
            line += " [\(reminder.calendar.title)]"
            if let notes = reminder.notes, !notes.isEmpty { line += "\n  Notes: \(notes.prefix(200))" }
            return line
        }.joined(separator: "\n")
    }

    private static func createReminder(_ arguments: [String: Any]) async throws -> String {
        try await requestReminders()
        guard let list = store.defaultCalendarForNewReminders() else { throw DeviceError.unavailable("There is no reminders list.") }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = arguments["title"] as? String ?? "Reminder"
        reminder.notes = arguments["notes"] as? String
        if let due = date(arguments["due"] as? String) {
            let parts: Set<Calendar.Component> = due.allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: due.date)
            if !due.allDay { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        try store.save(reminder, commit: true)
        return "Added the reminder “\(reminder.title ?? "")” to \(list.title)."
    }

    // MARK: Contacts

    private static func contacts(_ query: String) async throws -> String {
        let contacts = CNContactStore()
        guard (try? await contacts.requestAccess(for: .contacts)) == true else { throw DeviceError.denied("contacts") }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactJobTitleKey,
                                       CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactBirthdayKey]
            .map { $0 as CNKeyDescriptor }
        let query = query.trimmingCharacters(in: .whitespaces)
        let found: [CNContact] = try await Task.detached {
            var found = try contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
            if found.isEmpty, query.contains("@") {
                found = try contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: query), keysToFetch: keys)
            }
            if found.isEmpty {
                // Company names aren't covered by the name search.
                let request = CNContactFetchRequest(keysToFetch: keys)
                try contacts.enumerateContacts(with: request) { contact, stop in
                    if contact.organizationName.localizedCaseInsensitiveContains(query) { found.append(contact) }
                    if found.count >= 20 { stop.pointee = true }
                }
            }
            return found
        }.value
        guard !found.isEmpty else { return "No contacts match \"\(query)\"." }
        return found.prefix(20).map { contact in
            var lines = ["- " + [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")]
            let work = [contact.jobTitle, contact.organizationName].filter { !$0.isEmpty }.joined(separator: ", ")
            if !work.isEmpty { lines.append("  " + work) }
            for phone in contact.phoneNumbers { lines.append("  Phone (\(CNLabeledValue<NSString>.localizedString(forLabel: phone.label ?? ""))): \(phone.value.stringValue)") }
            for email in contact.emailAddresses { lines.append("  Email: \(email.value)") }
            for address in contact.postalAddresses {
                lines.append("  Address: " + CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", "))
            }
            if let birthday = contact.birthday?.date { lines.append("  Birthday: \(birthday.formatted(date: .long, time: .omitted))") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: Location

    private static func location() async throws -> String {
        let location = try await LocationFetcher().fetch()
        var text = String(format: "Coordinates: %.4f, %.4f (accuracy about %.0f m).", location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy)
        if let place = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            let address = [place.name, place.locality, place.administrativeArea, place.country].compactMap { $0 }.filter { !$0.isEmpty }
            text = "Place: " + address.joined(separator: ", ") + ". " + text
        }
        return text
    }
}

/// One location fix, asking for permission when needed.
@MainActor
private final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var keepAlive: LocationFetcher?

    func fetch() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            keepAlive = self
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: finish(.failure(DeviceTools.DeviceError.denied("the location")))
            default: manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        manager.delegate = nil
        keepAlive = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard continuation != nil else { return }
            switch manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted: finish(.failure(DeviceTools.DeviceError.denied("the location")))
            default: manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in finish(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in finish(.failure(error)) }
    }
}
