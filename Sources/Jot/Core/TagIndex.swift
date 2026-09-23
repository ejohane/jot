import Foundation

/// Disposable folder index. A full background reconciliation also repairs missed file events.
actor TagIndex {
    private let scan: @Sendable (URL?) -> [URL: Set<String>]
    private var root: URL?
    private var generation = 0
    private var refreshGeneration = 0
    private var refreshInProgress = false
    private(set) var tagsByFile: [URL: Set<String>] = [:]

    init(scan: @escaping @Sendable (URL?) -> [URL: Set<String>] = TagIndex.scanFolder) {
        self.scan = scan
    }

    func configure(root: URL?) {
        self.root = root
        generation += 1
        refreshGeneration += 1
        tagsByFile = [:]
    }

    func refresh() async -> [String]? {
        guard !refreshInProgress else { return nil }
        refreshInProgress = true
        defer { refreshInProgress = false }
        let root = self.root
        let generation = self.generation
        refreshGeneration += 1
        let refreshGeneration = self.refreshGeneration
        let scanner = scan
        let next = await Task.detached(priority: .utility) { scanner(root) }.value
        guard generation == self.generation, refreshGeneration == self.refreshGeneration else { return nil }
        guard next != tagsByFile else { return nil }
        tagsByFile = next
        return vocabulary
    }

    var vocabulary: [String] {
        let names = tagsByFile.values.flatMap { $0 }.sorted()
        var result: [String: String] = [:]
        for name in names where result[name.lowercased()] == nil { result[name.lowercased()] = name }
        return result.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func scanFolder(root: URL?) -> [URL: Set<String>] {
        guard let root,
              let files = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return [:] }
        var result: [URL: Set<String>] = [:]
        for case let url as URL in files where url.pathExtension.lowercased() == "md" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result[url] = InlineTags.names(in: text)
        }
        return result
    }
}
