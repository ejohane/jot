import XCTest
@testable import Jot

final class NotebookStorageTests: XCTestCase {
    func testUnavailableCloudFileAbortsBeforeAnyDestinationWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let note = source.appendingPathComponent("note.md")
        let remote = source.appendingPathComponent("attachments/remote.png")
        try LocalJotFileSystem().writeAtomically(Data("local source".utf8), to: note)
        do {
            try await NotebookTransfer.copyPrepared(from: source, to: destination, cloudFiles: [remote],
                prepare: { _ in throw NotebookCloudFile.DownloadError.unavailable })
            XCTFail("An incomplete cloud snapshot must not transfer")
        } catch is NotebookCloudFile.DownloadError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: note), Data("local source".utf8))
    }

    func testDownloadedCloudFileIsIncludedInTransfer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let image = source.appendingPathComponent("attachments/remote.png")
        try await NotebookTransfer.copyPrepared(from: source, to: destination, cloudFiles: [image],
            prepare: { url in try LocalJotFileSystem().writeAtomically(Data([7, 8, 9]), to: url) })
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("attachments/remote.png")), Data([7, 8, 9]))
        XCTAssertEqual(try Data(contentsOf: image), Data([7, 8, 9]))
    }

    func testTransferPreservesMarkdownAttachmentsAndSourceAndIsRepeatable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local")
        let destination = root.appendingPathComponent("cloud")
        let markdown = source.appendingPathComponent("2026/10/02/n.md")
        let attachment = source.appendingPathComponent("2026/10/02/attachments/n/photo.png")
        let text = Data("Thought\n\n![Image](attachments/n/photo.png)\n".utf8)
        let image = Data([0, 1, 2, 3])
        try LocalJotFileSystem().writeAtomically(text, to: markdown)
        try LocalJotFileSystem().writeAtomically(image, to: attachment)
        try NotebookTransfer.copy(from: source, to: destination)
        try NotebookTransfer.copy(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: markdown), text)
        XCTAssertEqual(try Data(contentsOf: attachment), image)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("2026/10/02/n.md")), text)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("2026/10/02/attachments/n/photo.png")), image)
    }

    func testConflictingDestinationFailsBeforeCopyingAnyFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local")
        let destination = root.appendingPathComponent("cloud")
        try LocalJotFileSystem().writeAtomically(Data("one".utf8), to: source.appendingPathComponent("a.md"))
        try LocalJotFileSystem().writeAtomically(Data("phone".utf8), to: source.appendingPathComponent("z.md"))
        try LocalJotFileSystem().writeAtomically(Data("mac".utf8), to: destination.appendingPathComponent("z.md"))
        XCTAssertThrowsError(try NotebookTransfer.copy(from: source, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.md").path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("z.md"), encoding: .utf8), "phone")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("z.md"), encoding: .utf8), "mac")
    }

    func testDestinationDirectoryLinkCannotWriteOutsideNotebook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local")
        let destination = root.appendingPathComponent("cloud")
        let outside = root.appendingPathComponent("outside")
        try LocalJotFileSystem().writeAtomically(Data("note".utf8), to: source.appendingPathComponent("day/n.md"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("day"), withDestinationURL: outside)
        XCTAssertThrowsError(try NotebookTransfer.copy(from: source, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("n.md").path))
    }

    func testRejectsNestedRootsAndSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try NotebookTransfer.copy(from: root, to: root.appendingPathComponent("nested")))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: URL(fileURLWithPath: "/tmp/outside.md"))
        XCTAssertThrowsError(try NotebookTransfer.copy(from: root, to: root.appendingPathExtension("copy")))
    }
}
