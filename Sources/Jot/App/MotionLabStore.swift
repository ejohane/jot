import Foundation

struct MotionLabNote: Codable, Identifiable {
    var id: String
    var capturedAt: String
    var text: String
    var anchor: Int = 0
    var head: Int = 0
    var scrollTop: Double = 0
}

struct MotionLabData: Codable {
    var notes: [MotionLabNote]
    var selectedID: String
    var settings: [String: Double]
}

@MainActor
final class MotionLabStore {
    private let fileURL: URL
    private(set) var data: MotionLabData

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jot Motion Lab", isDirectory: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("sample-notes.json")
        if let loaded = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(MotionLabData.self, from: loaded), !decoded.notes.isEmpty {
            data = decoded
        } else {
            data = Self.sampleData()
        }
    }

    func payload() -> [String: Any] {
        let notes: [[String: Any]] = data.notes.map {
            ["id": $0.id, "capturedAt": $0.capturedAt, "text": $0.text,
             "anchor": $0.anchor, "head": $0.head, "scrollTop": $0.scrollTop]
        }
        return ["notes": notes, "selectedID": data.selectedID, "settings": data.settings]
    }

    @discardableResult
    func save(id: String, text: String, anchor: Int, head: Int, scrollTop: Double) -> Bool {
        guard let index = data.notes.firstIndex(where: { $0.id == id }) else { return false }
        data.notes[index].text = text
        data.notes[index].anchor = max(0, min(anchor, text.utf16.count))
        data.notes[index].head = max(0, min(head, text.utf16.count))
        data.notes[index].scrollTop = max(0, scrollTop)
        return persist()
    }

    @discardableResult
    func select(id: String) -> Bool {
        guard data.notes.contains(where: { $0.id == id }), persist() else { return false }
        data.selectedID = id
        return persist()
    }

    func saveSettings(_ settings: [String: Double]) {
        data.settings = settings.filter { $0.value.isFinite }
        persist()
    }

    func settingsJSON() -> String {
        guard let encoded = try? JSONSerialization.data(withJSONObject: data.settings, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: encoded, as: UTF8.self)
    }

    func reset() {
        data = Self.sampleData()
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: fileURL, options: .atomic)
            return true
        } catch { return false }
    }

    static func sampleData() -> MotionLabData {
        let base = Date(timeIntervalSince1970: 1_779_500_000)
        let formatter = ISO8601DateFormatter()
        let seeds = [
            "# First spark\n\nA short thought on the way out.",
            "# Window light\n\nThe kitchen window made a small rectangle of gold on the floor.",
            "# Ideas for a walk\n\nTake the long path. Notice the quieter streets.\n\nReturn with one useful sentence.",
            "# A longer note\n\n" + Array(repeating: "A paragraph to test steady scrolling and the boundary between a document and its neighbor. Keep writing until the page extends well beyond the viewport.\n\n", count: 18).joined(),
            "# Coffee with Mira\n\nThe interesting part was the pause before the answer.",
            "# Tiny capture\n\nYes.",
            "# Draft with a list\n\n- One thing\n- Another thing\n- A third thing",
            "# Daybook\n\n" + Array(repeating: "The day moved in small chapters. This is enough text to test a long downward scroll without a jump.\n\n", count: 12).joined(),
            "# Last line\n\nLeave room for the next thought."
        ]
        let additional = (10...64).map { index in "# Sample \(index)\n\nA disposable capture for testing a dense, scrollable timeline." }
        let notes = (seeds + additional).enumerated().map { index, text in
            MotionLabNote(id: "sample-\(index + 1)", capturedAt: formatter.string(from: base.addingTimeInterval(Double(index) * 3760)), text: text)
        }
        return MotionLabData(notes: notes, selectedID: notes[3].id, settings: [:])
    }
}
