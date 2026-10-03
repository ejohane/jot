import Foundation

/// iOS can move an app's data container during installation. Notebook paths remain
/// relative to Documents/Jots, while the container UUID is not a durable identity.
enum AppContainerNotePath {
    static func relocate(_ jot: ActiveJot, to root: URL) -> ActiveJot? {
        let parts = URL(fileURLWithPath: jot.path).pathComponents
        guard !parts.contains(".."),
              let index = parts.indices.first(where: { index in
                  index + 5 < parts.count && Array(parts[index...index + 2]) == ["Containers", "Data", "Application"]
                  && parts[index + 4] == "Documents" && parts[index + 5] == "Jots"
              }), index + 6 < parts.count else { return nil }
        let relative = parts[(index + 6)...].joined(separator: "/")
        return ActiveJot(id: jot.id, path: root.appendingPathComponent(relative).path,
                         acknowledgedRevision: jot.acknowledgedRevision)
    }
}
