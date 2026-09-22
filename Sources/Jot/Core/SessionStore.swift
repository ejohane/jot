import Foundation

actor SessionStore {
    private let fileURL: URL
    private let fileSystem: any JotFileSystem
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var latestSavedGeneration = -1

    init(fileURL: URL, fileSystem: any JotFileSystem = LocalJotFileSystem()) {
        self.fileURL = fileURL
        self.fileSystem = fileSystem
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    static func live() -> SessionStore {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SessionStore(fileURL: applicationSupport.appendingPathComponent("Jot/session.json"))
    }

    func load() -> PersistedSession {
        try? fileSystem.recoverInterruptedAtomicWrite(to: fileURL)
        guard fileSystem.fileExists(at: fileURL),
              let data = try? fileSystem.data(at: fileURL),
              let session = try? decoder.decode(PersistedSession.self, from: data)
        else { return .empty }
        return session
    }

    func save(_ session: PersistedSession) throws {
        latestSavedGeneration += 1
        let data = try encoder.encode(session)
        try fileSystem.writeAtomically(data, to: fileURL)
    }

    func save(_ session: PersistedSession, generation: Int) throws {
        guard generation > latestSavedGeneration else { return }
        let data = try encoder.encode(session)
        try fileSystem.writeAtomically(data, to: fileURL)
        latestSavedGeneration = generation
    }
}
