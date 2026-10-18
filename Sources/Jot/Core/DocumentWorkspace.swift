import Foundation

/// Paths identify windows; resolving aliases/symlinks avoids two writers for one file.
enum MarkdownFile {
    static func canonicalURL(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    static func accepts(_ url: URL) -> Bool {
        url.isFileURL && ["md", "markdown", "mdown", "mkd", "mkdn"].contains(url.pathExtension.lowercased())
    }
}

struct DocumentWindowState: Codable, Equatable, Sendable {
    var path: String
    var bookmark: Data?
    var text: String
    var baseline: Data
    var revision: Int = 0
    var acknowledgedRevision: Int = 0
    var selection: EditorSelection = .start
    var viewport: EditorViewport = .top
    var frame: String?
}

actor DocumentWorkspaceStore {
    let fileURL: URL
    private var windows: [DocumentWindowState]?
    private let fileSystem: any JotFileSystem

    init(fileURL: URL, fileSystem: any JotFileSystem = LocalJotFileSystem()) {
        self.fileURL = fileURL
        self.fileSystem = fileSystem
    }

    static func live() -> DocumentWorkspaceStore {
        let session = ProcessInfo.processInfo.environment["JOT_TEST_SESSION_PATH"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Jot/session.json")
        return DocumentWorkspaceStore(fileURL: session.appendingPathExtension("documents.json"))
    }

    func load() throws -> [DocumentWindowState] {
        if let windows { return windows }
        try fileSystem.recoverInterruptedAtomicWrite(to: fileURL)
        let result = fileSystem.fileExists(at: fileURL)
            ? try JSONDecoder().decode([DocumentWindowState].self, from: fileSystem.data(at: fileURL)) : []
        windows = result
        return result
    }

    func put(_ state: DocumentWindowState) throws {
        var next = try load().filter { $0.path != state.path }
        next.append(state)
        try save(next)
    }

    func remove(path: String) throws { try save(load().filter { $0.path != path }) }

    private func save(_ next: [DocumentWindowState]) throws {
        try fileSystem.writeAtomically(JSONEncoder().encode(next), to: fileURL)
        windows = next
    }
}

/// All methods are called in order by the owning window. Journal before canonical write;
/// compare disk bytes under file coordination before replacing the original.
actor MarkdownDocument {
    private(set) var state: DocumentWindowState
    private let store: DocumentWorkspaceStore
    private let fileSystem: any JotFileSystem
    private(set) var conflict = false

    init(state: DocumentWindowState, store: DocumentWorkspaceStore,
         fileSystem: any JotFileSystem = LocalJotFileSystem()) {
        self.state = state
        self.store = store
        self.fileSystem = fileSystem
    }

    static func readState(_ url: URL) throws -> DocumentWindowState {
        guard MarkdownFile.accepts(url) else { throw PersistenceError.writeFailed("Choose a Markdown file.") }
        let canonical = MarkdownFile.canonicalURL(url)
        let data = try Data(contentsOf: canonical)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PersistenceError.writeFailed("This Markdown file is not valid UTF-8.")
        }
        let bookmark = try canonical.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return DocumentWindowState(path: canonical.path, bookmark: bookmark, text: text, baseline: data)
    }

    static func open(_ url: URL, store: DocumentWorkspaceStore) throws -> MarkdownDocument {
        MarkdownDocument(state: try readState(url), store: store)
    }

    func checkpoint() async throws { try await store.put(state) }

    func restore() async throws -> DocumentWindowState {
        let url = URL(fileURLWithPath: state.path)
        // A write can reach disk before its acknowledgement reaches the journal.
        if let data = try? fileSystem.data(at: url), data == Data(state.text.utf8), state.revision > state.acknowledgedRevision {
            state.baseline = data
            state.acknowledgedRevision = state.revision
        }
        if state.revision > state.acknowledgedRevision { try await flush() }
        else { _ = try await reconcile() }
        try await store.put(state)
        return state
    }

    func receive(_ snapshot: EditorSnapshot) async throws {
        guard snapshot.revision >= state.revision else { return }
        state.selection = snapshot.selection
        state.viewport = snapshot.viewport
        if snapshot.revision > state.revision {
            state.text = snapshot.text
            state.revision = snapshot.revision
        }
        try await store.put(state)
        try await flush()
    }

    func position(selection: EditorSelection, viewport: EditorViewport, frame: String?) async throws {
        state.selection = selection
        state.viewport = viewport
        if let frame { state.frame = frame }
        try await store.put(state)
    }

    func flush() async throws {
        guard state.revision > state.acknowledgedRevision else { return }
        // Never write until the recovery journal is durable.
        try await store.put(state)
        do {
            let bytes = Data(state.text.utf8)
            let url = URL(fileURLWithPath: state.path)
            if fileSystem is LocalJotFileSystem, FileManager.default.fileExists(atPath: url.path),
               !FileManager.default.isWritableFile(atPath: url.path) {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileSystem.writeIfUnchanged(bytes, to: URL(fileURLWithPath: state.path), expected: state.baseline)
            state.baseline = bytes
            state.acknowledgedRevision = state.revision
            conflict = false
            try await store.put(state)
        } catch {
            if (error as? PersistenceError) == .externalConflict || (error as? PersistenceError) == .activeFileMissing { conflict = true }
            throw error
        }
    }

    func hasExternalChange() -> Bool {
        (try? fileSystem.data(at: URL(fileURLWithPath: state.path))) != state.baseline
    }

    @discardableResult
    func reconcile() async throws -> Bool {
        let bytes = try fileSystem.data(at: URL(fileURLWithPath: state.path))
        guard bytes != state.baseline else { return false }
        guard state.revision <= state.acknowledgedRevision, !conflict else {
            conflict = true
            throw PersistenceError.externalConflict
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw PersistenceError.writeFailed("The outside version is not valid UTF-8. Your version is preserved.")
        }
        state.text = text
        state.baseline = bytes
        state.revision += 1
        state.acknowledgedRevision = state.revision
        try await store.put(state)
        return true
    }

    /// Keep the local version beside the original before adopting any outside bytes.
    func keepBothAndReload() async throws -> URL {
        let original = URL(fileURLWithPath: state.path)
        let copy = original.deletingPathExtension().appendingPathExtension("jot-conflict-\(UUID().uuidString).md")
        try fileSystem.writeIfUnchanged(Data(state.text.utf8), to: copy, expected: nil)
        guard let bytes = try? fileSystem.data(at: original) else {
            throw PersistenceError.writeFailed("Your version was saved as \(copy.lastPathComponent). The original file is unavailable. Restore it to continue.")
        }
        guard let text = String(data: bytes, encoding: .utf8) else { throw PersistenceError.writeFailed("The outside version is not valid UTF-8. Your version was saved as a copy.") }
        state.text = text
        state.baseline = bytes
        state.revision += 1
        state.acknowledgedRevision = state.revision
        conflict = false
        try await store.put(state)
        return copy
    }

    func close() async throws {
        try await flush()
        try await store.remove(path: state.path)
    }
}
