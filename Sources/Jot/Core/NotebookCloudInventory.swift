import Foundation

/// Keep the cloud inventory alive even when document contents are not on this device yet.
@MainActor
final class NotebookCloudInventory {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var requestedPaths: Set<String> = []
    private(set) var gathered = false
    private(set) var files: [URL] = []
    private var startFailed = false
    var onChange: (@MainActor ([URL]) -> Void)?

    func configure(root: URL?) {
        generation = UUID()
        gathered = false
        startFailed = false
        files = []
        requestedPaths = []
        query?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        query = nil
        guard let root else { onChange?([]); return }
        let token = generation
        let query = NSMetadataQuery()
        #if os(iOS)
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        #else
        query.searchScopes = [root]
        #endif
        query.predicate = NSPredicate(value: true)
        self.query = query
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, let query = self.query else { return }
                    query.disableUpdates()
                    let urls = query.results.compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemURLKey) as? URL }
                        .filter {
                            guard !$0.hasDirectoryPath, (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return false }
                            let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
                            let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                            return path.hasPrefix(prefix) && !path.dropFirst(prefix.count).split(separator: "/").contains(where: { $0.hasPrefix(".") })
                        }
                    query.enableUpdates()
                    self.files = urls
                    if name == .NSMetadataQueryDidFinishGathering { self.gathered = true }
                    self.onChange?(urls)
                    let downloads = urls.filter { $0.pathExtension.lowercased() == "md" }.filter { self.requestedPaths.insert($0.path).inserted }
                    // Request Markdown for full-text indexing; images stay lazy.
                    Task.detached(priority: .utility) {
                        for url in downloads { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
                    }
                }
            })
        }
        if !query.start() { startFailed = true; onChange?([]) }
    }
    static func snapshot(root: URL) async throws -> [URL] {
        let inventory = NotebookCloudInventory()
        inventory.configure(root: root)
        defer { inventory.configure(root: nil) }
        for _ in 0..<60 {
            try Task.checkCancellation()
            if inventory.startFailed { throw NotebookCloudFile.DownloadError.unavailable }
            if inventory.gathered { return inventory.files }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NotebookCloudFile.DownloadError.unavailable
    }
}
