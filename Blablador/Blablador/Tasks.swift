import SwiftUI
import UserNotifications

/// A prompt that runs by itself at set times, e.g. "Every weekday at 8:00: summarise the news about HPC".
struct ScheduledTask: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var prompt: String
    var hour = 8
    var minute = 0
    /// Weekdays it runs on (1 = Sunday … 7 = Saturday, as in Calendar); empty runs once, on `date`.
    var weekdays: Set<Int> = Set(1...7)
    var date: Date?
    var enabled = true
    var webSearch = true
    var lastRun: Date?
    var lastChat: UUID?
    /// Repeating tasks don't run for times before they were made.
    var created = Date()

    /// The latest time at or before `now` it was due, or nil if it hasn't been due since `after`.
    func due(now: Date = Date(), after: Date) -> Date? {
        guard enabled else { return nil }
        let calendar = Calendar.current
        if weekdays.isEmpty {
            guard let date, date <= now, date > after else { return nil }
            return date
        }
        // Today's or an earlier day's time, looking back a week.
        for back in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if time <= now { return time > after ? time : nil }
        }
        return nil
    }

    /// The next time it runs.
    func next(after now: Date = Date()) -> Date? {
        guard enabled else { return nil }
        if weekdays.isEmpty { return date.flatMap { $0 > now ? $0 : nil } }
        let calendar = Calendar.current
        for ahead in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: ahead, to: now),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), time > now else { continue }
            return time
        }
        return nil
    }

    var scheduleText: String {
        let time = String(format: "%02d:%02d", hour, minute)
        if weekdays.isEmpty { return date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Once" }
        if weekdays.count == 7 { return "Every day at \(time)" }
        if weekdays == Set(2...6) { return "Weekdays at \(time)" }
        if weekdays == [1, 7] { return "Weekends at \(time)" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { symbols[$0 - 1] }.joined(separator: ", ") + " at \(time)"
    }
}

/// Keeps scheduled tasks (encrypted `tasks.json`), runs them when due while the app is open, and on launch or when
/// it comes to the front for any that were missed. A local notification at each time lets the user open the app
/// to run it, since iOS doesn't let apps run at exact times in the background.
@MainActor
final class TaskScheduler: ObservableObject {
    static let shared = TaskScheduler()

    @Published private(set) var tasks: [ScheduledTask] = []
    /// Tasks found due, waiting for the chat to be free.
    private var queue: [UUID] = []
    private var timer: Timer?
    weak var store: ChatStore?

    private static var fileURL: URL { AppFolder.url.appendingPathComponent("tasks.json") }

    private init() {
        if let data = EncryptedStorage.read(Self.fileURL), let tasks = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            self.tasks = tasks
        }
    }

    func start(with store: ChatStore) {
        self.store = store
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in TaskScheduler.shared.check() }
        }
        check()
    }

    func save(_ task: ScheduledTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        persist()
        if !tasks.isEmpty { Notifier.requestPermission() }
    }

    func delete(_ ids: Set<UUID>) {
        tasks.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Runs tasks that became due since they last ran (or since they were made), one at a time.
    func check(now: Date = Date()) {
        for task in tasks where !queue.contains(task.id) {
            let after = task.lastRun ?? (task.weekdays.isEmpty ? .distantPast : task.created)
            if task.due(now: now, after: after) != nil { queue.append(task.id) }
        }
        runNext()
    }

    func runNow(_ id: UUID) {
        if !queue.contains(id) { queue.append(id) }
        runNext()
    }

    private func runNext() {
        guard let store, !store.isBusy, let id = queue.first else { return }
        queue.removeFirst()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return runNext() }
        tasks[index].lastRun = Date()
        if tasks[index].weekdays.isEmpty { tasks[index].enabled = false }
        let task = tasks[index]
        persist()
        tasks[index].lastChat = store.runTask(task)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        EncryptedStorage.write(data, to: Self.fileURL)
        scheduleNotifications()
    }

    /// One reminder notification per task for its next time (repeating ones per weekday).
    private func scheduleNotifications() {
        guard Notifier.available else { return }
        let center = UNUserNotificationCenter.current()
        let tasks = tasks
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix("task.") })
            for task in tasks where task.enabled {
                let content = UNMutableNotificationContent()
                content.title = task.title
                content.body = "Scheduled task: open Blablador to run it."
                content.sound = .default
                content.userInfo = ["task": task.id.uuidString]
                if task.weekdays.isEmpty {
                    guard let date = task.date, date > Date() else { continue }
                    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                    center.add(UNNotificationRequest(identifier: "task.\(task.id)", content: content,
                                                     trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
                } else {
                    for day in task.weekdays {
                        let parts = DateComponents(hour: task.hour, minute: task.minute, weekday: day)
                        center.add(UNNotificationRequest(identifier: "task.\(task.id).\(day)", content: content,
                                                         trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)))
                    }
                }
            }
        }
    }

    // MARK: Tool

    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "schedule_task",
            "description": "Schedule a prompt to run by itself at a set time, once or on repeating weekdays, e.g. a daily news summary. Each run makes a new chat and a notification. The user confirms first.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Short name, e.g. \"Morning HPC news\"."],
                    "prompt": ["type": "string", "description": "What to do at each run, written as a complete request to the assistant, e.g. \"Summarise today's top AI news\". For a plain reminder: \"Remind the user to call Maria.\""],
                    "time": ["type": "string", "description": "Local time HH:MM."],
                    "days": ["type": "array", "items": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]],
                             "description": "Weekdays to repeat on; leave out for every day."],
                    "date": ["type": "string", "description": "For a single run: the date, YYYY-MM-DD; then days is ignored."]
                ],
                "required": ["title", "prompt", "time"]
            ]
        ]
    ]

    static func task(from arguments: [String: Any]) -> ScheduledTask? {
        guard let title = arguments["title"] as? String, let prompt = arguments["prompt"] as? String, !prompt.isEmpty,
              let time = arguments["time"] as? String else { return nil }
        let parts = time.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        var task = ScheduledTask(title: title, prompt: prompt, hour: parts[0], minute: parts[1])
        if let dateText = arguments["date"] as? String, let day = DeviceTools.date(dateText)?.date {
            task.weekdays = []
            task.date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
        } else if let days = arguments["days"] as? [String], !days.isEmpty {
            let numbers = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            let set = Set(days.compactMap { numbers[$0.lowercased().prefix(3).description] })
            if !set.isEmpty { task.weekdays = set }
        }
        return task
    }
}

