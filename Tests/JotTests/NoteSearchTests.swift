import Foundation
import XCTest
@testable import Jot

final class NoteSearchTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JotSearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func note(_ root: URL, id: String, day: String = "26", source: String) throws -> URL {
        let folder = root.appendingPathComponent("2026/09/\(day)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("06-00-00-000--\(id).md")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRecentNotesAndFullContentRanking() async throws {
        let root = try root()
        try note(root, id: "title", day: "23", source: "# Ocean plans\nA checklist")
        try note(root, id: "phrase", day: "24", source: "Other ideas\nThe ocean plans are ready")
        try note(root, id: "words", source: "Other thoughts\nocean then \(String(repeating: "padding ", count: 150))plans")
        let index = NoteSearchIndex(root: root)
        let recentValue = await index.search(query: "", refresh: true)
        let recent = try XCTUnwrap(recentValue)
        XCTAssertEqual(recent.map(\.id), ["words", "phrase", "title"])
        let resultsValue = await index.search(query: "ocean plans")
        let results = try XCTUnwrap(resultsValue)
        XCTAssertEqual(results.map(\.id), ["title", "phrase", "words"])
        XCTAssertEqual(results.first?.title, "Ocean plans")
        XCTAssertTrue(results.last?.excerpt.contains("ocean") == true)
        let absent = await index.search(query: "ocean missing")
        XCTAssertEqual(absent, [])
    }

    func testMatchingExcerptAndUnicodeHighlightOffsets() async throws {
        let root = try root()
        try note(root, id: "unicode", source: "# Café trip\n\(String(repeating: "🙂 elsewhere ", count: 100))\nBring 📝 #project résumé tomorrow")
        let index = NoteSearchIndex(root: root)
        let resultsValue = await index.search(query: "#project resume", refresh: true)
        let results = try XCTUnwrap(resultsValue)
        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.excerpt.contains("#project résumé"))
        let excerpt = result.excerpt as NSString
        XCTAssertEqual(result.excerptMatches.map { excerpt.substring(with: NSRange(location: $0.from, length: $0.to - $0.from)) }, ["#project", "résumé"])
        let titleResultsValue = await index.search(query: "cafe")
        let titleResults = try XCTUnwrap(titleResultsValue)
        XCTAssertEqual(titleResults.first?.titleMatches, [NoteSearchMatch(from: 0, to: 4)])
    }

    func testRefreshReconcilesEditsDeletionsAndFolderChanges() async throws {
        let root = try root()
        let file = try note(root, id: "edited", source: "Before")
        let index = NoteSearchIndex(root: root)
        let before = await index.search(query: "before", refresh: true)
        XCTAssertEqual(before?.count, 1)
        try "After a longer edit".write(to: file, atomically: true, encoding: .utf8)
        let after = await index.search(query: "after", refresh: true)
        XCTAssertEqual(after?.count, 1)
        try FileManager.default.removeItem(at: file)
        let deleted = await index.search(query: "", refresh: true)
        XCTAssertEqual(deleted, [])
        let other = try self.root()
        try note(other, id: "other", source: "New folder")
        await index.configure(root: other)
        let changed = await index.search(query: "")
        XCTAssertEqual(changed?.map(\.id), ["other"])
    }

    func testSearchIncludesOrdinaryMarkdownFilesAndOpensTheirExactPath() async throws {
        let root = try root()
        let file = root.appendingPathComponent("Project plan.md")
        try "# Project plan\nImported Markdown".write(to: file, atomically: true, encoding: .utf8)
        let index = NoteSearchIndex(root: root)
        let results = await index.search(query: "imported", refresh: true)
        let result = try XCTUnwrap(results?.first)
        let entryValue = await index.entry(id: result.id)
        let entry = try XCTUnwrap(entryValue)
        XCTAssertEqual(entry.id, "file:Project plan.md")
        XCTAssertEqual(entry.path, file.resolvingSymlinksInPath().path)
        let writer = JotWriter(rootURL: root) { _ in }
        let opened = try await writer.openExisting(id: entry.id, path: entry.path, through: 0)
        XCTAssertEqual(opened.text, "# Project plan\nImported Markdown")
    }

    func testCurrentEditorSnapshotAndEmptyNotes() async throws {
        let root = try root()
        try note(root, id: "active", source: "Saved version")
        try note(root, id: "empty", day: "25", source: "")
        let index = NoteSearchIndex(root: root)
        let result = await index.search(query: "unsaved", refresh: true, currentID: "active", currentText: "Current unsaved version")
        XCTAssertEqual(result?.map(\.id), ["active"])
        let saved = await index.search(query: "saved")
        XCTAssertEqual(saved?.map(\.id), ["active"])
        let recent = await index.search(query: "")
        XCTAssertEqual(recent?.last?.title, "Empty note")
    }
}
