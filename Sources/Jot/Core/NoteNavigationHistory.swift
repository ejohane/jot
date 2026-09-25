import Foundation

enum NoteLocation: Equatable, Hashable {
    case blank
    case note(String)
}

enum NoteNavigationDirection: Equatable {
    case latest
    case back
    case forward
}

enum NoteNavigationMovement {
    case direct
    case back
    case forward
}

struct NoteReadingPosition: Equatable {
    let selection: EditorSelection
    let viewport: EditorViewport

    static let start = NoteReadingPosition(selection: .start, viewport: .top)
}

struct NoteNavigationHistory {
    private(set) var back: [NoteLocation] = []
    private(set) var forward: [NoteLocation] = []
    private var positions: [NoteLocation: NoteReadingPosition] = [:]

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func target(for movement: NoteNavigationMovement) -> NoteLocation? {
        switch movement {
        case .direct: return nil
        case .back: return back.last
        case .forward: return forward.last
        }
    }

    func position(for location: NoteLocation) -> NoteReadingPosition {
        positions[location] ?? .start
    }

    mutating func forgetPosition(for location: NoteLocation) {
        positions.removeValue(forKey: location)
    }

    mutating func recordTransition(
        from source: NoteLocation,
        to destination: NoteLocation,
        movement: NoteNavigationMovement,
        sourcePosition: NoteReadingPosition
    ) {
        guard source != destination else { return }
        positions[source] = sourcePosition
        switch movement {
        case .direct:
            back.append(source)
            forward.removeAll()
        case .back:
            guard back.last == destination else { return }
            back.removeLast()
            forward.append(source)
        case .forward:
            guard forward.last == destination else { return }
            forward.removeLast()
            back.append(source)
        }
    }

    mutating func replaceBlank(with id: String) {
        let note = NoteLocation.note(id)
        back = back.map { $0 == .blank ? note : $0 }
        forward = forward.map { $0 == .blank ? note : $0 }
        if let position = positions.removeValue(forKey: .blank) {
            positions[note] = position
        }
    }

    mutating func reset() {
        back.removeAll()
        forward.removeAll()
        positions.removeAll()
    }
}
