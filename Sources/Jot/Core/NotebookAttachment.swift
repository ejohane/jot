import Foundation

struct NotebookAttachment {
    static func load(_ url: URL) async throws -> Data {
        try await NotebookCloudFile.prepare(url)
        try Task.checkCancellation()
        var coordinationError: NSError?
        var result: Result<Data, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { actual in
            result = Result { try Data(contentsOf: actual) }
        }
        if let coordinationError { throw coordinationError }
        try Task.checkCancellation()
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
