import AppKit
import Carbon.HIToolbox

struct KeyChord: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let key: String
    let modifiers: UInt

    init(_ keyCode: UInt16, _ key: String, _ flags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.key = key.lowercased()
        modifiers = flags.intersection(Self.allowedModifiers).rawValue
    }

    static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var displayName: String {
        let symbol: String = switch keyCode {
        case 36: "↩"
        case 48: "⇥"
        case 49: "Space"
        case 51: "⌫"
        case 53: "⎋"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        case 109: "F10"
        default: key.uppercased()
        }
        return (flags.contains(.control) ? "⌃" : "")
            + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "") + symbol
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection(Self.allowedModifiers) == flags
    }

    static func legacy(_ choice: ShortcutChoice) -> KeyChord {
        switch choice {
        case .optionSpace: KeyChord(49, " ", .option)
        case .controlSpace: KeyChord(49, " ", .control)
        case .commandShiftJ: KeyChord(38, "j", [.command, .shift])
        }
    }
}

enum ShortcutAction: String, CaseIterable, Sendable {
    case showJot, finishAndNew, hideJot, changeFolder, settings, quit
    case undo, redo, cut, copy, paste, selectAll
    case newNote, openFile, closeWindow, fullScreen, actions, searchNotes, find, findNext, findPrevious
    case bold, italic, dictation, latest, back, forward, focusToolbar

    var title: String {
        switch self {
        case .newNote: "New Note"
        case .openFile: "Open File"
        case .closeWindow: "Close Window"
        case .fullScreen: "Toggle Full Screen"
        case .actions: "Actions"
        case .searchNotes: "Search Notes"
        case .find: "Find in Note"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .bold: "Bold"
        case .italic: "Italic"
        case .dictation: "Start / Stop Dictation"
        case .latest: "Latest Jot"
        case .back: "Go Back"
        case .forward: "Go Forward"
        case .focusToolbar: "Focus Formatting Toolbar"
        case .showJot: "Show Jot"
        case .finishAndNew: "Finish & New"
        case .hideJot: "Hide Jot"
        case .changeFolder: "Change Jots Folder"
        case .settings: "Settings"
        case .quit: "Quit Jot"
        case .undo: "Undo"
        case .redo: "Redo"
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select All"
        }
    }

    var defaultChord: KeyChord {
        switch self {
        case .newNote: KeyChord(45, "n", .command)
        case .openFile: KeyChord(31, "o", .command)
        case .closeWindow: KeyChord(13, "w", .command)
        case .fullScreen: KeyChord(3, "f", [.control, .command])
        case .actions: KeyChord(40, "k", .command)
        case .searchNotes: KeyChord(35, "p", .command)
        case .find: KeyChord(3, "f", .command)
        case .findNext: KeyChord(5, "g", .command)
        case .findPrevious: KeyChord(5, "g", [.command, .shift])
        case .bold: KeyChord(11, "b", .command)
        case .italic: KeyChord(34, "i", .command)
        case .dictation: KeyChord(2, "d", [.command, .shift])
        case .latest: KeyChord(37, "l", .command)
        case .back: KeyChord(33, "[", .command)
        case .forward: KeyChord(30, "]", .command)
        case .focusToolbar: KeyChord(109, String(UnicodeScalar(NSF10FunctionKey)!), .option)
        case .showJot: KeyChord(49, " ", .option)
        case .finishAndNew: KeyChord(36, "\r", .command)
        case .hideJot: KeyChord(53, "\u{1b}", [])
        case .changeFolder: KeyChord(38, "j", [.command, .option])
        case .settings: KeyChord(43, ",", .command)
        case .quit: KeyChord(12, "q", .command)
        case .undo: KeyChord(6, "z", .command)
        case .redo: KeyChord(6, "z", [.command, .shift])
        case .cut: KeyChord(7, "x", .command)
        case .copy: KeyChord(8, "c", .command)
        case .paste: KeyChord(9, "v", .command)
        case .selectAll: KeyChord(0, "a", .command)
        }
    }
}

@MainActor
final class KeyboardShortcuts: ObservableObject {
    @Published private(set) var bindings: [String: KeyChord]
    @Published var recording: ShortcutAction? {
        didSet { onRecordingChanged?(recording != nil) }
    }
    @Published var error: String?
    var apply: (([String: KeyChord]) throws -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    init(session: PersistedSession) {
        var bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, $0.defaultChord) })
        bindings[ShortcutAction.showJot.rawValue] = .legacy(session.shortcut)
        for (key, value) in session.keyboardShortcuts ?? [:] where ShortcutAction(rawValue: key) != nil {
            bindings[key] = value
        }
        self.bindings = bindings
    }

    subscript(_ action: ShortcutAction) -> KeyChord { bindings[action.rawValue] ?? action.defaultChord }

    func assign(_ chord: KeyChord, to action: ShortcutAction) {
        guard !chord.flags.intersection([.command, .option, .control]).isEmpty
                || (action == .hideJot && chord.keyCode == 53 && chord.flags.isEmpty) else {
            error = "Include Command, Option, or Control in the shortcut."
            return
        }
        if let conflict = ShortcutAction.allCases.first(where: {
            $0 != action && self[$0].keyCode == chord.keyCode && self[$0].modifiers == chord.modifiers
        }) {
            error = "\(chord.displayName) is already used for \(conflict.title)."
            return
        }
        var proposed = bindings
        proposed[action.rawValue] = chord
        commit(proposed)
    }

    func reset() {
        commit(Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, $0.defaultChord) }))
    }

    private func commit(_ proposed: [String: KeyChord]) {
        do {
            try apply?(proposed)
            bindings = proposed
            error = nil
            recording = nil
        } catch {
            self.error = "That global shortcut is unavailable. Your current shortcuts are still active."
        }
    }
}
