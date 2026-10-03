import Foundation

enum NotebookStorage: String, Codable, CaseIterable, Sendable {
    case local, iCloud
    static let cloudContainer = "iCloud.com.erikjohansson.Jot"

    static func cloudRoot() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: cloudContainer)?
            .appendingPathComponent("Documents/Jots", isDirectory: true)
    }
}

enum NotebookTransferError: LocalizedError {
    case nestedRoots
    case conflictingFile(String)
    case symbolicLink(String)
    case destinationEscape(String)
    var errorDescription: String? {
        switch self {
        case .nestedRoots: "Choose a folder outside the current notebook."
        case let .conflictingFile(path): "The destination has a different version of \(path). Neither version was overwritten; choose another destination."
        case let .destinationEscape(path): "The destination contains a link outside the notebook at \(path). Choose another destination."
        case let .symbolicLink(path): "The notebook contains a symbolic link at \(path). Move the linked file into the notebook before transferring."
        }
    }
}

/// A non-destructive transfer. Preflight all collisions before copying; never overwrite a different file.
/// Keep the source as a backup so interruption cannot remove the only copy of any jot.
struct NotebookTransfer {
    static func copy(from source: URL, to destination: URL) throws {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard source != destination else { return }
        guard !source.path.hasPrefix(destination.path + "/"), !destination.path.hasPrefix(source.path + "/") else {
            throw NotebookTransferError.nestedRoots
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }
        var plan: [(source: URL, destination: URL, relative: String)] = []
        var enumerationError: (any Error)?
        guard let files = manager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let url as URL in files {
            let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(source.path.count + 1))
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw NotebookTransferError.symbolicLink(relative) }
            guard values.isRegularFile == true else { continue }
            let target = destination.appendingPathComponent(relative)
            guard target.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target.lastPathComponent).path.hasPrefix(destination.path + "/") else {
                throw NotebookTransferError.destinationEscape(relative)
            }
            if manager.fileExists(atPath: target.path), try read(url) != read(target) {
                throw NotebookTransferError.conflictingFile(relative)
            }
            plan.append((url, target, relative))
        }
        if let enumerationError { throw enumerationError }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in plan {
            let data = try read(item.source)
            try manager.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: item.destination.path) {
                guard try read(item.destination) == data else { throw NotebookTransferError.conflictingFile(item.relative) }
            } else {
                do { try LocalJotFileSystem().writeIfUnchanged(data, to: item.destination, expected: nil) }
                catch PersistenceError.externalConflict { throw NotebookTransferError.conflictingFile(item.relative) }
            }
        }
    }

    private static func read(_ url: URL) throws -> Data {
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
