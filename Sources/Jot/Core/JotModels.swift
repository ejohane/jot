import Foundation

struct EditorSelection: Codable, Equatable, Sendable {
    var anchor: Int
    var head: Int

    static let start = EditorSelection(anchor: 0, head: 0)
}

struct EditorViewport: Codable, Equatable, Sendable {
    var scrollTop: Double

    static let top = EditorViewport(scrollTop: 0)
}

struct ActiveJot: Codable, Equatable, Sendable {
    let id: String
    let path: String
    var acknowledgedRevision: Int
}

struct PersistedSession: Codable, Equatable, Sendable {
    var activeJot: ActiveJot?
    var selection: EditorSelection
    var viewport: EditorViewport
    var panelFrame: String?
    var rootBookmark: Data?
    var shortcut: ShortcutChoice
    var launchAtLogin: Bool
    var recoveryText: String?
    var recoveryRevision: Int?

    static let empty = PersistedSession(
        activeJot: nil,
        selection: .start,
        viewport: .top,
        panelFrame: nil,
        rootBookmark: nil,
        shortcut: .optionSpace,
        launchAtLogin: false,
        recoveryText: nil,
        recoveryRevision: nil
    )
}

enum ShortcutChoice: String, Codable, CaseIterable, Sendable {
    case optionSpace
    case controlSpace
    case commandShiftJ

    var displayName: String {
        switch self {
        case .optionSpace: "Option-Space"
        case .controlSpace: "Control-Space"
        case .commandShiftJ: "Command-Shift-J"
        }
    }
}

struct EditorSnapshot: Equatable, Sendable {
    let revision: Int
    let text: String
    let selection: EditorSelection
    let viewport: EditorViewport
}

enum PersistenceError: Error, Equatable, Sendable {
    case rootUnavailable
    case externalConflict
    case activeFileMissing
    case writeFailed(String)

    var code: String {
        switch self {
        case .rootUnavailable: "root_unavailable"
        case .externalConflict: "external_conflict"
        case .activeFileMissing: "active_file_missing"
        case .writeFailed: "write_failed"
        }
    }
}

enum WriterEvent: Equatable, Sendable {
    case noteAllocated(id: String, path: String, revision: Int)
    case saving(revision: Int)
    case writeSucceeded(id: String, revision: Int)
    case writeFailed(id: String?, revision: Int, error: PersistenceError)
    case externalConflict(id: String, revision: Int)
}
