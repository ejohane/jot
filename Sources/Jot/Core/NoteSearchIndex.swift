import Foundation

struct NoteSearchMatch: Equatable, Sendable {
    let from: Int
    let to: Int
}

struct NoteSearchResult: Equatable, Sendable {
    let id: String
    let timestamp: Date
    let title: String
    let excerpt: String
    let titleMatches: [NoteSearchMatch]
    let excerptMatches: [NoteSearchMatch]
}

/// Disposable full-text cache. Scanning and matching never run on the main actor.
actor NoteSearchIndex {
    private struct Document: Sendable {
        let entry: NoteRailEntry
        let modified: Date?
        let size: Int?
        let source: String
    }
    private var root: URL?
    private var generation = 0
    private var documents: [String: Document] = [:]
    private var scan: Task<[String: Document], Never>?
    private var scanned = false
    private var scanGeneration = 0

    init(root: URL?) { self.root = root }

    func configure(root: URL?) {
        generation += 1
        scanGeneration += 1
        self.root = root
        scan?.cancel()
        scan = nil
        documents = [:]
        scanned = false
    }

    func entry(id: String) -> NoteRailEntry? { documents[id]?.entry }

    func search(query: String, refresh: Bool = false, currentID: String? = nil, currentText: String? = nil) async -> [NoteSearchResult]? {
        let generation = self.generation
        if scan == nil && (refresh || !scanned) {
            scanGeneration += 1
            let root = self.root
            let cached = documents
            scan = Task.detached(priority: .userInitiated) { Self.load(root: root, cached: cached) }
        }
        if let scan {
            let scanGeneration = self.scanGeneration
            let loaded = await scan.value
            guard generation == self.generation else { return nil }
            if scanGeneration == self.scanGeneration {
                documents = loaded
                self.scan = nil
                scanned = true
            }
        }
        let snapshot = documents
        let matching = Task.detached(priority: .userInitiated) {
            Self.matches(in: snapshot, query: query, currentID: currentID, currentText: currentText)
        }
        let results = await withTaskCancellationHandler(operation: { await matching.value }, onCancel: { matching.cancel() })
        guard generation == self.generation, !Task.isCancelled else { return nil }
        return results
    }

    private static func load(root: URL?, cached: [String: Document]) -> [String: Document] {
        var result: [String: Document] = [:]
        for entry in NoteRailIndex.scan(root: root, includeOtherMarkdown: true) {
            if Task.isCancelled { break }
            let url = URL(fileURLWithPath: entry.path)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            if let old = cached[entry.id], old.entry.path == entry.path,
               old.modified == values.contentModificationDate, old.size == values.fileSize {
                result[entry.id] = old
            } else if let source = try? String(contentsOf: url, encoding: .utf8) {
                result[entry.id] = Document(entry: entry, modified: values.contentModificationDate, size: values.fileSize, source: source)
            }
        }
        return result
    }

    private static func matches(in documents: [String: Document], query: String, currentID: String?, currentText: String?) -> [NoteSearchResult] {
        let phrase = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let words = phrase.split(separator: " ").map(String.init)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var ranked: [(score: Int, result: NoteSearchResult)] = []
        for document in documents.values {
            if Task.isCancelled { return [] }
            let source = document.entry.id == currentID ? currentText ?? document.source : document.source
            let text = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard words.allSatisfy({ text.range(of: $0, options: options) != nil }) else { continue }
            let firstLine = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.allSatisfy({ "-*_`~".contains($0) }) } ?? ""
            let title = firstLine.isEmpty ? "Empty note" : String(firstLine
                .replacingOccurrences(of: "^ {0,3}#{1,6}\\s+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").prefix(120))
            let hit = phrase.isEmpty ? nil : text.range(of: phrase, options: options) ?? words.compactMap { text.range(of: $0, options: options) }.min { $0.lowerBound < $1.lowerBound }
            let excerpt: String
            if text == firstLine, text.count <= 120 {
                excerpt = ""
            } else if let hit {
                let start = text.index(hit.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(start, offsetBy: 180, limitedBy: text.endIndex) ?? text.endIndex
                excerpt = (start > text.startIndex ? "…" : "") + String(text[start..<end]) + (end < text.endIndex ? "…" : "")
            } else {
                let remainder = source.split(whereSeparator: \.isNewline).dropFirst().joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                excerpt = String(remainder.prefix(180))
            }
            let titleScore = words.filter { title.range(of: $0, options: options) != nil }.count * 100
            let score = titleScore + (!phrase.isEmpty && title.range(of: phrase, options: options) != nil ? 400 : 0)
                + (!phrase.isEmpty && text.range(of: phrase, options: options) != nil ? 40 : 0)
            ranked.append((score, NoteSearchResult(id: document.entry.id, timestamp: document.entry.timestamp,
                title: title, excerpt: excerpt, titleMatches: highlights(title, words: words), excerptMatches: highlights(excerpt, words: words))))
        }
        return ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.result.timestamp != $1.result.timestamp { return $0.result.timestamp > $1.result.timestamp }
            return $0.result.id > $1.result.id
        }.prefix(60).map(\.result)
    }

    private static func highlights(_ text: String, words: [String]) -> [NoteSearchMatch] {
        var ranges: [NSRange] = []
        for word in words {
            var start = text.startIndex
            while start < text.endIndex, let match = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                ranges.append(NSRange(match, in: text))
                start = match.upperBound
            }
        }
        var merged: [NoteSearchMatch] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let previous = merged.last, range.location <= previous.to {
                merged[merged.count - 1] = NoteSearchMatch(from: previous.from, to: max(previous.to, NSMaxRange(range)))
            } else { merged.append(NoteSearchMatch(from: range.location, to: NSMaxRange(range))) }
        }
        return merged
    }
}
