import Foundation
import XCTest
@testable import Jot

final class InMemoryFileSystem: @unchecked Sendable, JotFileSystem {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private(set) var writes: [(String, Data)] = []
    private(set) var writeDates: [Date] = []
    var writeError: Error?
    private(set) var recoveryCallCount = 0

    func createDirectory(at url: URL) throws {}

    func data(at url: URL) throws -> Data {
        try lock.withLock {
            guard let data = files[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
            return data
        }
    }

    func fileExists(at url: URL) -> Bool { lock.withLock { files[url.path] != nil } }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try lock.withLock {
            if let writeError { throw writeError }
            files[url.path] = data
            writes.append((url.path, data))
            writeDates.append(Date())
        }
    }

    func removeItem(at url: URL) throws { lock.withLock { _ = files.removeValue(forKey: url.path) } }

    func recoverInterruptedAtomicWrite(to url: URL) throws {
        lock.withLock {
            recoveryCallCount += 1
            let temporaryPath = atomicTemporaryURL(for: url).path
            guard let temporaryData = files[temporaryPath] else { return }
            if files[url.path] == nil { files[url.path] = temporaryData }
            files.removeValue(forKey: temporaryPath)
        }
    }

    func replaceExternally(at url: URL, with text: String) {
        lock.withLock { files[url.path] = Data(text.utf8) }
    }

    func deleteExternally(at url: URL) {
        lock.withLock { _ = files.removeValue(forKey: url.path) }
    }

    var fileCount: Int { lock.withLock { files.count } }
    var writeCount: Int { lock.withLock { writes.count } }
    var latestWrittenData: Data? { lock.withLock { writes.last?.1 } }
    var recordedWriteDates: [Date] { lock.withLock { writeDates } }
}

final class DelayedFileSystem: @unchecked Sendable, JotFileSystem {
    private let base = InMemoryFileSystem()
    private let lock = NSLock()
    private var writeNumber = 0
    private let firstWriteStarted = DispatchSemaphore(value: 0)
    private let allowFirstWriteToFinish = DispatchSemaphore(value: 0)

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func data(at url: URL) throws -> Data { try base.data(at: url) }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func recoverInterruptedAtomicWrite(to url: URL) throws { try base.recoverInterruptedAtomicWrite(to: url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let number = lock.withLock {
            writeNumber += 1
            return writeNumber
        }
        if number == 1 {
            firstWriteStarted.signal()
            allowFirstWriteToFinish.wait()
        }
        try base.writeAtomically(data, to: url)
    }

    func waitForFirstWriteToStart() -> Bool {
        firstWriteStarted.wait(timeout: .now() + 2) == .success
    }

    func releaseFirstWrite() { allowFirstWriteToFinish.signal() }
    var writes: [(String, Data)] { base.writes }
}

@MainActor
final class BridgeDelegateSpy: EditorBridgeDelegate {
    var readyCount = 0
    var content: (EditorSnapshot, String?)?
    var state: (EditorSelection, EditorViewport)?
    var preferredHeight: Double?
    var finishRevision: Int?
    var hideRevision: Int?
    var recoveryAction: String?

    func editorDidBecomeReady() { readyCount += 1 }
    func editorContentChanged(_ snapshot: EditorSnapshot, noteID: String?) { content = (snapshot, noteID) }
    func editorStateChanged(selection: EditorSelection, viewport: EditorViewport) { state = (selection, viewport) }
    func editorPreferredHeightChanged(_ height: Double) { preferredHeight = height }
    func editorRequestedFinish(revision: Int) { finishRevision = revision }
    func editorRequestedHide(revision: Int) { hideRevision = revision }
    func editorRequestedRecovery(_ action: String) { recoveryAction = action }
}

final class CoreTests: XCTestCase {
    @MainActor
    func testNativeDragRegionWinsHitTestingWithoutTakingOverTheEditor() {
        let dragView = WindowDragContainerView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))

        XCTAssertTrue(dragView.mouseDownCanMoveWindow)
        XCTAssertTrue(dragView.acceptsFirstMouse(for: nil))
        XCTAssertFalse(dragView.isAccessibilityElement())

