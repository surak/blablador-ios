import Combine
import Foundation

@MainActor
final class SiriCommandCenter: ObservableObject {
    static let shared = SiriCommandCenter()

    @Published private(set) var pendingCommand: String?

    private init() {}

    func handle(command: String) {
        pendingCommand = command
    }

    func consumePendingCommand() {
        pendingCommand = nil
    }
}