/// Local notifications: a finished background reply or task, and opening the chat when one is tapped.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Notifications need an app bundle (not available in the test runner).
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notify(title: String, body: String, chat: UUID) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(plain(body).prefix(200))
        content.sound = .default
        content.userInfo = ["chat": chat.uuidString]
        let request = UNNotificationRequest(identifier: "chat.\(chat).\(UUID())", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        // Asked the first time there is something to tell.
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in if granted { center.add(request) } }
            } else {
                center.add(request)
            }
        }
    }

    /// Notification text without Markdown marks.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\*\*|__|`|^#+\s*|\[(\d+)\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func install() { UNUserNotificationCenter.current().delegate = self }

    /// Task reminders are pointless while the app is open (it runs the task itself); finished replies show.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.userInfo["task"] != nil {
            await MainActor.run { TaskScheduler.shared.check() }
            return []
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run {
            if let chat = (info["chat"] as? String).flatMap(UUID.init) {
                SiriCommandCenter.shared.open(URL(string: "blablador://chat?id=\(chat.uuidString)")!)
            } else {
                TaskScheduler.shared.check()
            }
        }
    }
}

// MARK: - Views

struct TasksView: View {
    @ObservedObject private var scheduler = TaskScheduler.shared
    @State private var editing: ScheduledTask?

