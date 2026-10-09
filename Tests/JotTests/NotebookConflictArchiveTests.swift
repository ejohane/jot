import Foundation
import XCTest
@testable import Jot

final class NotebookConflictArchiveTests: XCTestCase {
    func testConflictCopyPreservesBytesAndRelativeImageDirectoryAndRetriesOnce() throws {
        let files = InMemoryFileSystem()
        let original = URL(fileURLWithPath: "/Jots/2025/01/02/06-00-00-000--original.md")
        files.replaceExternally(at: original, with: "Current version")
        let bytes = Data("Old version\n![photo](attachments/original/photo.png)".utf8)
        var resolutions = 0
        let copy = try NotebookConflictArchive.preserve(source: original, fileSystem: files,
            read: { bytes }, resolve: { resolutions += 1 })
        let retry = try NotebookConflictArchive.preserve(source: original, fileSystem: files,
            read: { bytes }, resolve: { resolutions += 1 })
        XCTAssertEqual(copy, retry)
        XCTAssertEqual(copy.deletingLastPathComponent(), original.deletingLastPathComponent())
        XCTAssertEqual(try files.data(at: copy), bytes)
        XCTAssertEqual(try files.data(at: original), Data("Current version".utf8))
        XCTAssertEqual(files.writes.count, 1)
        XCTAssertEqual(resolutions, 2)
    }

    func testFailedCopyNeverAcknowledgesResolution() throws {
        let files = InMemoryFileSystem()
        files.writeError = CocoaError(.fileWriteOutOfSpace)
        var resolved = false
        XCTAssertThrowsError(try NotebookConflictArchive.preserve(source: URL(fileURLWithPath: "/Jots/n.md"), fileSystem: files,
            read: { Data("conflict".utf8) }, resolve: { resolved = true }))
        XCTAssertFalse(resolved)
    }

    func testDistinctConflictsReceiveDistinctPaths() throws {
        let files = InMemoryFileSystem()
        let original = URL(fileURLWithPath: "/Jots/n.md")
        let first = try NotebookConflictArchive.preserve(source: original, fileSystem: files, read: { Data("first".utf8) }, resolve: {})
        let second = try NotebookConflictArchive.preserve(source: original, fileSystem: files, read: { Data("second".utf8) }, resolve: {})
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try files.data(at: first), Data("first".utf8))
        XCTAssertEqual(try files.data(at: second), Data("second".utf8))
    }
}
