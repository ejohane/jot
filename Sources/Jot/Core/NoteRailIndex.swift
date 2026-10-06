import Foundation

struct NoteRailEntry: Equatable, Sendable {
    let id: String
    let path: String
    let timestamp: Date
    let excerpt: String
}

/// A disposable, read-only view of the Markdown archive for note navigation.
actor NoteRailIndex {
    private var root: URL?
    private var generation = 0
    private var entriesByID: [String: NoteRailEntry] = [:]
    private var refreshGeneration = 0

    init(root: URL?) { self.root = root }

    func configure(root: URL?) {
        self.root = root
        generation += 1
        refreshGeneration += 1
        entriesByID = [:]
    }

    func refresh(discoveredURLs: [URL] = []) async -> [NoteRailEntry]? {
        let root = self.root
        let generation = self.generation
        refreshGeneration += 1
        let refreshGeneration = self.refreshGeneration
        let entries = await Task.detached(priority: .utility) {
            var entries = Self.scan(root: root)
            if let root {
                let paths = Set(entries.map(\.path))
                entries += discoveredURLs.compactMap { Self.cloudEntry(url: $0, root: root) }
                    .filter { !paths.contains($0.path) && !$0.id.hasPrefix("file:") }
            }
            return entries.sorted { $0.timestamp == $1.timestamp ? $0.id > $1.id : $0.timestamp > $1.timestamp }
        }.value
        guard generation == self.generation, refreshGeneration == self.refreshGeneration else { return nil }
        entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries
    }

    func entry(id: String) -> NoteRailEntry? { entriesByID[id] }

    static func scan(root: URL?, includeOtherMarkdown: Bool = false) -> [NoteRailEntry] {
        guard let root = root?.resolvingSymlinksInPath(),
              let files = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return [] }
        var result: [NoteRailEntry] = []
        for case let url as URL in files where url.pathExtension.lowercased() == "md" {
            let filename = url.deletingPathExtension().lastPathComponent
            let parts = filename.components(separatedBy: "--")
            let isJot = parts.count == 2 && !parts[1].isEmpty
            guard isJot || includeOtherMarkdown,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let timestamp = (isJot ? date(from: url, clock: parts[0]) : nil) ?? values.creationDate ?? .distantPast
            let excerpt = preview(of: url)
            let path = url.resolvingSymlinksInPath().path
            let id = isJot ? parts[1] : "file:" + String(path.dropFirst(root.path.count + 1))
            result.append(NoteRailEntry(id: id, path: path, timestamp: timestamp, excerpt: excerpt))
        }
        return result.sorted { $0.timestamp == $1.timestamp ? $0.id > $1.id : $0.timestamp > $1.timestamp }
    }

    static func cloudEntry(url: URL, root: URL) -> NoteRailEntry? {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), url.pathExtension.lowercased() == "md" else { return nil }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "--")
        let isJot = parts.count == 2 && !parts[1].isEmpty
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .creationDateKey])
        guard values?.isSymbolicLink != true, values?.isDirectory != true else { return nil }
        let id = isJot ? parts[1] : "file:" + relative
        return NoteRailEntry(id: id, path: url.path,
            timestamp: (isJot ? date(from: url, clock: parts[0]) : nil) ?? values?.creationDate ?? .distantPast, excerpt: "Jot in iCloud — download to read")
    }

    static func date(from url: URL, clock: String) -> Date? {
        let day = url.deletingLastPathComponent()
        let month = day.deletingLastPathComponent()
        let year = month.deletingLastPathComponent()
        let time = clock.split(separator: "-").compactMap { Int($0) }
        guard let y = Int(year.lastPathComponent), let m = Int(month.lastPathComponent),
              let d = Int(day.lastPathComponent), time.count == 4 else { return nil }
        return Calendar.autoupdatingCurrent.date(from: DateComponents(
            year: y, month: m, day: d, hour: time[0], minute: time[1], second: time[2], nanosecond: time[3] * 1_000_000
        ))
    }

    private static func preview(of url: URL) -> String {
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return "Jot in iCloud — download to read"
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(180))
    }
}
