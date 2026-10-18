import AppKit

@MainActor
final class DocumentWindowController: NSObject, EditorBridgeDelegate, ComposerPanelDelegate {
    let panel: ComposerPanelController
    let document: MarkdownDocument
    private(set) var state: DocumentWindowState
    private var tail: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var ready = false
    private var closing = false
    private var allowClose = false
    private var accessURL: URL?
    private var isAccessing = false
    private var capturedForTermination = false
    private let voiceDictation = VoiceDictation()
    private var droppedFiles: [URL] = []
    private var dropID: String?
    var onClose: (() -> Void)?
    var searchNotes: ((String, Int, Bool, ComposerPanelController) -> Void)?
    var openNote: ((String) -> Void)?
    var openFile: ((URL) -> Void)?

    init(document: MarkdownDocument, state: DocumentWindowState) {
        self.document = document
        self.state = state
        let url = URL(fileURLWithPath: state.path)
        panel = ComposerPanelController(savedFrame: state.frame ?? NSStringFromRect(NSRect(x: 180, y: 180, width: 620, height: 540)), documentURL: url)
        super.init()
        if let bookmark = state.bookmark {
            var stale = false
            accessURL = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            isAccessing = accessURL?.startAccessingSecurityScopedResource() == true
        }
        panel.bridge.delegate = self
        panel.panelDelegate = self
        panel.configureAttachmentRoot(url.deletingLastPathComponent(), documentImages: true)
        panel.onEscape = { [weak self] in self?.panel.send(["version": 1, "type": "escape"]) }
        panel.onCloseRequested = { [weak self] in
            guard let self else { return true }
            if self.allowClose { return true }
            self.closeDocument()
            return false
        }
        voiceDictation.onStateChange = { [weak self] status, message in
            var payload: [String: Any] = ["version": 1, "type": "dictationState", "status": status.rawValue]
            if let message { payload["message"] = message }
            self?.panel.send(payload)
        }
        voiceDictation.onResult = { [weak self] in self?.panel.send(["version": 1, "type": "dictationResult", "text": $0]) }
        voiceDictation.onPartial = { [weak self] in self?.panel.send(["version": 1, "type": "dictationPartial", "text": $0]) }
        voiceDictation.onLevel = { [weak self] in self?.panel.send(["version": 1, "type": "dictationLevel", "level": $0]) }
        panel.onImageFileDrop = { [weak self] files, point in
            guard let self else { return }
            droppedFiles = files
            let id = UUID().uuidString
            dropID = id
            panel.send(["version": 1, "type": "beginImageFileDrop", "dropID": id, "count": files.count, "x": point.x, "y": point.y])
        }
        panel.loadEditor()
        panel.showAndFocus()
    }

