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

    func refresh() async -> [NoteRailEntry]? {
        let root = self.root
        let generation = self.generation
        refreshGeneration += 1
        let refreshGeneration = self.refreshGeneration
        let entries = await Task.detached(priority: .utility) { Self.scan(root: root) }.value
        guard generation == self.generation, refreshGeneration == self.refreshGeneration else { return nil }
        entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries
    }

    func entry(id: String) -> NoteRailEntry? { entriesByID[id] }

    private static func scan(root: URL?) -> [NoteRailEntry] {
        guard let root,
              let files = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return [] }
        var result: [NoteRailEntry] = []
        for case let url as URL in files where url.pathExtension.lowercased() == "md" {
            let filename = url.deletingPathExtension().lastPathComponent
            let parts = filename.components(separatedBy: "--")
            guard parts.count == 2, !parts[1].isEmpty,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey]),
                  values.isRegularFile == true else { continue }
            let timestamp = date(from: url, clock: parts[0]) ?? values.creationDate ?? .distantPast
            let excerpt = preview(of: url)
            result.append(NoteRailEntry(id: parts[1], path: url.path, timestamp: timestamp, excerpt: excerpt))
        }
        return result.sorted { $0.timestamp == $1.timestamp ? $0.id > $1.id : $0.timestamp > $1.timestamp }
    }

    private static func date(from url: URL, clock: String) -> Date? {
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
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(180))
    }
}
