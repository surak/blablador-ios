import XCTest
@testable import BlabladorCore

/// Which way the return key goes in the composer: Enter sends, a modified Enter starts a new line.
final class ComposerReturnTests: XCTestCase {
    func testEnterSends() {
        XCTAssertEqual(ComposerReturn.action(), .send)
    }

    func testShiftEnterStartsANewLine() {
        XCTAssertEqual(ComposerReturn.action(shift: true), .newLine)
    }

    func testCommandEnterStartsANewLine() {
        XCTAssertEqual(ComposerReturn.action(command: true), .newLine)
    }

    func testControlEnterStartsANewLine() {
        XCTAssertEqual(ComposerReturn.action(control: true), .newLine)
    }

    /// The habit from before this change — Cmd+Enter sent — must not send any more.
    func testNoModifierCombinationSends() {
        for shift in [true, false] {
            for command in [true, false] {
                for control in [true, false] {
                    guard shift || command || control else { continue }
                    XCTAssertEqual(ComposerReturn.action(shift: shift, command: command, control: control), .newLine,
                                   "shift \(shift) command \(command) control \(control)")
                }
            }
        }
    }
}
