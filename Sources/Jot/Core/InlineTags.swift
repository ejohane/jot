import Foundation

/// Keep this grammar in sync with Web/src/tags.ts; both sides run the same fixtures.
enum InlineTags {
    static let tagPattern = try! NSRegularExpression(pattern: "(^|[\\s(\\[{\\\"'])#([A-Za-z][A-Za-z0-9_-]*)", options: [.anchorsMatchLines])
    static let fencePattern = try! NSRegularExpression(pattern: "^ {0,3}(`{3,}|~{3,})")

    static func names(in text: String) -> Set<String> {
        Set(matches(in: text))
    }

    static func matches(in text: String) -> [String] {
        let original = text as NSString
        var masked = Array(text.utf16)
        var fence: (marker: UInt16, length: Int)?
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let units = Array(line.utf16)
            let nsLine = line as NSString
            let marker = fencePattern.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length))
                .map { nsLine.substring(with: $0.range(at: 1)) }
            if let active = fence {
                clear(&masked, offset, offset + units.count)
                if let marker, marker.utf16.first == active.marker, marker.utf16.count >= active.length { fence = nil }
            } else if let marker {
                fence = (marker.utf16.first!, marker.utf16.count)
                clear(&masked, offset, offset + units.count)
            } else {
                var i = 0
                while i < units.count {
                    if units[i] == 92 { i += 2; continue }
                    if units[i] == 96 && (i == 0 || units[i - 1] != 96) {
                        var end = i + 1
                        while end < units.count && units[end] == 96 { end += 1 }
                        let count = end - i
                        var close = end
                        while close + count <= units.count {
                            if units[close] == 96 && (close == 0 || units[close - 1] != 96)
                                && (close + count == units.count || units[close + count] != 96)
                                && units[close..<(close + count)].allSatisfy({ $0 == 96 }) { break }
                            close += 1
                        }
                        if close + count <= units.count { clear(&masked, offset + i, offset + close + count); i = close + count; continue }
                        i = end; continue
                    }
                    if units[i] == 93 && i + 1 < units.count && units[i + 1] == 40 {
                        var depth = 1
                        var j = i + 2
                        while j < units.count && depth > 0 {
                            if units[j] == 92 { j += 2; continue }
                            if units[j] == 40 { depth += 1 }
                            if units[j] == 41 { depth -= 1 }
                            j += 1
                        }
                        clear(&masked, offset + i + 1, offset + min(j, units.count))
                        i = j; continue
                    }
                    i += 1
                }
            }
            offset += units.count + 1
        }
        let safe = String(decoding: masked, as: UTF16.self)
        return tagPattern.matches(in: safe, range: NSRange(location: 0, length: masked.count)).compactMap { match in
            let hash = match.range.location + match.range(at: 1).length
            if hash > 0 && original.character(at: hash - 1) == 92 { return nil }
            return original.substring(with: match.range(at: 2))
        }
    }

    private static func clear(_ units: inout [UInt16], _ from: Int, _ to: Int) {
        guard from < to else { return }
        for index in from..<min(to, units.count) { units[index] = 32 }
    }
}
