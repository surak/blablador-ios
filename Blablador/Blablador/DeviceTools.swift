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

    static let names: Set<String> = ["calendar_events", "create_event", "list_reminders", "create_reminder", "find_contacts", "current_location"]

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                          "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    static let definitions: [[String: Any]] = [
        function("calendar_events", "List events in the user's calendars between two dates.", [
            "from": ["type": "string", "description": "Start, ISO 8601 date or date-time, e.g. 2026-11-02 or 2026-11-02T09:00."],
            "to": ["type": "string", "description": "End, ISO 8601; defaults to one day after from."],
            "query": ["type": "string", "description": "Only events whose title, place or notes contain this text."]
        ], required: ["from"]),
        function("create_event", "Add an event to the user's default calendar. The user is asked first.", [
            "title": ["type": "string"],
            "start": ["type": "string", "description": "ISO 8601 date-time, or a date for an all-day event."],
            "end": ["type": "string", "description": "ISO 8601; defaults to one hour after start."],
            "location": ["type": "string"],
            "notes": ["type": "string"]
        ], required: ["title", "start"]),
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

    static let systemPrompt = "You can use the user's calendar (calendar_events, create_event), reminders (list_reminders, create_reminder), contacts (find_contacts) and location (current_location). Use local times; creating events and reminders shows the user a confirmation first."

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
        case "calendar_events": return try await events(arguments)
        case "create_event": return try await createEvent(arguments)
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

    private static func events(_ arguments: [String: Any]) async throws -> String {
        let fromText = arguments["from"] as? String
        guard let from = date(fromText) else { throw DeviceError.badDate(fromText ?? "") }
        let start = from.allDay ? Calendar.current.startOfDay(for: from.date) : from.date
        var end = date(arguments["to"] as? String).map { $0.allDay ? Calendar.current.date(byAdding: .day, value: 1, to: $0.date)! : $0.date }
            ?? Calendar.current.date(byAdding: .day, value: 1, to: start)!
        if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: start)! }
        try await requestEvents()
        let predicate = store.predicateForEvents(withStart: start, end: min(end, Calendar.current.date(byAdding: .year, value: 1, to: start)!), calendars: nil)
        var events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if let query = (arguments["query"] as? String)?.lowercased(), !query.isEmpty {
            events = events.filter { [$0.title, $0.location, $0.notes].compactMap { $0?.lowercased() }.contains { $0.contains(query) } }
        }
        guard !events.isEmpty else { return "No events between \(describe(start)) and \(describe(end))." }
        return events.prefix(100).map { event in
            var line = "- \(event.title ?? "(no title)"): "
            line += event.isAllDay ? describe(event.startDate, allDay: true) + " (all day)" : "\(describe(event.startDate)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
            if let location = event.location, !location.isEmpty { line += ", at \(location)" }
            line += " [\(event.calendar.title)]"
            if let notes = event.notes, !notes.isEmpty { line += "\n  Notes: \(notes.prefix(300))" }
            return line
        }.joined(separator: "\n")
    }

    private static func createEvent(_ arguments: [String: Any]) async throws -> String {
        let startText = arguments["start"] as? String
        guard let start = date(startText) else { throw DeviceError.badDate(startText ?? "") }
        try await requestEvents()
        guard let calendar = store.defaultCalendarForNewEvents else { throw DeviceError.unavailable("There is no calendar to add events to.") }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = arguments["title"] as? String ?? "Event"
        event.isAllDay = start.allDay
        event.startDate = start.date
        event.endDate = date(arguments["end"] as? String)?.date ?? start.date.addingTimeInterval(start.allDay ? 0 : 3600)
        event.location = arguments["location"] as? String
        event.notes = arguments["notes"] as? String
        try store.save(event, span: .thisEvent)
        return "Added “\(event.title ?? "")” on \(describe(event.startDate, allDay: event.isAllDay)) to \(calendar.title)."
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
