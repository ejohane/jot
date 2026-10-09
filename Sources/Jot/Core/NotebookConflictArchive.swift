import Foundation
import CryptoKit

/// Preserve every cloud conflict as an ordinary note before acknowledging resolution.
struct NotebookConflictArchive {
    static func preserve(in root: URL) throws -> [URL] {
        guard let files = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var copies: [URL] = []
        for case let url as URL in files {
            guard NoteRailIndex.cloudEntry(url: url, root: root) != nil else { continue }
            copies += try preserve(at: url)
        }
        return copies
    }

    static func preserve(at url: URL) throws -> [URL] {
        var copies: [URL] = []
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            let copy = try preserve(source: url, read: { try coordinatedRead(version.url) },
                resolve: { version.isResolved = true })
            copies.append(copy)
        }
        return copies
    }

    static func preserve(source: URL, fileSystem: any JotFileSystem = LocalJotFileSystem(),
                         read: () throws -> Data, resolve: () -> Void) throws -> URL {
        let bytes = try read()
        // Stable names let interrupted retries and two devices preserve the same version once.
        let identity = Data(source.lastPathComponent.utf8) + Data([0]) + bytes
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let clock = source.deletingPathExtension().lastPathComponent.components(separatedBy: "--")[0]
        let copy = source.deletingLastPathComponent().appendingPathComponent("\(clock)--conflict-\(digest).md")
        if fileSystem.fileExists(at: copy) {
            guard try fileSystem.data(at: copy) == bytes else { throw PersistenceError.externalConflict }
        } else {
            do { try fileSystem.writeIfUnchanged(bytes, to: copy, expected: nil) }
            catch PersistenceError.externalConflict {
                // A cooperating device may have created this identical copy concurrently.
                guard try fileSystem.data(at: copy) == bytes else { throw PersistenceError.externalConflict }
            }
        }
        guard try fileSystem.data(at: copy) == bytes else { throw PersistenceError.externalConflict }
        resolve()
        return copy
    }

    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { actual in
            result = Result { try Data(contentsOf: actual) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
