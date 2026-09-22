import Foundation

struct JotAllocation: Equatable, Sendable {
    let id: String
    let fileURL: URL
}

struct JotPathAllocator: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func allocate(root: URL, at date: Date = Date(), id: String? = nil) -> JotAllocation {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let milliseconds = Int((date.timeIntervalSince1970 * 1_000).rounded(.down)) % 1_000
        let identifier = id ?? ULID.make(timestamp: date)
        let directory = root
            .appendingPathComponent(String(format: "%04d", components.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day ?? 0), isDirectory: true)
        let filename = String(
            format: "%02d-%02d-%02d-%03d--%@.md",
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            milliseconds,
            identifier
        )
        return JotAllocation(id: identifier, fileURL: directory.appendingPathComponent(filename))
    }
}
