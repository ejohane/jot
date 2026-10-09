import Foundation

/// The timestamp belongs to the device session, never the shared notebook.
enum CaptureLaunchPolicy {
    static let freshEntryInterval: TimeInterval = 5 * 60

    static func startsNewEntry(lastDeparture: Date?, now: Date) -> Bool {
        guard let lastDeparture else { return false }
        return now.timeIntervalSince(lastDeparture) >= freshEntryInterval
    }
}
