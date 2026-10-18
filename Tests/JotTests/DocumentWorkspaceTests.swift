import AppKit
import XCTest
@testable import Jot

@MainActor
final class DocumentWorkspaceTests: XCTestCase {
    private func fixture() throws -> (URL, URL, DocumentWorkspaceStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jot-doc-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("project/README.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Original\n\nUnicode: å 👋\n".utf8).write(to: file)
        return (root, file, DocumentWorkspaceStore(fileURL: root.appendingPathComponent("windows.json")))
    }

    private func snapshot(_ text: String, revision: Int = 1) -> EditorSnapshot {
        EditorSnapshot(revision: revision, text: text, selection: EditorSelection(anchor: 2, head: 5), viewport: EditorViewport(scrollTop: 123))
    }

    func testEditWritesExactOriginalAndDoesNotImportOrCreateSibling() async throws {
        let (_, file, store) = try fixture()
        let document = try MarkdownDocument.open(file, store: store)
        _ = try await document.restore()
        let text = "---\ntitle: Keep source\n---\n# Edited å 👋\r\n"
        try await document.receive(snapshot(text))
        XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["README.md"])
        let state = await document.state
        XCTAssertEqual(state.path, file.path)
        XCTAssertEqual(state.revision, state.acknowledgedRevision)
    }

    func testTwoFilesSaveIndependentlyAndRestorePositionsAndFrame() async throws {
        let (root, file, store) = try fixture()
        let other = root.appendingPathComponent("other.markdown")
        try Data("Other".utf8).write(to: other)
        let first = try MarkdownDocument.open(file, store: store)
        let second = try MarkdownDocument.open(other, store: store)
        _ = try await first.restore(); _ = try await second.restore()
        try await first.receive(snapshot("First"))
        try await second.receive(snapshot("Second"))
        let selection = EditorSelection(anchor: 3, head: 3)
        try await first.position(selection: selection, viewport: EditorViewport(scrollTop: 456), frame: "{{10, 20}, {620, 540}}")
        let restored = try await DocumentWorkspaceStore(fileURL: root.appendingPathComponent("windows.json")).load()
        XCTAssertEqual(restored.count, 2)
        let state = try XCTUnwrap(restored.first { $0.path == file.path })
        XCTAssertEqual(state.selection, selection)
        XCTAssertEqual(state.viewport.scrollTop, 456)
        XCTAssertEqual(state.frame, "{{10, 20}, {620, 540}}")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "Second")
        try await second.close()
        let remaining = try await store.load()
        XCTAssertEqual(remaining.map(\.path), [file.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testOutsideChangesReloadAndNextEditUsesNewBaseline() async throws {
        let (_, file, store) = try fixture()
        let document = try MarkdownDocument.open(file, store: store)
        _ = try await document.restore()
        try Data("Outside edit".utf8).write(to: file, options: .atomic)
        let changed = try await document.reconcile()
        XCTAssertTrue(changed)
        let external = await document.state
        XCTAssertEqual(external.text, "Outside edit")
        try await document.receive(snapshot("Outside edit + Jot", revision: external.revision + 1))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Outside edit + Jot")
    }

    func testConflictPreservesOutsideFileAndJournalThenKeepsBoth() async throws {
        let (root, file, store) = try fixture()
        let document = try MarkdownDocument.open(file, store: store)
        _ = try await document.restore()
        try Data("Outside wins no overwrite".utf8).write(to: file)
        do { try await document.receive(snapshot("My pending edit")); XCTFail("Expected conflict") }
        catch { XCTAssertEqual(error as? PersistenceError, .externalConflict) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Outside wins no overwrite")
        let journal = try await DocumentWorkspaceStore(fileURL: root.appendingPathComponent("windows.json")).load()
        XCTAssertEqual(journal.first?.text, "My pending edit")
        let copy = try await document.keepBothAndReload()
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "My pending edit")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Outside wins no overwrite")
        let state = await document.state
        XCTAssertEqual(state.text, "Outside wins no overwrite")
    }

    func testConflictSurvivesRelaunchWithoutOverwritingEitherVersion() async throws {
        let (root, file, store) = try fixture()
        let document = try MarkdownDocument.open(file, store: store)
        _ = try await document.restore()
        try Data("Outside".utf8).write(to: file)
        do { try await document.receive(snapshot("Mine")); XCTFail("Expected conflict") } catch {}
        let newStore = DocumentWorkspaceStore(fileURL: root.appendingPathComponent("windows.json"))
        let states = try await newStore.load()
        let restored = MarkdownDocument(state: try XCTUnwrap(states.first), store: newStore)
        do { _ = try await restored.restore(); XCTFail("Expected conflict") } catch {}
        let state = await restored.state
        XCTAssertEqual(state.text, "Mine")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Outside")
    }

    func testMissingFileIsNotRecreatedAndCloseIsBlocked() async throws {
        let (_, file, store) = try fixture()
        let document = try MarkdownDocument.open(file, store: store)
        _ = try await document.restore()
        try FileManager.default.removeItem(at: file)
        do { try await document.receive(snapshot("Keep me")); XCTFail("Expected missing file") }
        catch { XCTAssertEqual(error as? PersistenceError, .activeFileMissing) }
        do { try await document.close(); XCTFail("Close must not lose pending text") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let saved = try await store.load()
        XCTAssertEqual(saved.first?.text, "Keep me")
    }

    func testJournalFailureStopsCanonicalWrite() async throws {
        let (_, file, _) = try fixture()
        let files = InMemoryFileSystem()
        files.writeError = CocoaError(.fileWriteOutOfSpace)
        let store = DocumentWorkspaceStore(fileURL: URL(fileURLWithPath: "/state.json"), fileSystem: files)
        let document = try MarkdownDocument.open(file, store: store)
        let before = try Data(contentsOf: file)
        do { try await document.receive(snapshot("Must not write")); XCTFail("Expected journal failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testSymlinkAndDotPathsIdentifySameFileAndUnsupportedFilesFail() throws {
        let (root, file, store) = try fixture()
        let alias = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        XCTAssertEqual(MarkdownFile.canonicalURL(alias), MarkdownFile.canonicalURL(file))
        XCTAssertEqual(MarkdownFile.canonicalURL(file.deletingLastPathComponent().appendingPathComponent("./README.md")), MarkdownFile.canonicalURL(file))
        XCTAssertThrowsError(try MarkdownDocument.open(root.appendingPathComponent("data.pdf"), store: store))
    }

    func testOriginalFilePermissionsSurviveAutosave() async throws {
        let (_, file, store) = try fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let document = try MarkdownDocument.open(file, store: store)
        _ = try await document.restore()
        try await document.receive(snapshot("Private Markdown"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testReadOnlyOriginalKeepsCanonicalBytesAndJournalsWriting() async throws {
        let (_, file, store) = try fixture()
        let document = try MarkdownDocument.open(file, store: store)
        _ = try await document.restore()
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        do { try await document.receive(snapshot("Keep read-only edit")); XCTFail("Expected permission failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), before)
        let saved = try await store.load()
        XCTAssertEqual(saved.first?.text, "Keep read-only edit")
    }

    func testRelativeImagesStayInsideDocumentFolder() {
        let root = URL(fileURLWithPath: "/tmp/project")
        XCTAssertNotNil(LocalResourceSchemeHandler.attachmentURL(path: "images/chart.png", root: root, documentImages: true))
        XCTAssertNil(LocalResourceSchemeHandler.attachmentURL(path: "../private.png", root: root, documentImages: true))
        XCTAssertNil(LocalResourceSchemeHandler.attachmentURL(path: "script.html", root: root, documentImages: true))
    }
}
