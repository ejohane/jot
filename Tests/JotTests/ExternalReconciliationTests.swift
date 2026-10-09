import Foundation
import XCTest
@testable import Jot

@MainActor
final class ExternalReconciliationTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Jots")
    private let url = URL(fileURLWithPath: "/Jots/2026/10/02/n.md")
    private var jot: ActiveJot { ActiveJot(id: "n", path: url.path, acknowledgedRevision: 2) }

    func testAcknowledgedNoteAdoptsExternalTextAndRemainsEditable() async throws {
        let files = InMemoryFileSystem()
        files.replaceExternally(at: url, with: "original")
        let writer = JotWriter(rootURL: root, fileSystem: files) { _ in }
        _ = try await writer.restore(jot)
        let unchanged = try await writer.hasExternalChange()
        XCTAssertFalse(unchanged)
        files.replaceExternally(at: url, with: "Mac edit")
        let changed = try await writer.hasExternalChange()
        XCTAssertTrue(changed)
        let change = try await writer.reconcileExternal()
        XCTAssertEqual(change?.text, "Mac edit")
        XCTAssertEqual(change?.jot.acknowledgedRevision, 3)
        await writer.receive(EditorSnapshot(revision: 4, text: "Mac edit plus phone", selection: .start, viewport: .top), flushImmediately: true)
        XCTAssertEqual(try files.data(at: url), Data("Mac edit plus phone".utf8))
    }

    func testDirtyNoteKeepsLocalAndExternalVersions() async throws {
        let files = InMemoryFileSystem()
        files.replaceExternally(at: url, with: "baseline")
        let writer = JotWriter(rootURL: root, fileSystem: files) { _ in }
        _ = try await writer.restore(jot)
        files.replaceExternally(at: url, with: "Mac edit")
        await writer.receive(EditorSnapshot(revision: 3, text: "Phone edit", selection: .start, viewport: .top), flushImmediately: true)
        let change = try await writer.reconcileExternal()
        XCTAssertNil(change)
        XCTAssertEqual(try files.data(at: url), Data("Mac edit".utf8))
        let copy = await writer.saveCurrentVersionAsCopy()
        XCTAssertEqual(try files.data(at: URL(fileURLWithPath: try XCTUnwrap(copy).path)), Data("Phone edit".utf8))
    }

    func testUnchangedExternalFileDoesNotResetEditorRevision() async throws {
        let files = InMemoryFileSystem()
        files.replaceExternally(at: url, with: "baseline")
        let writer = JotWriter(rootURL: root, fileSystem: files) { _ in }
        _ = try await writer.restore(jot)
        let change = try await writer.reconcileExternal()
        let active = await writer.currentJot()
        XCTAssertNil(change)
        XCTAssertEqual(active?.acknowledgedRevision, 2)
        XCTAssertTrue(files.writes.isEmpty)
    }
}
