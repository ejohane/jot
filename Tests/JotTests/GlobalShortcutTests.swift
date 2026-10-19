import XCTest
@testable import Jot

@MainActor
final class GlobalShortcutTests: XCTestCase {
    func testFailedReplacementLeavesOldGlobalRegistrationActive() throws {
        let original = KeyChord(17, "t", [.command, .option, .control, .shift])
        let occupied = KeyChord(15, "r", [.command, .option, .control, .shift])
        let first = GlobalShortcut {}
        let second = GlobalShortcut {}
        defer { first.unregister(); second.unregister() }
        do {
            try first.register(original)
            try second.register(occupied)
        } catch {
            throw XCTSkip("Test shortcut is already reserved by another app: \(error)")
        }
        XCTAssertThrowsError(try first.register(occupied))
        // If replacement removed the old registration, this would succeed.
        XCTAssertThrowsError(try second.register(original))
        first.unregister()
        XCTAssertNoThrow(try second.register(original))
    }
}
