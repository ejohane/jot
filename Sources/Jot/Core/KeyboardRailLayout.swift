import Foundation

/// Stable identifiers shared by the phone's rail, its picker, and saved preferences.
enum KeyboardRailAction: String, CaseIterable, Identifiable, Sendable {
    case format, checklist, image, dictation
    case bold, italic, strikethrough, code, headings
    case bulletList, numberedList, quote, indent, outdent, undo, redo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .format: "Format"
        case .checklist: "Checklist"
        case .image: "Add image"
        case .dictation: "Start dictation"
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .code: "Monospace"
        case .headings: "Headings"
        case .bulletList: "Bulleted list"
        case .numberedList: "Numbered list"
        case .quote: "Block quote"
        case .indent: "Increase indent"
        case .outdent: "Decrease indent"
        case .undo: "Undo"
        case .redo: "Redo"
        }
    }

    var symbol: String {
        switch self {
        case .format: "textformat"
        case .checklist: "checklist"
        case .image: "photo"
        case .dictation: "mic.fill"
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .headings: "h.square"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .quote: "text.quote"
        case .indent: "increase.indent"
        case .outdent: "decrease.indent"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        }
    }
}

struct KeyboardRailLayout: Equatable, Sendable {
    static let preferenceKey = "phone.keyboardRail.actions.v1"
    static let defaults: [KeyboardRailAction] = [.format, .checklist, .image, .dictation]
    private(set) var actions: [KeyboardRailAction]

    init(storedValue: String? = nil) {
        guard let storedValue, let data = storedValue.data(using: .utf8),
              let identifiers = try? JSONDecoder().decode([String].self, from: data) else {
            actions = Self.defaults
            return
        }
        var seen = Set<KeyboardRailAction>()
        actions = identifiers.compactMap(KeyboardRailAction.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    var storedValue: String {
        String(decoding: try! JSONEncoder().encode(actions.map(\.rawValue)), as: UTF8.self)
    }

    var availableActions: [KeyboardRailAction] { KeyboardRailAction.allCases.filter { !actions.contains($0) } }

    mutating func add(_ action: KeyboardRailAction) {
        guard !actions.contains(action) else { return }
        actions.append(action)
    }

    mutating func remove(_ action: KeyboardRailAction) { actions.removeAll { $0 == action } }

    mutating func move(_ action: KeyboardRailAction, to destination: Int) {
        guard let source = actions.firstIndex(of: action), actions.indices.contains(destination), source != destination else { return }
        actions.remove(at: source)
        actions.insert(action, at: destination)
    }
}
