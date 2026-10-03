import Foundation

/// Keep the cloud inventory alive even when document contents are not on this device yet.
@MainActor
final class PhoneCloudNotebook {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var requestedPaths: Set<String> = []
    var onChange: (@MainActor ([URL]) -> Void)?

    func configure(root: URL?) {
        generation = UUID()
        requestedPaths = []
        query?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        query = nil
        guard let root else { onChange?([]); return }
        let token = generation
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K ENDSWITH[c] %@", NSMetadataItemFSNameKey, ".md")
        self.query = query
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, let query = self.query else { return }
                    query.disableUpdates()
                    let urls = query.results.compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemURLKey) as? URL }
                        .filter { NoteRailIndex.cloudEntry(url: $0, root: root) != nil }
                    query.enableUpdates()
                    self.onChange?(urls)
                    let downloads = urls.filter { self.requestedPaths.insert($0.path).inserted }
                    // Request Markdown for full-text indexing; images stay lazy.
                    Task.detached(priority: .utility) {
                        for url in downloads { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
                    }
                }
            })
        }
        if !query.start() { onChange?([]) }
    }
}
