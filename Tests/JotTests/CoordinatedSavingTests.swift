import XCTest
@testable import Jot

final class CoordinatedSavingTests: XCTestCase {
    func testConcurrentWritersCannotBothReplaceTheSameBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("note.md")
        let baseline = Data("original".utf8)
        try LocalJotFileSystem().writeAtomically(baseline, to: url)
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for text in ["phone", "mac"] {
                group.addTask {
                    do {
                        try LocalJotFileSystem().writeIfUnchanged(Data(text.utf8), to: url, expected: baseline)
                        return true
                    } catch { return false }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertTrue(["phone", "mac"].contains(try String(contentsOf: url, encoding: .utf8)))
    }

    func testConflictCopyFromAnotherDayKeepsRelativeImageLinksUsable() async throws {
        let files = InMemoryFileSystem()
        let noteURL = URL(fileURLWithPath: "/Jots/2025/01/01/12-00-00-000--original.md")
        let attachment = noteURL.deletingLastPathComponent().appendingPathComponent("attachments/original/photo.png")
        let markdown = "![Image](attachments/original/photo.png)\nMy writing"
        try files.writeAtomically(Data(markdown.utf8), to: noteURL)
        try files.writeAtomically(Data([1, 2, 3]), to: attachment)
        let memoryWriter = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: files) { _ in }
        _ = try await memoryWriter.restore(ActiveJot(id: "original", path: noteURL.path, acknowledgedRevision: 0))
        files.replaceExternally(at: noteURL, with: "Remote version")
        await memoryWriter.receive(EditorSnapshot(revision: 1, text: markdown + " locally edited", selection: .start, viewport: .top), flushImmediately: true)
        let saved = await memoryWriter.saveCurrentVersionAsCopy()
        let copy = try XCTUnwrap(saved)
        let copyURL = URL(fileURLWithPath: copy.path)
        XCTAssertEqual(try files.data(at: attachment), Data([1, 2, 3]))
        XCTAssertEqual(try files.data(at: copyURL.deletingLastPathComponent().appendingPathComponent("attachments/original/photo.png")), Data([1, 2, 3]))
        XCTAssertEqual(try files.data(at: copyURL), Data((markdown + " locally edited").utf8))
        XCTAssertEqual(try files.data(at: noteURL), Data("Remote version".utf8))
    }

    func testMissingAndNewFilesDoNotOverwriteUnexpectedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("note.md")
        XCTAssertThrowsError(try LocalJotFileSystem().writeIfUnchanged(Data("new".utf8), to: url, expected: Data("old".utf8))) {
            XCTAssertEqual($0 as? PersistenceError, .activeFileMissing)
        }
        try LocalJotFileSystem().writeIfUnchanged(Data("original".utf8), to: url, expected: nil)
        XCTAssertThrowsError(try LocalJotFileSystem().writeIfUnchanged(Data("replacement".utf8), to: url, expected: nil)) {
            XCTAssertEqual($0 as? PersistenceError, .externalConflict)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }
}
