import Darwin
import Foundation

protocol JotFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    func data(at url: URL) throws -> Data
    func fileExists(at url: URL) -> Bool
    func writeAtomically(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
    func recoverInterruptedAtomicWrite(to url: URL) throws
}

func atomicTemporaryURL(for canonicalURL: URL) -> URL {
    canonicalURL.deletingLastPathComponent()
        .appendingPathComponent(".\(canonicalURL.lastPathComponent).jot-tmp")
}

struct LocalJotFileSystem: JotFileSystem {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func data(at url: URL) throws -> Data { try Data(contentsOf: url) }

    func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        let temporaryURL = atomicTemporaryURL(for: url)
        if fileExists(at: temporaryURL) {
            try removeItem(at: temporaryURL)
        }
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()

            if Darwin.rename(temporaryURL.path, url.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            let directoryDescriptor = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
            if directoryDescriptor >= 0 {
                _ = Darwin.fsync(directoryDescriptor)
                Darwin.close(directoryDescriptor)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }

    func recoverInterruptedAtomicWrite(to url: URL) throws {
        let temporaryURL = atomicTemporaryURL(for: url)
        guard fileExists(at: temporaryURL) else { return }
        if fileExists(at: url) {
            try removeItem(at: temporaryURL)
            return
        }
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
