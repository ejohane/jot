import Foundation
import XCTest
@testable import Jot

@MainActor
final class JournalRecoveryTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Jots")
    private let url = URL(fileURLWithPath: "/Jots/2026/10/02/note.md")
    private var jot: ActiveJot { ActiveJot(id: "note", path: url.path, acknowledgedRevision: 3) }

    func testNewerExternalEditSurvivesJournalRestoreAndCopy() async throws {
        let files = InMemoryFileSystem()
        files.replaceExternally(at: url, with: "Mac changed this")
        let writer = JotWriter(rootURL: root, fileSystem: files) { _ in }
        let restored = try await writer.restoreJournal(jot, text: "Phone offline edit", revision: 4, baseline: Data("shared baseline".utf8))
        XCTAssertEqual(restored, "Phone offline edit")
        let saved = await writer.flush(through: 4)
        XCTAssertFalse(saved)
        XCTAssertEqual(try files.data(at: url), Data("Mac changed this".utf8))
        let copy = await writer.saveCurrentVersionAsCopy()
        let copyURL = try XCTUnwrap(copy).path
        XCTAssertEqual(try files.data(at: URL(fileURLWithPath: copyURL)), Data("Phone offline edit".utf8))
        XCTAssertEqual(try files.data(at: url), Data("Mac changed this".utf8))
    }

    func testMatchingBaselineAllowsRecoveredEditToSave() async throws {
        let files = InMemoryFileSystem()
        files.replaceExternally(at: url, with: "baseline")
        let writer = JotWriter(rootURL: root, fileSystem: files) { _ in }
        _ = try await writer.restoreJournal(jot, text: "recovered edit", revision: 4, baseline: Data("baseline".utf8))
        let saved = await writer.flush(through: 4)
        XCTAssertTrue(saved)
        XCTAssertEqual(try files.data(at: url), Data("recovered edit".utf8))
    }

    func testLegacyJournalWithoutBaselinePreservesBoth() async throws {
        let files = InMemoryFileSystem()
        files.replaceExternally(at: url, with: "external version")
        let writer = JotWriter(rootURL: root, fileSystem: files) { _ in }
        _ = try await writer.restoreJournal(jot, text: "legacy recovery", revision: 4, baseline: nil)
        let saved = await writer.flush(through: 4)
        XCTAssertFalse(saved)
        XCTAssertEqual(try files.data(at: url), Data("external version".utf8))
        let copy = await writer.saveCurrentVersionAsCopy()
        XCTAssertEqual(try files.data(at: URL(fileURLWithPath: try XCTUnwrap(copy).path)), Data("legacy recovery".utf8))
    }

    func testCompletedDiskWriteBeforeJournalAcknowledgementNeedsNoDuplicate() async throws {
        let files = InMemoryFileSystem()
        files.replaceExternally(at: url, with: "already saved")
        let writer = JotWriter(rootURL: root, fileSystem: files) { _ in }
        _ = try await writer.restoreJournal(jot, text: "already saved", revision: 4, baseline: Data("old".utf8))
        let saved = await writer.flush(through: 4)
        let active = await writer.currentJot()
        XCTAssertTrue(saved)
        XCTAssertEqual(active?.acknowledgedRevision, 4)
        XCTAssertTrue(files.writes.isEmpty)
    }
}
