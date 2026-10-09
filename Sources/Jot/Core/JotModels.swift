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
    var panelPositionWasUserChosen: Bool?
    var rootBookmark: Data?
    var storage: NotebookStorage? = nil
    var acknowledgedData: Data? = nil
    var shortcut: ShortcutChoice
    var launchAtLogin: Bool
    var recoveryText: String?
    var recoveryRevision: Int?

    static let empty = PersistedSession(
        activeJot: nil,
        selection: .start,
        viewport: .top,
        panelFrame: nil,
        panelPositionWasUserChosen: nil,
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

enum PersistenceError: LocalizedError, Equatable, Sendable {
    case rootUnavailable
    case externalConflict
    case activeFileMissing
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .rootUnavailable: "Jot couldn’t access your notebook. Your recovery copy is kept safe."
        case .externalConflict: "This jot changed elsewhere. Keep both versions to preserve your writing."
        case .activeFileMissing: "The current jot couldn’t be found in your notebook. Your recovery copy is kept safe."
        case let .writeFailed(message): message
        }
    }

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
