import XCTest
@testable import Jot

final class NotebookOpeningTests: XCTestCase {
    func testOpeningAnotherFolderClearsAllPreviousDocumentState() {
        var original = PersistedSession.empty
        original.activeJot = ActiveJot(id: "old-note", path: "/old/note.md", acknowledgedRevision: 42)
        original.selection = EditorSelection(anchor: 12, head: 18)
        original.viewport = EditorViewport(scrollTop: 400)
        original.recoveryText = "Writing belonging only to the old notebook"
        original.recoveryRevision = 43
        original.acknowledgedData = Data("previous saved version".utf8)

        let next = original.openingNotebook(bookmark: Data([1, 2, 3]), storage: .iCloud)

        XCTAssertNil(next.activeJot)
        XCTAssertNil(next.recoveryText)
        XCTAssertNil(next.recoveryRevision)
        XCTAssertNil(next.acknowledgedData)
        XCTAssertEqual(next.selection, .start)
        XCTAssertEqual(next.viewport, .top)
        XCTAssertEqual(next.rootBookmark, Data([1, 2, 3]))
        XCTAssertEqual(next.storage, .iCloud)
        XCTAssertEqual(original.recoveryRevision, 43)
        XCTAssertEqual(original.activeJot?.path, "/old/note.md")
    }

    func testOpeningAnotherFolderPreservesAppPreferences() {
        var original = PersistedSession.empty
        original.shortcut = .commandShiftJ
        original.launchAtLogin = true
        original.panelFrame = "{{100, 200}, {600, 400}}"
        original.panelPositionWasUserChosen = true

        let next = original.openingNotebook(bookmark: Data([4]), storage: .local)

        XCTAssertEqual(next.shortcut, .commandShiftJ)
        XCTAssertTrue(next.launchAtLogin)
        XCTAssertEqual(next.panelFrame, original.panelFrame)
        XCTAssertEqual(next.panelPositionWasUserChosen, true)
    }

    func testNewNotebookSessionSurvivesRelaunchWithoutRestoringOldWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(fileURL: root.appendingPathComponent("session.json"))
        var original = PersistedSession.empty
        original.recoveryText = "Old notebook"
        let next = original.openingNotebook(bookmark: Data([5]), storage: .local)
        try await store.save(next, generation: 10)
        // An old in-flight save must not undo the committed notebook change.
        try await store.save(original, generation: 9)
        let relaunched = await SessionStore(fileURL: root.appendingPathComponent("session.json")).load()
        XCTAssertEqual(relaunched, next)
        XCTAssertNil(relaunched.recoveryText)
    }
}
