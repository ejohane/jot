import Foundation

/// A cached cloud copy remains usable offline. Never treat an undownloaded item as a deleted jot.
struct NotebookCloudFile {
    enum Availability: Equatable, Sendable { case local, cached, remote }
    enum DownloadError: LocalizedError {
        case unavailable
        var errorDescription: String? { "This jot hasn’t downloaded from iCloud yet. Connect to the internet and try again. Your current writing is kept safe." }
    }

    static func prepare(_ url: URL) async throws {
        try await prepare(url, availability: { url in
            // URL resource values can cache metadata; use a fresh URL for every poll.
            let fresh = URL(fileURLWithPath: url.path)
            let values = try fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                            .ubiquitousItemDownloadingErrorKey])
            guard values.isUbiquitousItem == true else { return .local }
            if values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded {
                return .cached
            }
            if let error = values.ubiquitousItemDownloadingError { throw error }
            return .remote
        }, request: { try FileManager.default.startDownloadingUbiquitousItem(at: $0) })
    }

    static func prepare(_ url: URL,
                        availability: @Sendable (URL) throws -> Availability,
                        request: @Sendable (URL) throws -> Void,
                        attempts: Int = 60,
                        pause: @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) async throws {
        try Task.checkCancellation()
        switch try availability(url) {
        case .local: return
        case .cached:
            // A failed refresh must not prevent editing the downloaded copy offline.
            try? request(url)
            return
        case .remote: try request(url)
        }
        for _ in 0..<attempts {
            try await pause()
            try Task.checkCancellation()
            if try availability(url) != .remote { return }
        }
        throw DownloadError.unavailable
    }
}
