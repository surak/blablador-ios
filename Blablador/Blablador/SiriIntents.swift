import AppIntents
import Foundation

@available(iOS 16.0, *)
struct BlabladorCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Tell Blablador"
    static var description = IntentDescription("Send a command to Blablador.")
    static var openAppWhenRun = true

    @Parameter(title: "Command", description: "What you want Blablador to do", requestValueDialog: "What should Blablador do?")
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Blablador to \(\.$command)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriCommandCenter.shared.handle(command: command)
        return .result(dialog: "Sending \"\(command)\" to Blablador.")
    }
}

@available(iOS 16.0, *)
struct BlabladorShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BlabladorCommandIntent(),
            phrases: [
                "Tell \(.applicationName)",
                "Ask \(.applicationName)"
            ],
            shortTitle: "Tell Blablador",
            systemImageName: "mic"
        )
    }
}