    deinit {
        watcher?.cancel()
        if isAccessing { accessURL?.stopAccessingSecurityScopedResource() }
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await operation() }
            catch { self.showError(error) }
        }
    }

    private func showError(_ error: any Error) {
        panel.send(["version": 1, "type": "writeFailed", "revision": state.revision,
                    "errorCode": "document_save_failed", "message": "\(error.localizedDescription) Your writing remains in this window. Resolve the saving problem and try again.",
                    "actions": ["saveCopy"]])
        panel.window?.isDocumentEdited = true
    }

    private func load(focus: Bool = false) {
        panel.send(["version": 1, "type": "loadSession", "documentWindow": true,
                    "text": state.text, "noteID": state.path, "revision": state.revision,
                    "selection": ["anchor": state.selection.anchor, "head": state.selection.head],
                    "viewport": ["scrollTop": state.viewport.scrollTop], "baseURL": "jot://attachment/", "focus": focus])
        panel.send(["version": 1, "type": "actionState", "canNew": false, "canReveal": true,
                    "canLatest": false, "canBack": false, "canForward": false])
    }

    func editorDidBecomeReady() {
        ready = false
        enqueue { [self] in
            defer { ready = true; startWatching() }
            do { state = try await document.restore(); load(focus: panel.window?.isKeyWindow == true) }
            catch { state = await document.state; load(); throw error }
        }
    }

    private func startWatching() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled, let self else { return }
                self.enqueue { [weak self] in try await self?.reconcile() }
            }
        }
    }

    private func capture() async throws {
        guard ready else { return }
        capturedForTermination = false
        let snapshot = try await panel.lockAndSnapshot()
        capturedForTermination = true
        defer { panel.unlockEditor(restoringFocus: panel.window?.isKeyWindow == true) }
        try await document.receive(snapshot)
        state = await document.state
    }

    private func reconcile() async throws {
        guard ready, !closing, await document.hasExternalChange(), !(await document.conflict) else { return }
        // Freeze only while reconciling, so a queued native snapshot cannot overwrite newer typing.
        let snapshot = try await panel.lockAndSnapshot()
        defer { panel.unlockEditor(restoringFocus: panel.window?.isKeyWindow == true) }
        try await document.receive(snapshot)
        if try await document.reconcile() {
            state = await document.state
            load()
        }
    }

    func editorContentChanged(_ snapshot: EditorSnapshot, noteID: String?) {
        guard ready, !closing, noteID == state.path else { return }
        panel.window?.isDocumentEdited = true
        enqueue { [self] in
            try await document.receive(snapshot)
            state = await document.state
            panel.window?.isDocumentEdited = false
            panel.send(["version": 1, "type": "writeSucceeded", "noteID": state.path, "revision": state.acknowledgedRevision])
        }
    }

    func editorStateChanged(selection: EditorSelection, viewport: EditorViewport) {
        guard ready, !closing else { return }
        enqueue { [self] in
            try await document.position(selection: selection, viewport: viewport, frame: panel.window.map { NSStringFromRect($0.frame) })
            state = await document.state
        }
    }

    func composerFrameDidChange(_ frame: NSRect) {
        editorStateChanged(selection: state.selection, viewport: state.viewport)
    }
    func composerDidResignKey() { guard ready, !closing else { return }; enqueue { [self] in try await capture() } }
    func editorPreferredHeightChanged(_ height: Double) {}
    func editorFormattingToolbarBoundsChanged(_ bounds: CGRect?) { panel.applyFormattingToolbarBounds(bounds) }
    func editorActionPanelChanged(visible: Bool) { panel.applyActionPanelVisibility(visible) }
    func editorRequestedFinish(revision: Int) {} // Only the designated capture window can finish a jot.
    func editorRequestedHide(revision: Int) {} // Escape dismisses editor panels; Command-W closes a document.
    func editorRequestedNavigation(_ direction: NoteNavigationDirection) {}
    func editorRequestedOpenNote(id: String, revision: Int) { openNote?(id) }
    func editorRequestedNoteSearch(query: String, requestID: Int, refresh: Bool) { searchNotes?(query, requestID, refresh, panel) }
    func editorRequestedNoteAction(_ action: String, text: String?, revision: Int) {
        switch action {
        case "copyNote": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text ?? state.text, forType: .string)
        case "revealInFinder": NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: state.path)])
        case "openNotesFolder": NSWorkspace.shared.open(URL(fileURLWithPath: state.path).deletingLastPathComponent())
        default: break
        }
    }
    func editorRequestedRecovery(_ action: String) {
        guard action == "saveCopy" else { return }
        enqueue { [self] in
            // Capture may fail on the conflicting write; its journal still holds the exact editor text.
            try? await capture()
            let copy = try await document.keepBothAndReload()
            state = await document.state
            panel.window?.isDocumentEdited = false
            load(focus: true)
            let alert = NSAlert()
            alert.messageText = "Both versions are safe"
            alert.informativeText = "Your version was saved as \(copy.lastPathComponent). This window now shows the original file’s outside version."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: panel.window!, completionHandler: nil)
        }
    }
    func editorRequestedImageImport(requestID: String) {
        guard let data = NSPasteboard.general.data(forType: .png)
            ?? NSPasteboard.general.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else {
            imageFailed(requestID); return
        }
        importImage(data, requestID: requestID)
    }
    func editorRequestedDroppedImage(requestID: String, base64Data: String) {
        guard let data = Data(base64Encoded: base64Data) else { imageFailed(requestID); return }
        importImage(data, requestID: requestID)
    }
    func editorRequestedDroppedFile(requestID: String, dropID: String) {
        guard self.dropID == dropID, !droppedFiles.isEmpty else { imageFailed(requestID); return }
        let file = droppedFiles.removeFirst()
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20 * 1024 * 1024,
              let data = try? Data(contentsOf: file) else { imageFailed(requestID); return }
        importImage(data, requestID: requestID)
    }
    private func imageFailed(_ id: String) {
        panel.send(["version": 1, "type": "imageImportFailed", "requestID": id, "message": "The image could not be saved beside this document. Check its folder permissions and try again."])
    }
    private func importImage(_ data: Data, requestID: String) {
        guard let tiff = NSImage(data: data)?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { imageFailed(requestID); return }
        enqueue { [self] in
            do {
                let relative = "attachments/\(UUID().uuidString)/image.png"
                let file = URL(fileURLWithPath: state.path).deletingLastPathComponent().appendingPathComponent(relative)
                try LocalJotFileSystem().writeAtomically(png, to: file)
                panel.send(["version": 1, "type": "imageImported", "requestID": requestID, "path": relative, "baseURL": "jot://attachment/"])
            } catch { imageFailed(requestID) }
        }
    }
    func editorRequestedDocumentLink(path: String) {
        let directory = URL(fileURLWithPath: state.path).deletingLastPathComponent().appendingPathComponent("", isDirectory: true)
        guard let url = URL(string: path, relativeTo: directory)?.absoluteURL, url.isFileURL else { return }
        if MarkdownFile.accepts(url) { openFile?(url) }
        else { NSWorkspace.shared.open(url) }
    }

    func editorRequestedImagePreview(path: String) {
        let root = URL(fileURLWithPath: state.path).deletingLastPathComponent()
        if let url = LocalResourceSchemeHandler.attachmentURL(path: path, root: root, documentImages: true) { panel.previewImage(at: url) }
    }
    func editorRequestedDictationToggle() { voiceDictation.toggle() }
    func editorRequestedDictationFinish() { voiceDictation.finish() }
    func editorRequestedDictationCancel() { voiceDictation.cancel() }

    private func closeDocument() {
        guard !closing, ready else { return }
        closing = true
        enqueue { [self] in
            do {
                try await capture()
                try await document.close()
                watcher?.cancel()
                voiceDictation.cancel()
                allowClose = true
                panel.close()
                onClose?()
            } catch { closing = false; throw error }
        }
    }

    func prepareToTerminate() async -> Bool {
        voiceDictation.cancel()
        await tail?.value
        guard ready else { return false }
        do { try await capture(); return true }
        catch {
            showError(error)
            // A conflict is safe to restore only when the current editor snapshot is journaled.
            guard capturedForTermination else { return false }
            do { try await document.checkpoint(); return true }
            catch { return false }
        }
    }
}
