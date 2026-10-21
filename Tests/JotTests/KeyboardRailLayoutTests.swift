import XCTest
@testable import Jot

final class KeyboardRailLayoutTests: XCTestCase {
    func testFirstLaunchAndCorruptPreferencesKeepExistingRail() {
        XCTAssertEqual(KeyboardRailLayout().actions, [.format, .checklist, .image, .dictation])
        XCTAssertEqual(KeyboardRailLayout(storedValue: "invalid").actions, KeyboardRailLayout.defaults)
    }

    func testCustomizationRoundTripPreservesOrderAndDoesNotRestoreRemovedDefaults() {
        var layout = KeyboardRailLayout()
        layout.remove(.image)
        layout.add(.bold)
        layout.move(.bold, to: 0)
        let restored = KeyboardRailLayout(storedValue: layout.storedValue)
        XCTAssertEqual(restored.actions, [.bold, .format, .checklist, .dictation])
        XCTAssertTrue(restored.availableActions.contains(.image))
        XCTAssertFalse(restored.availableActions.contains(.bold))
    }

    func testRemovedAllActionsStaysEmptyAndCanBeRepopulated() {
        var layout = KeyboardRailLayout(storedValue: "[]")
        XCTAssertEqual(layout.actions, [])
        XCTAssertEqual(KeyboardRailLayout(storedValue: layout.storedValue).actions, [])
        layout.add(.format)
        layout.add(.format)
        XCTAssertEqual(layout.actions, [.format])
    }

    func testUnknownIdentifiersAndDuplicatesAreIgnoredWithoutChangingKnownOrder() {
        let layout = KeyboardRailLayout(storedValue: #"["bold","future-action","image","bold","undo"]"#)
        XCTAssertEqual(layout.actions, [.bold, .image, .undo])
    }

    func testReorderingInBothDirectionsAndStaleOperations() {
        var layout = KeyboardRailLayout()
        layout.move(.format, to: 3)
        XCTAssertEqual(layout.actions, [.checklist, .image, .dictation, .format])
        layout.move(.format, to: 0)
        XCTAssertEqual(layout.actions, KeyboardRailLayout.defaults)
        layout.move(.undo, to: 0)
        layout.move(.format, to: -1)
        layout.move(.format, to: 99)
        XCTAssertEqual(layout.actions, KeyboardRailLayout.defaults)
    }
}