        let controller = ComposerPanelController(savedFrame: nil)
        XCTAssertEqual(controller.window?.isMovable, true)
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Composer panel has no content view")
        }
        contentView.layoutSubtreeIfNeeded()
        let dragPoint = NSPoint(x: 300, y: contentView.bounds.maxY - 10)
        let editorPoint = NSPoint(x: 300, y: contentView.bounds.maxY - 50)
        XCTAssertTrue(contentView.hitTest(dragPoint) === contentView)
        XCTAssertFalse(contentView.hitTest(editorPoint) === contentView)
    }

    @MainActor
    func testPreferredHeightClampsExpandedPanelToVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_800, height: 1_130)
        let expandedFromBottomEdge = NSRect(x: 0, y: -440, width: 560, height: 700)

        XCTAssertEqual(
            ComposerPanelController.clampedFrame(expandedFromBottomEdge, to: visibleFrame),
            NSRect(x: 0, y: 0, width: 560, height: 700)
        )
    }

    @MainActor
    func testFinishAndNewMenuRequiresWritableActiveJot() {
        let active = ActiveJot(id: "active", path: "/Jots/active.md", acknowledgedRevision: 1)
        XCTAssertFalse(AppCoordinator.finishAndNewIsEnabled(activeJot: nil, hasBlockingWriteError: false))
        XCTAssertFalse(AppCoordinator.finishAndNewIsEnabled(activeJot: active, hasBlockingWriteError: true))
        XCTAssertTrue(AppCoordinator.finishAndNewIsEnabled(activeJot: active, hasBlockingWriteError: false))
    }

    @MainActor
    func testTerminationRequiresDurableSessionAndEitherCanonicalOrRecoveryText() {
        XCTAssertTrue(AppCoordinator.mayTerminate(flushed: true, savedRecovery: true, hasRecoveryText: false))
        XCTAssertTrue(AppCoordinator.mayTerminate(flushed: false, savedRecovery: true, hasRecoveryText: true))
        XCTAssertFalse(AppCoordinator.mayTerminate(flushed: true, savedRecovery: false, hasRecoveryText: true))
        XCTAssertFalse(AppCoordinator.mayTerminate(flushed: false, savedRecovery: true, hasRecoveryText: false))
        XCTAssertFalse(AppCoordinator.mayTerminate(flushed: false, savedRecovery: false, hasRecoveryText: true))
    }

    func testULIDIsCanonicalAndDeterministicWithSuppliedEntropy() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ULID.make(timestamp: date, randomBytes: Array(repeating: 7, count: 10))
        let second = ULID.make(timestamp: date, randomBytes: Array(repeating: 7, count: 10))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 26)
        XCTAssertNotNil(first.range(of: "^[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression))
    }

    func testAllocationUsesLocalDateShardAndStableIdentifier() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -6 * 3_600)!
        let date = Date(timeIntervalSince1970: 1_758_468_138.391)
        let allocation = JotPathAllocator(calendar: calendar).allocate(
            root: URL(fileURLWithPath: "/Jots"),
            at: date,
            id: "01K5R8T7Q95W6E3G9A7D2P4M6N"
        )
        XCTAssertTrue(allocation.fileURL.path.hasSuffix("/2025/09/21/09-22-18-391--01K5R8T7Q95W6E3G9A7D2P4M6N.md"))
    }

    @MainActor
    func testBlankMutationDoesNotAllocateAFile() async {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: ""))
        let currentJot = await writer.currentJot()
        XCTAssertNil(currentJot)
        XCTAssertTrue(fileSystem.writes.isEmpty)
    }

    @MainActor
    func testFinishAndNewOnBlankDoesNotAllocateAFile() async {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        let didFinish = await writer.finishAndNew(through: 0)
        let currentJot = await writer.currentJot()
        XCTAssertTrue(didFinish)
        XCTAssertNil(currentJot)
        XCTAssertEqual(fileSystem.writeCount, 0)
    }

    @MainActor
    func testFirstMutationAllocatesAndWritesExactUTF8() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        let text = "# Hello\n\nUnfinished **text 📝"
        await writer.receive(snapshot(revision: 1, text: text))
        let currentJot = await writer.currentJot()
        let jot = try XCTUnwrap(currentJot)
        XCTAssertEqual(try fileSystem.data(at: URL(fileURLWithPath: jot.path)), Data(text.utf8))
        XCTAssertEqual(jot.acknowledgedRevision, 1)
    }

    @MainActor
    func testFinishAndNewFlushesLatestRevisionBeforeRelease() async {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: "first"))
        let path = await writer.currentJot()!.path
        await writer.receive(snapshot(revision: 2, text: "latest"))
        let didFinish = await writer.finishAndNew(through: 2)
        let currentJot = await writer.currentJot()
        XCTAssertTrue(didFinish)
        XCTAssertNil(currentJot)
        XCTAssertEqual(String(data: try! fileSystem.data(at: URL(fileURLWithPath: path)), encoding: .utf8), "latest")
    }

    @MainActor
    func testRapidPendingEditsCoalesceToNewestSnapshot() async throws {
        let fileSystem = InMemoryFileSystem()
        let saved = expectation(description: "Newest coalesced revision is durably saved")
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { event in
            if case .writeSucceeded(_, 4) = event { saved.fulfill() }
        }
        await writer.receive(snapshot(revision: 1, text: "1"))
        await writer.receive(snapshot(revision: 2, text: "12"))
        await writer.receive(snapshot(revision: 3, text: "123"))
        await writer.receive(snapshot(revision: 4, text: "1234"))
        // Wait for the writer's acknowledgement, not a guessed scheduling delay.
        let result = await XCTWaiter.fulfillment(of: [saved], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fileSystem.writeCount, 2)
        XCTAssertEqual(fileSystem.latestWrittenData, Data("1234".utf8))
        let acknowledgedRevision = await writer.currentJot()?.acknowledgedRevision
        XCTAssertEqual(acknowledgedRevision, 4)
    }

    @MainActor
    func testSustainedTypingWritesAtLeastOncePerSecond() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        for revision in 1...100 {
            await writer.receive(snapshot(revision: revision, text: String(repeating: "x", count: revision)))
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = await writer.flush(through: 100)
        let writeDates = fileSystem.recordedWriteDates
        XCTAssertGreaterThanOrEqual(writeDates.count, 3)
        let maximumGap = zip(writeDates, writeDates.dropFirst()).map { $1.timeIntervalSince($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximumGap, 1.15)
        XCTAssertEqual(fileSystem.latestWrittenData, Data(String(repeating: "x", count: 100).utf8))
    }

    @MainActor
    func testCreatedJotRemainsWhenEditedToEmpty() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: "created"))
        let currentJot = await writer.currentJot()
        let jot = try XCTUnwrap(currentJot)
        await writer.receive(snapshot(revision: 2, text: ""), flushImmediately: true)
        XCTAssertTrue(fileSystem.fileExists(at: URL(fileURLWithPath: jot.path)))
        XCTAssertEqual(try fileSystem.data(at: URL(fileURLWithPath: jot.path)), Data())
    }

    @MainActor
    func testChangingRootKeepsActiveJotAndUsesNewRootForNextJot() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Original"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: "original"))
        let originalValue = await writer.currentJot()
        let original = try XCTUnwrap(originalValue)
        XCTAssertTrue(original.path.hasPrefix("/Original/"))

        await writer.configureRoot(URL(fileURLWithPath: "/New"))
        await writer.receive(snapshot(revision: 2, text: "original updated"), flushImmediately: true)
        let activePath = await writer.currentJot()?.path
        XCTAssertEqual(activePath, original.path)
        XCTAssertEqual(try fileSystem.data(at: URL(fileURLWithPath: original.path)), Data("original updated".utf8))

        let didFinish = await writer.finishAndNew(through: 2)
        XCTAssertTrue(didFinish)
        await writer.receive(snapshot(revision: 1, text: "next"))
        let nextValue = await writer.currentJot()
        let next = try XCTUnwrap(nextValue)
        XCTAssertTrue(next.path.hasPrefix("/New/"))
        XCTAssertNotEqual(next.path, original.path)
    }

    @MainActor
    func testStaleRevisionCannotOverwriteNewerRevision() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 3, text: "newest"), flushImmediately: true)
        await writer.receive(snapshot(revision: 2, text: "stale"), flushImmediately: true)
        let jotValue = await writer.currentJot()
        let jot = try XCTUnwrap(jotValue)
        XCTAssertEqual(jot.acknowledgedRevision, 3)
        XCTAssertEqual(try fileSystem.data(at: URL(fileURLWithPath: jot.path)), Data("newest".utf8))
    }

    @MainActor
    func testDelayedInFlightWriteSerializesNewerRevisionAndPersistsNewestBytes() async throws {
        let fileSystem = DelayedFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }

        let first = Task { await writer.receive(snapshot(revision: 1, text: "delayed"), flushImmediately: true) }
        let firstDidStart = await Task.detached { fileSystem.waitForFirstWriteToStart() }.value
        XCTAssertTrue(firstDidStart)

        let newer = Task { await writer.receive(snapshot(revision: 2, text: "newest"), flushImmediately: true) }
        try await Task.sleep(for: .milliseconds(50))
        fileSystem.releaseFirstWrite()
        await first.value
        await newer.value

        let currentJot = await writer.currentJot()
        let jot = try XCTUnwrap(currentJot)
        XCTAssertEqual(jot.acknowledgedRevision, 2)
        XCTAssertEqual(fileSystem.writes.map(\.1), [Data("delayed".utf8), Data("newest".utf8)])
        XCTAssertEqual(try fileSystem.data(at: URL(fileURLWithPath: jot.path)), Data("newest".utf8))
    }

    @MainActor
    func testNativeBridgeDecodesVersionedNSNumberPayloadsAndRejectsObsoleteVersions() throws {
        let bridge = EditorBridge()
        let delegate = BridgeDelegateSpy()
        bridge.delegate = delegate

        bridge.handle(["version": NSNumber(value: 2), "type": "editorReady"] as NSDictionary)
        XCTAssertEqual(delegate.readyCount, 0)

        bridge.handle(["version": NSNumber(value: 1), "type": "editorReady"] as NSDictionary)
        bridge.handle([
            "version": NSNumber(value: 1),
            "type": "contentChanged",
            "noteID": "note-7",
            "revision": NSNumber(value: 9),
            "text": "exact 📝",
            "selection": ["anchor": NSNumber(value: 2), "head": NSNumber(value: 6)],
            "viewport": ["scrollTop": NSNumber(value: 42.5)],
        ] as NSDictionary)
        bridge.handle([
            "version": NSNumber(value: 1),
            "type": "editorStateChanged",
            "selection": ["anchor": NSNumber(value: 3), "head": NSNumber(value: 4)],
            "viewport": ["scrollTop": NSNumber(value: 12.25)],
        ] as NSDictionary)
        bridge.handle(["version": 1, "type": "preferredHeightChanged", "height": NSNumber(value: 333.5)] as NSDictionary)
        bridge.handle(["version": 1, "type": "finishAndNew", "revision": NSNumber(value: 9)] as NSDictionary)
        bridge.handle(["version": 1, "type": "hide", "revision": NSNumber(value: 10)] as NSDictionary)
        bridge.handle(["version": 1, "type": "recover", "action": "saveCopy"] as NSDictionary)

        XCTAssertEqual(delegate.readyCount, 1)
        let content = try XCTUnwrap(delegate.content)
        XCTAssertEqual(content.0.revision, 9)
        XCTAssertEqual(content.0.text, "exact 📝")
        XCTAssertEqual(content.0.selection, EditorSelection(anchor: 2, head: 6))
        XCTAssertEqual(content.0.viewport, EditorViewport(scrollTop: 42.5))
        XCTAssertEqual(content.1, "note-7")
        XCTAssertEqual(delegate.state?.0, EditorSelection(anchor: 3, head: 4))
        XCTAssertEqual(delegate.state?.1, EditorViewport(scrollTop: 12.25))
        XCTAssertEqual(delegate.preferredHeight, 333.5)
        XCTAssertEqual(delegate.finishRevision, 9)
        XCTAssertEqual(delegate.hideRevision, 10)
        XCTAssertEqual(delegate.recoveryAction, "saveCopy")
    }

    @MainActor
    func testChoosingRootAfterFailureFlushesRetainedBuffer() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: nil, fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: "retained"))
        let failedBeforeRecovery = await writer.hasBlockingError
        XCTAssertTrue(failedBeforeRecovery)
        await writer.configureRoot(URL(fileURLWithPath: "/Recovered"))
        let didFlush = await writer.flush(through: 1)
        let currentJot = await writer.currentJot()
        XCTAssertTrue(didFlush)
        let jot = try XCTUnwrap(currentJot)
        XCTAssertEqual(try fileSystem.data(at: URL(fileURLWithPath: jot.path)), Data("retained".utf8))
    }

    @MainActor
    func testRestoredRecoveryBufferFlushesAfterFolderAccessReturns() async throws {
        let fileSystem = InMemoryFileSystem()
        let existing = ActiveJot(id: "existing", path: "/Jots/existing.md", acknowledgedRevision: 7)
        fileSystem.replaceExternally(at: URL(fileURLWithPath: existing.path), with: "acknowledged")
        let writer = JotWriter(rootURL: nil, fileSystem: fileSystem) { _ in }

        let restored = await writer.restoreWithoutFileAccess(
            existing,
            recoveryText: "acknowledged",
            recoveryRevision: 7
        )
        XCTAssertEqual(restored, "acknowledged")
        await writer.receive(snapshot(revision: 8, text: "edited while unavailable"))
        await writer.configureRoot(URL(fileURLWithPath: "/Jots"))
        let flushed = await writer.flush(through: 8)

        XCTAssertTrue(flushed)
        XCTAssertEqual(
            try fileSystem.data(at: URL(fileURLWithPath: existing.path)),
            Data("edited while unavailable".utf8)
        )
    }

    @MainActor
    func testWriteFailurePreventsFinishAndNew() async {
        let fileSystem = InMemoryFileSystem()
        fileSystem.writeError = CocoaError(.fileWriteOutOfSpace)
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: "must survive"))
        let hasBlockingError = await writer.hasBlockingError
        let didFinish = await writer.finishAndNew(through: 1)
        let currentJot = await writer.currentJot()
        XCTAssertTrue(hasBlockingError)
        XCTAssertFalse(didFinish)
        XCTAssertNotNil(currentJot)
    }

    @MainActor
    func testAtomicReplacementFailurePreventsAcknowledgementAndFinish() async {
        let fileSystem = InMemoryFileSystem()
        fileSystem.writeError = POSIXError(.EIO)
        var succeededRevisions: [Int] = []
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { event in
            if case let .writeSucceeded(_, revision) = event { succeededRevisions.append(revision) }
        }
        await writer.receive(snapshot(revision: 1, text: "must survive"))
        await Task.yield()
        let didFinish = await writer.finishAndNew(through: 1)
        let currentJot = await writer.currentJot()
        XCTAssertTrue(succeededRevisions.isEmpty)
        XCTAssertFalse(didFinish)
        XCTAssertNotNil(currentJot)
    }

    @MainActor
    func testExternalModificationStopsOverwrite() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: "mine"))
        let currentJot = await writer.currentJot()
        let jot = try XCTUnwrap(currentJot)
        let url = URL(fileURLWithPath: jot.path)
        fileSystem.replaceExternally(at: url, with: "external")
        await writer.receive(snapshot(revision: 2, text: "mine newer"), flushImmediately: true)
        let hasBlockingError = await writer.hasBlockingError
        let didFinish = await writer.finishAndNew(through: 2)
        XCTAssertTrue(hasBlockingError)
        XCTAssertFalse(didFinish)
        XCTAssertEqual(String(data: try fileSystem.data(at: url), encoding: .utf8), "external")
    }

    @MainActor
    func testSaveAsCopyPreservesExternalVersion() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: "mine"))
        let currentJot = await writer.currentJot()
        let original = try XCTUnwrap(currentJot)
        let originalURL = URL(fileURLWithPath: original.path)
        fileSystem.replaceExternally(at: originalURL, with: "external")
        await writer.receive(snapshot(revision: 2, text: "mine newer"), flushImmediately: true)
        let copiedJot = await writer.saveCurrentVersionAsCopy()
        let copy = try XCTUnwrap(copiedJot)
        XCTAssertNotEqual(copy.path, original.path)
        XCTAssertEqual(String(data: try fileSystem.data(at: originalURL), encoding: .utf8), "external")
        XCTAssertEqual(String(data: try fileSystem.data(at: URL(fileURLWithPath: copy.path)), encoding: .utf8), "mine newer")
    }

    @MainActor
    func testSaveAsCopyReportsFailureUntilCopyIsDurable() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: "mine"))
        let originalValue = await writer.currentJot()
        let original = try XCTUnwrap(originalValue)
        let originalURL = URL(fileURLWithPath: original.path)
        fileSystem.replaceExternally(at: originalURL, with: "external")
        await writer.receive(snapshot(revision: 2, text: "mine newer"), flushImmediately: true)
        fileSystem.writeError = POSIXError(.EIO)

        let copy = await writer.saveCurrentVersionAsCopy()
        let hasBlockingError = await writer.hasBlockingError
        let currentJot = await writer.currentJot()

        XCTAssertNil(copy)
        XCTAssertTrue(hasBlockingError)
        XCTAssertEqual(currentJot?.path, original.path)
        XCTAssertEqual(try fileSystem.data(at: originalURL), Data("external".utf8))
    }

    @MainActor
    func testExplicitReloadAdoptsExternalVersion() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: "mine"))
        let currentJot = await writer.currentJot()
        let original = try XCTUnwrap(currentJot)
        let url = URL(fileURLWithPath: original.path)
        fileSystem.replaceExternally(at: url, with: "external")
        await writer.receive(snapshot(revision: 2, text: "mine newer"), flushImmediately: true)
        let reloaded = try await writer.reloadExternalVersion()
        XCTAssertEqual(reloaded.text, "external")
        XCTAssertGreaterThan(reloaded.jot.acknowledgedRevision, 2)
        let hasBlockingError = await writer.hasBlockingError
        XCTAssertFalse(hasBlockingError)
    }

    @MainActor
    func testMissingRestoredFileUsesRecoveryBufferWithoutRecreatingDeletedPath() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        let missing = ActiveJot(id: "missing", path: "/Jots/missing.md", acknowledgedRevision: 7)
        do {
            _ = try await writer.restore(missing, recoveryText: "recovered", recoveryRevision: 8)
            XCTFail("Restore should report the missing canonical file")
        } catch PersistenceError.activeFileMissing {
            // Expected.
        }
        await writer.receive(snapshot(revision: 9, text: "recovered newer"), flushImmediately: true)
        XCTAssertFalse(fileSystem.fileExists(at: URL(fileURLWithPath: missing.path)))
        let copiedJot = await writer.saveCurrentVersionAsCopy()
        let copied = try XCTUnwrap(copiedJot)
        XCTAssertNotEqual(copied.path, missing.path)
        XCTAssertEqual(try fileSystem.data(at: URL(fileURLWithPath: copied.path)), Data("recovered newer".utf8))
    }

    @MainActor
    func testExternalDeletionDuringEditingRequiresCopyAndDoesNotRecreateDeletedPath() async throws {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(snapshot(revision: 1, text: "before deletion"))
        let originalValue = await writer.currentJot()
        let original = try XCTUnwrap(originalValue)
        let originalURL = URL(fileURLWithPath: original.path)
        fileSystem.deleteExternally(at: originalURL)

        await writer.receive(snapshot(revision: 2, text: "recovered in memory"), flushImmediately: true)
        let hasBlockingError = await writer.hasBlockingError
        let didFinish = await writer.finishAndNew(through: 2)
        XCTAssertFalse(fileSystem.fileExists(at: originalURL))
        XCTAssertTrue(hasBlockingError)
        XCTAssertFalse(didFinish)

        let copyValue = await writer.saveCurrentVersionAsCopy()
        let copy = try XCTUnwrap(copyValue)
        XCTAssertNotEqual(copy.path, original.path)
        XCTAssertFalse(fileSystem.fileExists(at: originalURL))
        XCTAssertEqual(try fileSystem.data(at: URL(fileURLWithPath: copy.path)), Data("recovered in memory".utf8))
    }

    @MainActor
    func testInterruptedTemporaryFileRecoversMissingCanonicalFile() async throws {
        let fileSystem = InMemoryFileSystem()
        let canonicalURL = URL(fileURLWithPath: "/Jots/2026/09/21/example.md")
        let temporaryURL = atomicTemporaryURL(for: canonicalURL)
        fileSystem.replaceExternally(at: temporaryURL, with: "durable interrupted bytes")
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        let text = try await writer.restore(
            ActiveJot(id: "example", path: canonicalURL.path, acknowledgedRevision: 4)
        )
        XCTAssertEqual(text, "durable interrupted bytes")
        XCTAssertEqual(try fileSystem.data(at: canonicalURL), Data("durable interrupted bytes".utf8))
        XCTAssertFalse(fileSystem.fileExists(at: temporaryURL))
    }

    @MainActor
    func testStaleTemporaryFileNeverOverwritesExistingCanonicalFile() async throws {
        let fileSystem = InMemoryFileSystem()
        let canonicalURL = URL(fileURLWithPath: "/Jots/2026/09/21/example.md")
        let temporaryURL = atomicTemporaryURL(for: canonicalURL)
        fileSystem.replaceExternally(at: canonicalURL, with: "canonical")
        fileSystem.replaceExternally(at: temporaryURL, with: "stale temp")
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }

        let text = try await writer.restore(ActiveJot(id: "example", path: canonicalURL.path, acknowledgedRevision: 4))
        XCTAssertEqual(text, "canonical")
        XCTAssertEqual(try fileSystem.data(at: canonicalURL), Data("canonical".utf8))
        XCTAssertFalse(fileSystem.fileExists(at: temporaryURL))
    }

    func testSessionStoreRoundTripsApplicationSupportState() async throws {
        let fileSystem = InMemoryFileSystem()
        let url = URL(fileURLWithPath: "/Application Support/Jot/session.json")
        let store = SessionStore(fileURL: url, fileSystem: fileSystem)
        var expected = PersistedSession.empty
        expected.activeJot = ActiveJot(id: "id", path: "/Jots/a.md", acknowledgedRevision: 42)
        expected.selection = EditorSelection(anchor: 4, head: 9)
        expected.viewport = EditorViewport(scrollTop: 123)
        expected.panelFrame = "{{10, 20}, {560, 260}}"
        try await store.save(expected)
        let actual = await store.load()
        XCTAssertEqual(actual, expected)
    }

    func testStaleSessionGenerationCannotOverwriteNewerState() async throws {
        let fileSystem = InMemoryFileSystem()
        let store = SessionStore(fileURL: URL(fileURLWithPath: "/Application Support/Jot/session.json"), fileSystem: fileSystem)
        var old = PersistedSession.empty
        old.activeJot = ActiveJot(id: "old", path: "/Jots/old.md", acknowledgedRevision: 1)
        var new = PersistedSession.empty
        new.activeJot = ActiveJot(id: "new", path: "/Jots/new.md", acknowledgedRevision: 2)
        try await store.save(new, generation: 2)
        try await store.save(old, generation: 1)
        let restored = await store.load()
        XCTAssertEqual(restored.activeJot?.id, "new")
    }

    func testSessionStoreLoadsPreRecoverySchema() async throws {
        let fileSystem = InMemoryFileSystem()
        let url = URL(fileURLWithPath: "/Application Support/Jot/session.json")
        fileSystem.replaceExternally(at: url, with: """
        {
          "activeJot": null,
          "selection": {"anchor": 0, "head": 0},
          "viewport": {"scrollTop": 0},
          "shortcut": "optionSpace",
          "launchAtLogin": false
        }
        """)
        let session = await SessionStore(fileURL: url, fileSystem: fileSystem).load()
        XCTAssertNil(session.recoveryText)
        XCTAssertNil(session.recoveryRevision)
    }

    func testTenThousandAllocationsWithSameTimestampAreUnique() {
        let allocator = JotPathAllocator(calendar: Calendar(identifier: .gregorian))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let fileSystem = InMemoryFileSystem()
        let paths = Set((0..<10_000).map { index in
            let allocation = allocator.allocate(root: URL(fileURLWithPath: "/Jots"), at: timestamp)
            try! fileSystem.writeAtomically(Data("\(index)".utf8), to: allocation.fileURL)
            return allocation.fileURL.path
        })
        XCTAssertEqual(paths.count, 10_000)
        XCTAssertEqual(fileSystem.fileCount, 10_000)
    }

    private func snapshot(revision: Int, text: String) -> EditorSnapshot {
        EditorSnapshot(revision: revision, text: text, selection: .start, viewport: .top)
    }

}