    var body: some View {
        Form {
            Section {
                if scheduler.tasks.isEmpty {
                    Text("No tasks yet. Add one here, or ask in a chat, e.g. “Every weekday at 8, summarise the news about supercomputing.”")
                        .foregroundStyle(.secondary)
                }
                ForEach(scheduler.tasks) { task in
                    Button { editing = task } label: {
                        HStack(spacing: 12) {
                            ScheduleIcon(size: 26)
                                .opacity(task.enabled ? 1 : 0.4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).foregroundStyle(task.enabled ? .primary : .secondary)
                                Text(task.enabled ? task.scheduleText : "Off").scaledFont(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let last = task.lastRun {
                                Text(last.formatted(.relative(presentation: .named))).scaledFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) { scheduler.delete([task.id]) }
                    }
                    .contextMenu {
                        Button("Run now") { scheduler.runNow(task.id) }
                        Button("Delete", role: .destructive) { scheduler.delete([task.id]) }
                    }
                }
                Button {
                    editing = ScheduledTask(title: "", prompt: "")
                } label: {
                    Label("Add task", systemImage: "plus")
                }
            } footer: {
                Text("Each run makes a new chat and a notification. On iPhone and iPad, a notification appears at the set time and the task runs when you open Blablador; on the Mac it runs while Blablador is open.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Scheduled tasks")
        .sheet(item: $editing) { task in
            NavigationStack { TaskEditor(task: task) }
#if os(macOS)
                .frame(minWidth: 460, minHeight: 520)
#endif
        }
    }
}

private struct TaskEditor: View {
    @State var task: ScheduledTask
    @Environment(\.dismiss) private var dismiss

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: task.hour, minute: task.minute, second: 0, of: Date()) ?? Date() },
            set: {
                task.hour = Calendar.current.component(.hour, from: $0)
                task.minute = Calendar.current.component(.minute, from: $0)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $task.title)
                TextField("What should Blablador do?", text: $task.prompt, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section("When") {
                Picker("Repeat", selection: Binding(get: { task.weekdays.isEmpty }, set: { once in
                    task.weekdays = once ? [] : Set(1...7)
                    if once, task.date == nil { task.date = Calendar.current.date(byAdding: .day, value: 1, to: time.wrappedValue) }
                })) {
                    Text("On days").tag(false)
                    Text("Once").tag(true)
                }
                .pickerStyle(.segmented)
                if task.weekdays.isEmpty {
                    DatePicker("Date", selection: Binding(get: { task.date ?? Date() }, set: { task.date = $0 }))
                } else {
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    HStack {
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                            let on = task.weekdays.contains(day)
                            Button {
                                if on, task.weekdays.count > 1 { task.weekdays.remove(day) } else { task.weekdays.insert(day) }
                            } label: {
                                Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                                    .frame(maxWidth: .infinity, minHeight: 32)
                                    .foregroundStyle(on ? .white : .primary)
                                    .background(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.background), in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section {
                Toggle("Search the web", isOn: $task.webSearch)
                Toggle("On", isOn: $task.enabled)
            }
            if TaskScheduler.shared.tasks.contains(where: { $0.id == task.id }) {
                Section {
                    Button("Run now") {
                        TaskScheduler.shared.save(task)
                        TaskScheduler.shared.runNow(task.id)
                        dismiss()
                    }
                    Button("Delete task", role: .destructive) {
                        TaskScheduler.shared.delete([task.id])
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(task.title.isEmpty ? "New task" : task.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if task.title.isEmpty { task.title = String(task.prompt.prefix(40)) }
                    TaskScheduler.shared.save(task)
                    dismiss()
                }
                .disabled(task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// The icon for scheduled tasks: Blablador's logo with a small clock at the top right that glows in and out.
struct ScheduleIcon: View {
    var size: CGFloat = 22
    @State private var glowing = false

    var body: some View {
        Image("Avatar")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "clock.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white, Theme.gradient)
                    .background(Circle().fill(Theme.background).padding(-1))
                    .shadow(color: .purple.opacity(glowing ? 0.9 : 0), radius: glowing ? size * 0.3 : 0)
                    .opacity(glowing ? 1 : 0.55)
                    .offset(x: size * 0.22, y: -size * 0.22)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glowing = true }
            }
            .accessibilityHidden(true)
    }
}

/// An SF Symbol by name, or the schedule icon for "schedule".
struct ToolIcon: View {
    let name: String
    var size: CGFloat = 20

    static let schedule = "schedule"

    var body: some View {
        if name == Self.schedule {
            ScheduleIcon(size: size)
        } else {
            Image(systemName: name)
        }
    }
}
