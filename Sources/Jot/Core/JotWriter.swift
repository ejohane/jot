import Foundation

actor JotWriter {
    typealias EventHandler = @MainActor @Sendable (WriterEvent) -> Void

    private let fileSystem: any JotFileSystem
    private let allocator: JotPathAllocator
    private let now: @Sendable () -> Date
    private let eventHandler: EventHandler

    private var rootURL: URL?
    private var activeJot: ActiveJot?
    private var lastWrittenData: Data?
    private var latestSnapshot: EditorSnapshot?
    private var activeFileWasMissing = false
    private var idleTask: Task<Void, Never>?
    private var sustainedTask: Task<Void, Never>?
    private var lastWriteStartedAt = Date.distantPast
    private(set) var hasBlockingError = false

    init(
        rootURL: URL?,
        fileSystem: any JotFileSystem = LocalJotFileSystem(),
        allocator: JotPathAllocator = JotPathAllocator(),
        now: @escaping @Sendable () -> Date = Date.init,
        eventHandler: @escaping EventHandler
    ) {
        self.rootURL = rootURL
        self.fileSystem = fileSystem
        self.allocator = allocator
        self.now = now
        self.eventHandler = eventHandler
    }

    deinit {
        idleTask?.cancel()
        sustainedTask?.cancel()
    }

    func configureRoot(_ newRoot: URL?) {
        rootURL = newRoot
        if newRoot != nil { hasBlockingError = false }
    }

    func restoreWithoutFileAccess(
        _ jot: ActiveJot,
        recoveryText: String?,
        recoveryRevision: Int?
    ) -> String {
        let text = recoveryText ?? ""
        let revision = max(recoveryRevision ?? jot.acknowledgedRevision, jot.acknowledgedRevision)
        activeJot = jot
        activeFileWasMissing = false
        latestSnapshot = EditorSnapshot(
            revision: revision,
            text: text,
            selection: .start,
            viewport: .top
        )
        lastWrittenData = revision == jot.acknowledgedRevision ? Data(text.utf8) : nil
        hasBlockingError = true
        return text
    }

    func restore(_ jot: ActiveJot?, recoveryText: String? = nil, recoveryRevision: Int? = nil) throws -> String {
        guard let jot else {
            activeJot = nil
            lastWrittenData = nil
            activeFileWasMissing = false
            return ""
        }

        let url = URL(fileURLWithPath: jot.path)
        try fileSystem.recoverInterruptedAtomicWrite(to: url)
        guard fileSystem.fileExists(at: url) else {
            activeJot = jot
            activeFileWasMissing = true
            if let recoveryText {
                latestSnapshot = EditorSnapshot(
                    revision: max(recoveryRevision ?? jot.acknowledgedRevision, jot.acknowledgedRevision),
                    text: recoveryText,
                    selection: .start,
                    viewport: .top
                )
            }
            hasBlockingError = true
            throw PersistenceError.activeFileMissing
        }
        let data = try fileSystem.data(at: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PersistenceError.writeFailed("The active jot is not valid UTF-8.")
        }
        activeJot = jot
        lastWrittenData = data
        activeFileWasMissing = false
        latestSnapshot = EditorSnapshot(
            revision: jot.acknowledgedRevision,
            text: text,
            selection: .start,
            viewport: .top
        )
        return text
    }

    /// Restore the durable phone journal against the bytes it last acknowledged.
    /// Reading a newer canonical file must not make it the baseline for an older local edit.
    func restoreJournal(_ jot: ActiveJot?, text recoveryText: String, revision: Int,
                        baseline: Data?) throws -> String {
        let canonical = try restore(jot, recoveryText: recoveryText, recoveryRevision: revision)
        guard var jot else { return recoveryText }
        guard revision > jot.acknowledgedRevision else { return canonical }
        latestSnapshot = EditorSnapshot(revision: revision, text: recoveryText, selection: .start, viewport: .top)
        if lastWrittenData == Data(recoveryText.utf8) {
            // The write reached disk before the journal recorded its acknowledgement.
            jot.acknowledgedRevision = revision
            activeJot = jot
        } else {
            let canonicalData = lastWrittenData
            lastWrittenData = baseline
            if baseline == nil || baseline != canonicalData {
                conflict(jot: jot, revision: revision, error: .externalConflict)
            }
        }
        return recoveryText
    }

    func acknowledgedState() -> (jot: ActiveJot?, data: Data?) {
        (activeJot, hasBlockingError ? nil : lastWrittenData)
    }

    func acknowledgedData() -> Data? { hasBlockingError ? nil : lastWrittenData }

    func receive(_ snapshot: EditorSnapshot, flushImmediately: Bool = false) {
        guard snapshot.revision > (latestSnapshot?.revision ?? activeJot?.acknowledgedRevision ?? -1) else {
            return
        }
        latestSnapshot = snapshot

        if activeJot == nil {
            guard !snapshot.text.isEmpty else { return }
            guard allocateActiveJot(for: snapshot) else { return }
            writeLatestSnapshot()
            return
        }

        Task { @MainActor [eventHandler] in eventHandler(.saving(revision: snapshot.revision)) }
        if flushImmediately || now().timeIntervalSince(lastWriteStartedAt) >= 1.0 {
            idleTask?.cancel()
            writeLatestSnapshot()
        } else {
            scheduleIdleWrite()
            ensureSustainedWrite()
        }
    }

    func flush(through revision: Int? = nil) -> Bool {
        idleTask?.cancel()
        idleTask = nil
        if activeJot == nil, let latestSnapshot, !latestSnapshot.text.isEmpty {
            guard allocateActiveJot(for: latestSnapshot) else { return false }
        }
        if let latestSnapshot,
           latestSnapshot.revision > (activeJot?.acknowledgedRevision ?? -1) {
            writeLatestSnapshot()
        }
        let requiredRevision = revision ?? latestSnapshot?.revision ?? activeJot?.acknowledgedRevision ?? 0
        return !hasBlockingError && (activeJot?.acknowledgedRevision ?? 0) >= requiredRevision
    }

    func finishAndNew(through revision: Int) -> Bool {
        guard activeJot != nil else { return true }
        guard flush(through: revision) else { return false }
        idleTask?.cancel()
        sustainedTask?.cancel()
        idleTask = nil
        sustainedTask = nil
        activeJot = nil
        lastWrittenData = nil
        activeFileWasMissing = false
        latestSnapshot = nil
        hasBlockingError = false
        return true
    }

    // Copy first, then reserve a note path. The editor commits the reference as one undoable edit.
    func importAttachment(_ data: Data, fileExtension: String) throws -> (jot: ActiveJot, relativePath: String) {
        guard let rootURL, !hasBlockingError else { throw PersistenceError.rootUnavailable }
        let allocation = activeJot.map { JotAllocation(id: $0.id, fileURL: URL(fileURLWithPath: $0.path)) }
            ?? allocator.allocate(root: rootURL, at: now())
        let directory = allocation.fileURL.deletingLastPathComponent()
            .appendingPathComponent("attachments/\(allocation.id)", isDirectory: true)
        let filename = "\(ULID.make()).\(fileExtension)"
        try fileSystem.createDirectory(at: directory)
        try fileSystem.writeAtomically(data, to: directory.appendingPathComponent(filename))
        if activeJot == nil {
            activeJot = ActiveJot(id: allocation.id, path: allocation.fileURL.path, acknowledgedRevision: -1)
            activeFileWasMissing = false
        }
        return (activeJot!, "attachments/\(allocation.id)/\(filename)")
    }

    func currentJot() -> ActiveJot? { activeJot }

    func openExisting(id: String, path: String, through revision: Int) throws -> (text: String, jot: ActiveJot) {
        guard flush(through: revision) else {
            throw PersistenceError.writeFailed("The current jot has not been saved.")
        }
        let url = URL(fileURLWithPath: path)
        guard fileSystem.fileExists(at: url) else { throw PersistenceError.activeFileMissing }
        let data = try fileSystem.data(at: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PersistenceError.writeFailed("The selected jot is not valid UTF-8.")
        }
        idleTask?.cancel()
        sustainedTask?.cancel()
        idleTask = nil
        sustainedTask = nil
        let jot = ActiveJot(id: id, path: path, acknowledgedRevision: 0)
        activeJot = jot
        lastWrittenData = data
        latestSnapshot = EditorSnapshot(revision: 0, text: text, selection: .start, viewport: .top)
        activeFileWasMissing = false
        hasBlockingError = false
        return (text, jot)
    }

    func saveCurrentVersionAsCopy() -> ActiveJot? {
        guard let latestSnapshot, let rootURL else { return nil }
        let previousJot = activeJot
        let previousWrittenData = lastWrittenData
        let previousFileWasMissing = activeFileWasMissing
        let allocation = allocator.allocate(root: rootURL, at: now())
        // Keep the same base directory so the copy's relative attachment links remain portable.
        let copyURL = previousJot.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent()
            .appendingPathComponent(allocation.fileURL.lastPathComponent) } ?? allocation.fileURL
        activeJot = ActiveJot(id: allocation.id, path: copyURL.path, acknowledgedRevision: -1)
        lastWrittenData = nil
        activeFileWasMissing = false
        hasBlockingError = false
        writeLatestSnapshot()
        guard !hasBlockingError,
              let activeJot,
              activeJot.acknowledgedRevision >= latestSnapshot.revision else {
            activeJot = previousJot
            lastWrittenData = previousWrittenData
            activeFileWasMissing = previousFileWasMissing
            hasBlockingError = true
            return nil
        }
        return activeJot
    }

    func hasExternalChange() throws -> Bool {
        guard let jot = activeJot else { return false }
        let url = URL(fileURLWithPath: jot.path)
        guard fileSystem.fileExists(at: url) else { return true }
        return try fileSystem.data(at: url) != lastWrittenData
    }

    /// Adopt external bytes only when the in-memory document is fully acknowledged.
    /// A dirty or failed writer preserves its snapshot for Save Copy instead.
    func reconcileExternal() throws -> (text: String, jot: ActiveJot)? {
        guard let jot = activeJot else { return nil }
        let url = URL(fileURLWithPath: jot.path)
        guard fileSystem.fileExists(at: url) else {
            conflict(jot: jot, revision: latestSnapshot?.revision ?? jot.acknowledgedRevision, error: .activeFileMissing)
            return nil
        }
        let data = try fileSystem.data(at: url)
        guard data != lastWrittenData else { return nil }
        guard !hasBlockingError, (latestSnapshot?.revision ?? jot.acknowledgedRevision) <= jot.acknowledgedRevision else {
            conflict(jot: jot, revision: latestSnapshot?.revision ?? jot.acknowledgedRevision, error: .externalConflict)
            return nil
        }
        return try reloadExternalVersion()
    }

    func reloadExternalVersion() throws -> (text: String, jot: ActiveJot) {
        guard var activeJot else { throw PersistenceError.activeFileMissing }
        let url = URL(fileURLWithPath: activeJot.path)
        guard fileSystem.fileExists(at: url) else { throw PersistenceError.activeFileMissing }
        let data = try fileSystem.data(at: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PersistenceError.writeFailed("The external jot is not valid UTF-8.")
        }
        activeJot.acknowledgedRevision = max(activeJot.acknowledgedRevision, latestSnapshot?.revision ?? 0) + 1
        self.activeJot = activeJot
        lastWrittenData = data
        activeFileWasMissing = false
        latestSnapshot = EditorSnapshot(
            revision: activeJot.acknowledgedRevision,
            text: text,
            selection: .start,
            viewport: .top
        )
        hasBlockingError = false
        return (text, activeJot)
    }

    private func allocateActiveJot(for snapshot: EditorSnapshot) -> Bool {
        guard let rootURL else {
            fail(snapshot, error: .rootUnavailable)
            return false
        }
        let allocation = allocator.allocate(root: rootURL, at: now())
        activeJot = ActiveJot(id: allocation.id, path: allocation.fileURL.path, acknowledgedRevision: -1)
        activeFileWasMissing = false
        Task { @MainActor [eventHandler] in
            eventHandler(.noteAllocated(id: allocation.id, path: allocation.fileURL.path, revision: snapshot.revision))
            eventHandler(.saving(revision: snapshot.revision))
        }
        return true
    }

    private func scheduleIdleWrite() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.writeLatestSnapshot()
        }
    }

    private func ensureSustainedWrite() {
        guard sustainedTask == nil else { return }
        sustainedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.writeIfPending()
            }
        }
    }

    private func writeIfPending() {
        guard let latestSnapshot,
              latestSnapshot.revision > (activeJot?.acknowledgedRevision ?? -1)
        else {
            sustainedTask?.cancel()
            sustainedTask = nil
            return
        }
        writeLatestSnapshot()
    }

    private func writeLatestSnapshot() {
        guard let snapshot = latestSnapshot, var jot = activeJot else { return }
        guard snapshot.revision > jot.acknowledgedRevision else { return }
        let fileURL = URL(fileURLWithPath: jot.path)
        lastWriteStartedAt = now()

        do {
            if activeFileWasMissing {
                conflict(jot: jot, revision: snapshot.revision, error: .activeFileMissing)
                return
            }
            let data = Data(snapshot.text.utf8)
            try fileSystem.writeIfUnchanged(data, to: fileURL, expected: lastWrittenData)
            lastWrittenData = data
            jot.acknowledgedRevision = snapshot.revision
            activeJot = jot
            hasBlockingError = false
            Task { @MainActor [eventHandler] in
                eventHandler(.writeSucceeded(id: jot.id, revision: snapshot.revision))
            }
        } catch let failure as PersistenceError where failure == .externalConflict || failure == .activeFileMissing {
            conflict(jot: jot, revision: snapshot.revision, error: failure)
        } catch {
            fail(snapshot, error: .writeFailed(error.localizedDescription))
        }
    }

    private func conflict(jot: ActiveJot, revision: Int, error: PersistenceError) {
        hasBlockingError = true
        Task { @MainActor [eventHandler] in
            eventHandler(.externalConflict(id: jot.id, revision: revision))
            eventHandler(.writeFailed(id: jot.id, revision: revision, error: error))
        }
    }

    private func fail(_ snapshot: EditorSnapshot, error: PersistenceError) {
        hasBlockingError = true
        let id = activeJot?.id
        Task { @MainActor [eventHandler] in
            eventHandler(.writeFailed(id: id, revision: snapshot.revision, error: error))
        }
    }

}
