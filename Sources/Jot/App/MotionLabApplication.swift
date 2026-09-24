#if JOT_MOTION_LAB
import AppKit

// Developer mode of Jot itself. It uses the real ComposerPanelController,
// EditorBridge, WKWebView, and Editor.tsx; only its note store is disposable.
@MainActor
final class MotionLabApplication: NSObject, NSApplicationDelegate, EditorBridgeDelegate, ComposerPanelDelegate {
    private let store = MotionLabStore()
    private var panelController: ComposerPanelController?
    private var stateSaveTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let panel = ComposerPanelController(savedFrame: nil, motionLabMode: true)
        panel.bridge.delegate = self
        panel.panelDelegate = self
        panel.onEscape = { [weak panel] in panel?.hide() }
        panelController = panel
        panel.loadEditor()
        panel.showAndFocus()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.showAndFocus()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stateSaveTask?.cancel()
        return store.flush() ? .terminateNow : .terminateCancel
    }

    func editorDidBecomeReady() { sendSelectedNote() }

    func editorContentChanged(_ snapshot: EditorSnapshot, noteID: String?) {
        guard noteID == store.data.selectedID else { return }
        let saved = store.save(
            id: store.data.selectedID,
            text: snapshot.text,
            anchor: snapshot.selection.anchor,
            head: snapshot.selection.head,
            scrollTop: snapshot.viewport.scrollTop
        )
        panelController?.send(saved
            ? ["version": 1, "type": "writeSucceeded", "noteID": store.data.selectedID, "revision": snapshot.revision]
            : ["version": 1, "type": "writeFailed", "noteID": store.data.selectedID,
               "revision": snapshot.revision, "errorCode": "motionLabSave", "message": "Sample note could not be saved.", "actions": []])
    }

    func editorStateChanged(selection: EditorSelection, viewport: EditorViewport) {
        store.updateState(id: store.data.selectedID, anchor: selection.anchor, head: selection.head, scrollTop: viewport.scrollTop)
        stateSaveTask?.cancel()
        stateSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            _ = self?.store.flush()
        }
    }

    func editorPreferredHeightChanged(_ height: Double) {}
    func editorRequestedFinish(revision: Int) {}
    func editorRequestedHide(revision: Int) { _ = store.flush(); panelController?.hide() }
    func editorRequestedRecovery(_ action: String) {}
    func editorRequestedDictationToggle() {}
    func editorRequestedDictationFinish() {}
    func editorRequestedDictationCancel() {}
    func composerDidResignKey() {}
    func composerFrameDidChange(_ frame: NSRect) {}

    func labRequestedSelection(_ id: String) {
        stateSaveTask?.cancel()
        if store.select(id: id) { sendSelectedNote() }
        else { sendLabError() }
    }

    func labRequestedSettings(_ values: [String: Double]) { store.saveSettings(values) }
    func labRequestedReset() {
        if store.reset() { sendSelectedNote() }
        else { sendLabError() }
    }
    func labRequestedExport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.settingsJSON(), forType: .string)
        panelController?.send(["version": 1, "type": "labExported"])
    }

    private func sendSelectedNote() {
        guard let note = store.data.notes.first(where: { $0.id == store.data.selectedID }) else { return }
        panelController?.send([
            "version": 1, "type": "loadSession", "text": note.text, "noteID": note.id,
            "revision": 0, "selection": ["anchor": note.anchor, "head": note.head],
            "viewport": ["scrollTop": note.scrollTop],
        ])
        panelController?.send(["version": 1, "type": "labHydrate", "payload": store.payload()])
    }

    private func sendLabError() {
        panelController?.send(["version": 1, "type": "writeFailed", "noteID": store.data.selectedID,
                               "revision": 0, "errorCode": "motionLabSave", "message": "Sample note could not be saved. Navigation was blocked.", "actions": []])
    }
}
#endif
