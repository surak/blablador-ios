import XCTest
@testable import BlabladorCore

@MainActor
final class AgentFeatureTests: XCTestCase {
    private func date(_ text: String) -> Date { DeviceTools.date(text)!.date }

    func testDeviceDatesAcceptDayAndTime() {
        XCTAssertEqual(DeviceTools.date("2026-11-02")?.allDay, true)
        XCTAssertEqual(DeviceTools.date("2026-11-02T09:30")?.allDay, false)
        XCTAssertEqual(Calendar.current.component(.hour, from: date("2026-11-02T09:30")), 9)
        XCTAssertNil(DeviceTools.date("next tuesday"))
    }

    func testPlanItemsReadStatuses() {
        let items = PlanTools.items(from: ["steps": [["step": "Search", "status": "done"], ["step": "Write", "status": "in_progress"], ["step": "Check", "status": "pending"], ["status": "done"]]])
        XCTAssertEqual(items.map(\.text), ["Search", "Write", "Check"])
        XCTAssertEqual(items.map(\.status), [.done, .active, .pending])
        XCTAssertEqual(PlanTools.summary(items), "Plan updated (1 of 3 done). Continue with the next step.")
    }

    func testScheduleToolArguments() {
        let daily = TaskScheduler.task(from: ["title": "News", "prompt": "Summarise HPC news", "time": "08:15", "days": ["mon", "fri"]])
        XCTAssertEqual(daily?.hour, 8)
        XCTAssertEqual(daily?.minute, 15)
        XCTAssertEqual(daily?.weekdays, [2, 6])
        let once = TaskScheduler.task(from: ["title": "Call", "prompt": "Remind me", "time": "14:00", "date": "2026-12-01"])
        XCTAssertEqual(once?.weekdays, [])
        XCTAssertEqual(once?.date, date("2026-12-01T14:00"))
        XCTAssertNil(TaskScheduler.task(from: ["title": "Bad", "prompt": "x", "time": "25:00"]))
    }

    func testTaskDueTimes() {
        var task = ScheduledTask(title: "News", prompt: "x", hour: 8, minute: 0)
        task.weekdays = Set(1...7)
        let morning = date("2026-11-02T09:00")
        // Due at 8:00 today when it last ran yesterday, not again after running today.
        XCTAssertEqual(task.due(now: morning, after: date("2026-11-01T08:00")), date("2026-11-02T08:00"))
        XCTAssertNil(task.due(now: morning, after: date("2026-11-02T08:00")))
        XCTAssertEqual(task.next(after: morning), date("2026-11-03T08:00"))
        // Weekdays only: Saturday's run waits until Monday.
        task.weekdays = Set(2...6)
        XCTAssertEqual(task.next(after: date("2026-10-31T09:00")), date("2026-11-02T08:00"))
        XCTAssertEqual(task.scheduleText, "Weekdays at 08:00")
        // Once.
        var once = ScheduledTask(title: "Once", prompt: "x")
        once.weekdays = []
        once.date = date("2026-11-02T10:00")
        XCTAssertNil(once.due(now: morning, after: .distantPast))
        XCTAssertEqual(once.due(now: date("2026-11-02T10:01"), after: .distantPast), once.date)
    }

    func testNeverHidesTools() {
        let permissions = ToolPermissions.shared
        permissions.resetAll()
        defer { permissions.resetAll() }
        let tools = [WebSearch.tool, PythonRunner.tool, PlanTools.tool]
        XCTAssertEqual(permissions.filter(tools).count, 3)
        permissions.set("python", .never)
        let names = permissions.filter(tools).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["web_search", "update_plan"])
        XCTAssertEqual(permissions.rule("calendarWrite"), .ask)
        XCTAssertEqual(ToolPermissions.kind(of: "create_event"), "calendarWrite")
    }

    func testMentionsBecomeInstructions() {
        let prompt = ChatStore.mentionPrompt([Mention(kind: .tool, value: "web", name: "Web search", icon: "globe"),
                                              Mention(kind: .knowledge, value: UUID().uuidString, name: "Papers", icon: "books.vertical")])
        XCTAssertEqual(prompt, "For this message the user asked you to use web search (web_search, read_page); the knowledge base \"Papers\" (relevant excerpts are below).")
        XCTAssertNil(ChatStore.mentionPrompt([]))
        XCTAssertEqual(MentionCatalog.matches("pyt").first?.value, "python")
    }

    func testSkillDraftNeedsRealWork() {
        var trace = Trace(model: "m")
        trace.calls = [TraceCall(tool: "update_plan", arguments: "{}", state: .done),
                       TraceCall(tool: "web_search", arguments: "{}", state: .done),
                       TraceCall(tool: "read_page", arguments: "{}", state: .done)]
        XCTAssertFalse(SkillDrafter.worthDrafting(trace))
        trace.calls.append(TraceCall(tool: "run_python", arguments: "{}", state: .done))
        XCTAssertTrue(SkillDrafter.worthDrafting(trace))
        XCTAssertFalse(ChatStore.canRerun("create_event"))
        XCTAssertTrue(ChatStore.canRerun("web_search"))
    }

    func testOldMessagesDecodeWithoutNewFields() throws {
        let json = #"{"id":"\#(UUID().uuidString)","role":"assistant","content":"Hi","date":0,"isError":false}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertTrue(message.plan.isEmpty)
        XCTAssertNil(message.trace)
        XCTAssertTrue(message.mentions.isEmpty)
    }

    func testInterruptedRepliesStopLookingBusy() {
        var conversation = Conversation(title: "Task", model: "m")
        conversation.messages = [ChatMessage(role: .user, content: "Run"), ChatMessage(role: .assistant, content: ""), ChatMessage(role: .assistant, content: "Done")]
        let marked = ConversationLibrary.markingInterrupted(conversation)
        XCTAssertTrue(marked.messages[1].isError)
        XCTAssertTrue(marked.messages[1].content.contains("interrupted"))
        XCTAssertFalse(marked.messages[2].isError)
        XCTAssertEqual(marked.messages[0].content, "Run")
    }
}
