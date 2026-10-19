import AppKit
import XCTest
@testable import Jot

@MainActor
final class KeyboardShortcutsTests: XCTestCase {
    func testLegacySessionLoadsWithoutNewPreferences() throws {
        var session = PersistedSession.empty
        session.shortcut = .commandShiftJ
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(PersistedSession.self, from: data)
        XCTAssertNil(decoded.keyboardShortcuts)
        let shortcuts = KeyboardShortcuts(session: decoded)
        XCTAssertEqual(shortcuts[.showJot], .legacy(.commandShiftJ))
        XCTAssertEqual(shortcuts[.finishAndNew], ShortcutAction.finishAndNew.defaultChord)
    }

    func testCustomBindingsSurviveSessionRoundTrip() throws {
        var session = PersistedSession.empty
        session.keyboardShortcuts = [ShortcutAction.finishAndNew.rawValue: KeyChord(3, "f", [.command, .shift])]
        let decoded = try JSONDecoder().decode(PersistedSession.self, from: JSONEncoder().encode(session))
        let shortcuts = KeyboardShortcuts(session: decoded)
        XCTAssertEqual(shortcuts[.finishAndNew], session.keyboardShortcuts?[ShortcutAction.finishAndNew.rawValue])
        XCTAssertEqual(shortcuts[.copy], ShortcutAction.copy.defaultChord)
    }

    func testConflictsAndPlainTypingNeverApply() {
        let shortcuts = KeyboardShortcuts(session: .empty)
        var applyCount = 0
        shortcuts.apply = { _ in applyCount += 1 }
        shortcuts.recording = .finishAndNew
        shortcuts.assign(shortcuts[.copy], to: .finishAndNew)
        XCTAssertNotNil(shortcuts.error)
        XCTAssertEqual(shortcuts.recording, .finishAndNew)
        shortcuts.assign(KeyChord(3, "f", .shift), to: .finishAndNew)
        XCTAssertNotNil(shortcuts.error)
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(shortcuts[.finishAndNew], ShortcutAction.finishAndNew.defaultChord)
    }

    func testFailedRegistrationPreservesBindingsAndResetIsAtomic() {
        let shortcuts = KeyboardShortcuts(session: .empty)
        let custom = KeyChord(3, "f", [.command, .shift])
        shortcuts.assign(custom, to: .finishAndNew)
        shortcuts.apply = { _ in throw NSError(domain: "registration", code: 1) }
        shortcuts.reset()
        XCTAssertEqual(shortcuts[.finishAndNew], custom)
        XCTAssertNotNil(shortcuts.error)
        shortcuts.apply = { _ in }
        shortcuts.reset()
        XCTAssertEqual(shortcuts[.finishAndNew], ShortcutAction.finishAndNew.defaultChord)
        XCTAssertNil(shortcuts.error)
    }

    func testDefaultsAreUniqueAndNotebookSwitchPreservesCustomShortcuts() {
        let shortcuts = KeyboardShortcuts(session: .empty)
        let identities = ShortcutAction.allCases.map { "\(shortcuts[$0].keyCode):\(shortcuts[$0].modifiers)" }
        XCTAssertEqual(Set(identities).count, ShortcutAction.allCases.count)
        var session = PersistedSession.empty
        session.keyboardShortcuts = shortcuts.bindings
        XCTAssertEqual(session.openingNotebook(bookmark: Data(), storage: .local).keyboardShortcuts, shortcuts.bindings)
    }

    func testMatchingNormalizesCapsLockAndRequiresExactModifiers() throws {
        let chord = KeyChord(3, "f", [.command, .shift])
        func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "F", charactersIgnoringModifiers: "F",
                isARepeat: false, keyCode: 3))
        }
        XCTAssertTrue(chord.matches(try event([.command, .shift, .capsLock])))
        XCTAssertFalse(chord.matches(try event([.command])))
        XCTAssertFalse(chord.matches(try event([.command, .shift, .option])))
    }
}
