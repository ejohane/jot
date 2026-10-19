import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: KeyboardShortcuts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            Text("Click a shortcut, then press a new key combination. Changes apply immediately.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Section("Capture") {
                    row(.showJot, detail: "Available from any app")
                    row(.finishAndNew)
                    row(.newNote)
                    row(.hideJot)
                }
                Section("Application") {
                    row(.changeFolder)
                    row(.settings)
                    row(.quit)
                    row(.openFile)
                    row(.closeWindow)
                    row(.fullScreen)
                }
                Section("Navigation") {
                    ForEach([ShortcutAction.actions, .searchNotes, .find, .findNext, .findPrevious, .latest, .back, .forward], id: \.self) { row($0) }
                }
                Section("Formatting and Voice") {
                    ForEach([ShortcutAction.bold, .italic, .dictation, .focusToolbar], id: \.self) { row($0) }
                }
                Section("Editing") {
                    ForEach([ShortcutAction.undo, .redo, .cut, .copy, .paste, .selectAll], id: \.self) { row($0) }
                }
            }
            .formStyle(.grouped)
            if let error = shortcuts.error {
                Text(error).font(.callout).foregroundStyle(.red).accessibilityLabel("Shortcut error: \(error)")
            }
            HStack {
                if shortcuts.recording != nil {
                    Button("Cancel Recording") { shortcuts.recording = nil; shortcuts.error = nil }
                }
                Spacer()
                Button("Restore Defaults") { shortcuts.reset() }
            }
        }
        .padding(20)
        .frame(width: 540, height: 580)
        .onDisappear { shortcuts.recording = nil }
    }

    private func row(_ action: ShortcutAction, detail: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button {
                shortcuts.error = nil
                shortcuts.recording = shortcuts.recording == action ? nil : action
            } label: {
                Text(shortcuts.recording == action ? "Press shortcut…" : shortcuts[action].displayName)
                    .monospaced()
                    .frame(minWidth: 126)
            }
            .accessibilityLabel("\(action.title) shortcut")
            .accessibilityValue(shortcuts.recording == action ? "Recording" : shortcuts[action].displayName)
            .help("Record a shortcut for \(action.title)")
        }
    }
}
