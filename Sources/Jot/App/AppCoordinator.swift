import AppKit
import ServiceManagement

@MainActor
final class AppCoordinator: NSObject, EditorBridgeDelegate, ComposerPanelDelegate, NSMenuItemValidation {
    private let sessionStore: SessionStore
    private let rootAccess = RootAccessController()
    private let appUpdater = AppUpdater()
    private let voiceDictation = VoiceDictation()
    private let tagIndex = TagIndex()
    private var noteRailIndex: NoteRailIndex!
    private var noteSearchIndex: NoteSearchIndex!
    private var railNoteIDs: Set<String> = []
    private var latestRailID: String?
    private var navigation = NoteNavigationHistory()
    private var hasBlankCapture = false
    private var isOpeningNote = false
    private var noteSearchTask: Task<Void, Never>?
    private var isImportingImage = false
    private var droppedImageFiles: [URL] = []
    private var imageDropID: String?
    private var tagRefreshTask: Task<Void, Never>?
    private var sentTags: [String] = []
    private var session: PersistedSession
    private var rootURL: URL?
    private var writer: JotWriter!
    private var panelController: ComposerPanelController!
    private var shortcut: GlobalShortcut!
    private var statusItem: NSStatusItem!
    private var latestRevision = 0
    private var documentGeneration = 0
    private var sessionGeneration = 0
    private var shortcutRegistrationFailed = false
    private var hasBlockingWriteError = false

    init(session: PersistedSession, sessionStore: SessionStore) {
        self.session = session
        self.sessionStore = sessionStore
        super.init()

        hasBlankCapture = session.activeJot == nil
        rootURL = rootAccess.restore(from: session.rootBookmark)
        noteRailIndex = NoteRailIndex(root: rootURL)
        noteSearchIndex = NoteSearchIndex(root: rootURL)
        Task { await tagIndex.configure(root: rootURL); await refreshTags(force: true) }
        hasBlockingWriteError = session.activeJot != nil && rootURL == nil
        writer = JotWriter(rootURL: rootURL) { [weak self] event in self?.handle(event) }
        panelController = ComposerPanelController(
            savedFrame: session.panelPositionWasUserChosen == true ? session.panelFrame : nil
        )
        panelController.configureAttachmentRoot(rootURL)
        panelController.bridge.delegate = self
        panelController.panelDelegate = self
        voiceDictation.onStateChange = { [weak self] state, message in
            var payload: [String: Any] = ["version": 1, "type": "dictationState", "status": state.rawValue]
            if let message { payload["message"] = message }
            self?.panelController.send(payload)
        }
        voiceDictation.onResult = { [weak self] text in
            self?.panelController.send(["version": 1, "type": "dictationResult", "text": text])
        }
        voiceDictation.onPartial = { [weak self] text in
            self?.panelController.send(["version": 1, "type": "dictationPartial", "text": text])
        }
        voiceDictation.onLevel = { [weak self] level in
            self?.panelController.send(["version": 1, "type": "dictationLevel", "level": level])
        }
        panelController.onEscape = { [weak self] in
            guard let self else { return }
            self.panelController.send(["version": 1, "type": "escape"])
        }
        panelController.onImageFileDrop = { [weak self] files, point in
            guard let self else { return }
            self.droppedImageFiles = files
            let dropID = UUID().uuidString
            self.imageDropID = dropID
            self.panelController.send(["version": 1, "type": "beginImageFileDrop", "dropID": dropID,
                                       "count": files.count, "x": point.x, "y": point.y])
        }
        shortcut = GlobalShortcut { [weak self] in self?.showJot() }
        let candidates = [session.shortcut] + ShortcutChoice.allCases.filter { $0 != session.shortcut }
        if let registered = candidates.first(where: { choice in
            do {
                try shortcut.register(choice)
                return true
            } catch {
                return false
            }
        }) {
            self.session.shortcut = registered
        } else {
            shortcutRegistrationFailed = true
        }
        appUpdater.start()
        configureApplicationMenu()
        configureStatusItem()
    }

    func start() {
        panelController.loadEditor()
        panelController.showAndFocus()
        tagRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await self?.refreshTags()
            }
        }
    }

    func show() {
        panelController.showAndFocus()
        Task { await refreshRail() }
    }

    func prepareToTerminate(completion: @escaping (Bool) -> Void) {
        tagRefreshTask?.cancel()
        voiceDictation.cancel()
        Task {
            let flushed = await writer.flush(through: latestRevision)
            let savedRecovery = await persistSessionNow()
            let mayTerminate = Self.mayTerminate(
                flushed: flushed,
                savedRecovery: savedRecovery,
                hasRecoveryText: session.recoveryText != nil
            )
            if !mayTerminate {
                sendError(
                    message: "Jot could not save its recovery state. It will stay open; try quitting again.",
                    actions: []
                )
            }
            completion(mayTerminate)
        }
    }

    static func mayTerminate(flushed: Bool, savedRecovery: Bool, hasRecoveryText: Bool) -> Bool {
        savedRecovery && (flushed || hasRecoveryText)
    }

    private func imageBaseURL(for path: String) -> String? {
        guard let rootURL else { return nil }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard directory == rootURL.path || directory.hasPrefix(rootURL.path + "/") else { return nil }
        let relative = directory == rootURL.path ? "" : String(directory.dropFirst(rootURL.path.count + 1))
        return "jot://attachment/" + relative.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/") + (relative.isEmpty ? "" : "/")
    }

    func editorRequestedImageImport(requestID: String) {
        guard let data = NSPasteboard.general.data(forType: .png)
            ?? NSPasteboard.general.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else {
            imageImportFailed(requestID: requestID, message: "The clipboard image could not be read. Copy it again and retry.")
            return
        }
        importImageData(data, requestID: requestID)
    }

    func editorRequestedDroppedImage(requestID: String, base64Data: String) {
        guard let data = Data(base64Encoded: base64Data), !data.isEmpty,
              let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            imageImportFailed(requestID: requestID, message: "This image could not be read. Try another image file.")
            return
        }
        importImageData(png, requestID: requestID)
    }

    func editorRequestedDroppedFile(requestID: String, dropID: String) {
        guard dropID == imageDropID, !droppedImageFiles.isEmpty else {
            imageImportFailed(requestID: requestID, message: "The dropped image is no longer available. Drop it again.")
            return
        }
        let file = droppedImageFiles.removeFirst()
        if droppedImageFiles.isEmpty { imageDropID = nil }
        let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if fileSize > 20 * 1024 * 1024 {
            droppedImageFiles = []
            imageDropID = nil
            imageImportFailed(requestID: requestID, message: "Images over 20 MB cannot be dropped yet.")
            return
        }
        guard let data = try? Data(contentsOf: file),
              let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            droppedImageFiles = []
            imageDropID = nil
            imageImportFailed(requestID: requestID, message: "This image could not be read. Try dropping it again.")
            return
        }
        importImageData(png, requestID: requestID)
    }

    private func imageImportFailed(requestID: String, message: String) {
        panelController.send(["version": 1, "type": "imageImportFailed", "requestID": requestID,
                              "message": message])
    }

    private func importImageData(_ data: Data, requestID: String) {
        guard !isImportingImage, !isOpeningNote else {
            imageImportFailed(requestID: requestID, message: "Wait for the current image to finish importing, then try again.")
            return
        }
        isImportingImage = true
        Task {
            defer { isImportingImage = false }
            do {
                let result = try await writer.importAttachment(data, fileExtension: "png")
                if session.activeJot == nil {
                    handle(.noteAllocated(id: result.jot.id, path: result.jot.path, revision: latestRevision))
                }
                panelController.preservesFrameForImages = true
                panelController.send(["version": 1, "type": "imageImported", "requestID": requestID,
                                      "path": result.relativePath,
                                      "baseURL": imageBaseURL(for: result.jot.path) ?? ""])
            } catch {
                imageImportFailed(requestID: requestID, message: "Image import failed. Your note is unchanged. Restore folder access if needed, then try again.")
            }
        }
    }

    func editorRequestedImagePreview(path: String) {
        guard let rootURL, let file = LocalResourceSchemeHandler.attachmentURL(path: path, root: rootURL) else { return }
        panelController.previewImage(at: file)
    }

    func editorDidBecomeReady() {
        Task { await refreshTags(force: true) }
        Task { await refreshRail() }
        panelController.send(["version": 1, "type": "dictationState", "status": voiceDictation.state.rawValue])
        if let activeJot = session.activeJot, rootURL == nil {
            hasBlockingWriteError = true
            Task {
                let text = await writer.restoreWithoutFileAccess(
                    activeJot,
                    recoveryText: session.recoveryText,
                    recoveryRevision: session.recoveryRevision
                )
                latestRevision = max(session.recoveryRevision ?? 0, activeJot.acknowledgedRevision)
                sendLoadSession(text: text)
                sendError(
                    message: "The Jots folder is unavailable. Restore folder access to continue saving.",
                    actions: ["restoreRoot", "saveCopy"]
                )
            }
            return
        }
        Task {
            do {
                let text = try await writer.restore(
                    session.activeJot,
                    recoveryText: session.recoveryText,
                    recoveryRevision: session.recoveryRevision
                )
                latestRevision = session.activeJot?.acknowledgedRevision ?? 0
                hasBlockingWriteError = false
                session.recoveryText = session.activeJot == nil ? nil : text
                session.recoveryRevision = session.activeJot?.acknowledgedRevision
                sendLoadSession(text: text)
                chooseRootIfNeeded()
                if shortcutRegistrationFailed {
                    sendError(message: "No global shortcut could be registered. Use the Jot menu-bar item to show the composer.", actions: [])
                }
            } catch {
                hasBlockingWriteError = true
                let recoveryText = session.recoveryText
                    ?? session.activeJot.flatMap { try? String(contentsOfFile: $0.path, encoding: .utf8) }
                    ?? ""
                latestRevision = max(session.recoveryRevision ?? 0, session.activeJot?.acknowledgedRevision ?? 0)
                sendLoadSession(text: recoveryText)
                sendError(
                    message: "The previous jot could not be reopened. Choose a valid folder or save the recovered text as a copy.",
                    actions: ["restoreRoot", "saveCopy"]
                )
            }
        }
    }

    func editorContentChanged(_ snapshot: EditorSnapshot, noteID: String?) {
        if let noteID, noteID != session.activeJot?.id { return }
        let generation = documentGeneration
        latestRevision = max(latestRevision, snapshot.revision)
        session.selection = snapshot.selection
        session.viewport = snapshot.viewport
        session.recoveryText = snapshot.text
        if Self.containsImageAttachment(snapshot.text) { panelController.preservesFrameForImages = true }
        session.recoveryRevision = snapshot.revision
        Task {
            guard documentGeneration == generation else { return }
            await writer.receive(snapshot)
        }
    }

    func editorStateChanged(selection: EditorSelection, viewport: EditorViewport) {
        session.selection = selection
        session.viewport = viewport
    }

    func editorPreferredHeightChanged(_ height: Double) {
        panelController.applyPreferredContentHeight(height)
    }

    func editorFormattingToolbarBoundsChanged(_ bounds: CGRect?) {
        panelController.applyFormattingToolbarBounds(bounds)
    }

    func editorRequestedNoteSearch(query: String, requestID: Int, refresh: Bool) {
        let currentID = session.activeJot?.id
        let currentText = session.recoveryText
        noteSearchTask?.cancel()
        guard rootURL != nil else {
            panelController.send(["version": 1, "type": "noteSearchResults", "requestID": requestID, "results": [],
                                  "message": "Choose an accessible Jots folder to search your notes."])
            return
        }
        noteSearchTask = Task {
            guard let results = await noteSearchIndex.search(query: query, refresh: refresh, currentID: currentID, currentText: currentText), !Task.isCancelled else { return }
            panelController.send([
                "version": 1, "type": "noteSearchResults", "requestID": requestID,
                "results": results.map { result in [
                    "id": result.id, "timestamp": Int(result.timestamp.timeIntervalSince1970 * 1_000),
                    "title": result.title, "excerpt": result.excerpt,
                    "titleMatches": result.titleMatches.map { ["from": $0.from, "to": $0.to] },
                    "excerptMatches": result.excerptMatches.map { ["from": $0.from, "to": $0.to] },
                ] as [String: Any] },
            ])
        }
    }

    func editorActionPanelChanged(visible: Bool) {
        panelController.applyActionPanelVisibility(visible)
        if visible { sendActionState() }
    }

    func editorRequestedNoteAction(_ action: String, text: String?, revision: Int) {
        switch action {
        case "copyNote":
            guard let text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "openNotesFolder":
            openJotsFolder()
        case "revealInFinder":
            Task {
                guard await writer.flush(through: revision) else { return }
                revealCurrentJot()
            }
        default: break
        }
    }

    private func sendActionState() {
        panelController.send([
            "version": 1, "type": "actionState",
            "canNew": Self.finishAndNewIsEnabled(activeJot: session.activeJot, hasBlockingWriteError: hasBlockingWriteError) && !isOpeningNote,
            "canReveal": session.activeJot != nil && rootURL != nil,
            "canLatest": !isOpeningNote && (hasBlankCapture || latestRailID != nil),
            "canBack": navigation.canGoBack && !isOpeningNote,
            "canForward": navigation.canGoForward && !isOpeningNote,
        ])
    }

    func editorRequestedFinish(revision: Int) {
        guard !isOpeningNote, !isImportingImage else { return }
        isOpeningNote = true
        voiceDictation.cancel()
        Task {
            defer { isOpeningNote = false; sendActionState() }
            guard await writer.currentJot() != nil else { return }
            guard await writer.finishAndNew(through: revision) else { return }
            let source = currentLocation
            navigation.forgetPosition(for: .blank)
            navigation.recordTransition(
                from: source,
                to: .blank,
                movement: .direct,
                sourcePosition: currentReadingPosition
            )
            hasBlankCapture = true
            documentGeneration += 1
            session.activeJot = nil
            session.selection = .start
            session.viewport = .top
            session.recoveryText = nil
            session.recoveryRevision = nil
            latestRevision = 0
            hasBlockingWriteError = false
            await persistSessionNow()
            sendLoadSession(text: "")
            await refreshRail()
        }
    }

    func editorRequestedOpenNote(id: String, revision: Int) {
        openNote(id: id, revision: revision, movement: .direct)
    }

    func editorRequestedNavigation(_ direction: NoteNavigationDirection) {
        navigate(direction)
    }

    private var currentLocation: NoteLocation {
        session.activeJot.map { .note($0.id) } ?? .blank
    }

    private var currentReadingPosition: NoteReadingPosition {
        NoteReadingPosition(selection: session.selection, viewport: session.viewport)
    }

    private func openNote(id: String, revision: Int, movement: NoteNavigationMovement) {
        guard !isOpeningNote, !isImportingImage, currentLocation != .note(id) else { return }
        isOpeningNote = true
        voiceDictation.cancel()
        Task {
            defer { isOpeningNote = false; sendActionState() }
            let railEntry = await noteRailIndex.entry(id: id)
            let searchEntry = await noteSearchIndex.entry(id: id)
            guard let entry = railEntry ?? searchEntry else { return }
            do {
                let result = try await writer.openExisting(id: id, path: entry.path, through: revision)
                let source = currentLocation
                let destination = NoteLocation.note(id)
                navigation.recordTransition(
                    from: source,
                    to: destination,
                    movement: movement,
                    sourcePosition: currentReadingPosition
                )
                let position = navigation.position(for: destination)
                documentGeneration += 1
                session.activeJot = result.jot
                session.selection = position.selection
                session.viewport = position.viewport
                session.recoveryText = result.text
                session.recoveryRevision = 0
                latestRevision = 0
                hasBlockingWriteError = false
                await persistSessionNow()
                sendLoadSession(text: result.text)
            } catch {
                if !(await writer.hasBlockingError) {
                    let message = (error as? PersistenceError) == .activeFileMissing
                        ? "This jot is no longer available."
                        : "Could not switch notes. Save the current jot and try again."
                    sendError(message: message, actions: [])
                }
                await refreshRail()
            }
        }
    }

    private func openBlankCapture(movement: NoteNavigationMovement) {
        guard !isOpeningNote, !isImportingImage, currentLocation != .blank else { return }
        isOpeningNote = true
        voiceDictation.cancel()
        Task {
            defer { isOpeningNote = false; sendActionState() }
            guard await writer.finishAndNew(through: latestRevision) else { return }
            let position = navigation.position(for: .blank)
            navigation.recordTransition(
                from: currentLocation,
                to: .blank,
                movement: movement,
                sourcePosition: currentReadingPosition
            )
            documentGeneration += 1
            session.activeJot = nil
            session.selection = position.selection
            session.viewport = position.viewport
            session.recoveryText = nil
            session.recoveryRevision = nil
            latestRevision = 0
            hasBlockingWriteError = false
            await persistSessionNow()
            sendLoadSession(text: "")
        }
    }

    private func navigate(_ direction: NoteNavigationDirection) {
        guard !isOpeningNote, !isImportingImage else { return }
        let movement: NoteNavigationMovement
        let destination: NoteLocation?
        switch direction {
        case .back:
            movement = .back
            destination = navigation.target(for: .back)
        case .forward:
            movement = .forward
            destination = navigation.target(for: .forward)
        case .latest:
            movement = .direct
            if hasBlankCapture {
                destination = .blank
            } else {
                if latestRailID == nil {
                    Task {
                        await refreshRail()
                        if latestRailID != nil { navigate(.latest) }
                    }
                    return
                }
                destination = latestRailID.map(NoteLocation.note)
            }
        }
        guard let destination, destination != currentLocation else { return }
        switch destination {
        case .blank:
            openBlankCapture(movement: movement)
        case let .note(id):
            openNote(id: id, revision: latestRevision, movement: movement)
        }
    }

    func editorRequestedHide(revision: Int) {
        voiceDictation.cancel()
        Task {
            _ = await writer.flush(through: revision)
            await persistSessionNow()
            panelController.hide()
        }
    }

    func editorRequestedRecovery(_ action: String) {
        switch action {
        case "restoreRoot":
            chooseRoot()
        case "saveCopy":
            Task {
                if let jot = await writer.saveCurrentVersionAsCopy() {
                    hasBlockingWriteError = false
                    session.activeJot = jot
                    panelController.send([
                        "version": 1,
                        "type": "noteAllocated",
                        "noteID": jot.id,
                        "path": jot.path,
                        "revision": jot.acknowledgedRevision,
                    ])
                    await persistSessionNow()
                }
            }
        case "reloadExternal":
            let alert = NSAlert()
            alert.messageText = "Reload the external version?"
            alert.informativeText = "Unsaved differences currently visible in Jot will be discarded."
            alert.addButton(withTitle: "Reload External Version")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task {
                do {
                    let result = try await writer.reloadExternalVersion()
                    session.activeJot = result.jot
                    latestRevision = result.jot.acknowledgedRevision
                    session.selection = .start
                    session.viewport = .top
                    session.recoveryText = result.text
                    session.recoveryRevision = result.jot.acknowledgedRevision
                    hasBlockingWriteError = false
                    await persistSessionNow()
                    sendLoadSession(text: result.text)
                } catch {
                    hasBlockingWriteError = true
                    sendError(message: "The external version is no longer available.", actions: ["saveCopy"])
                }
            }
        default:
            break
        }
    }

    func editorRequestedDictationToggle() { voiceDictation.toggle() }
    func editorRequestedDictationFinish() { voiceDictation.finish() }
    func editorRequestedDictationCancel() { voiceDictation.cancel() }

    func composerDidResignKey() {
        Task {
            _ = await writer.flush(through: latestRevision)
            await persistSessionNow()
        }
    }

    func composerFrameDidChange(_ frame: NSRect) {
        session.panelFrame = NSStringFromRect(frame)
        session.panelPositionWasUserChosen = true
        persistSessionSoon()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(finishAndNewFromMenu):
            return Self.finishAndNewIsEnabled(
                activeJot: session.activeJot,
                hasBlockingWriteError: hasBlockingWriteError
            ) && !isOpeningNote
        case #selector(chooseRoot), #selector(chooseICloud):
            return !isOpeningNote && !isImportingImage && (voiceDictation.state == .idle || voiceDictation.state == .error)
        case #selector(revealCurrentJot):
            return session.activeJot != nil
        case #selector(navigateBackFromMenu):
            return navigation.canGoBack && !isOpeningNote
        case #selector(navigateForwardFromMenu):
            return navigation.canGoForward && !isOpeningNote
        case #selector(navigateLatestFromMenu):
            return !isOpeningNote && (hasBlankCapture || latestRailID != nil)
        default:
            return true
        }
    }

    static func finishAndNewIsEnabled(activeJot: ActiveJot?, hasBlockingWriteError: Bool) -> Bool {
        activeJot != nil && !hasBlockingWriteError
    }

    @objc private func showJot() { show() }

    @objc private func toggleDictationFromMenu() {
        panelController.showAndFocus()
        voiceDictation.toggle()
    }

    @objc private func finishAndNewFromMenu() { editorRequestedFinish(revision: latestRevision) }

    @objc private func showActionsFromMenu() {
        panelController.showAndFocus()
        panelController.send(["version": 1, "type": "toggleActionPanel"])
    }

    @objc private func searchNotesFromMenu() {
        panelController.showAndFocus()
        panelController.send(["version": 1, "type": "showNoteSearch"])
    }

    @objc private func findInNoteFromMenu() {
        panelController.showAndFocus()
        panelController.send(["version": 1, "type": "findInNote"])
    }

    @objc private func toggleInlineFormatFromMenu(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? String else { return }
        if panelController.window?.isVisible != true { panelController.showAndFocus() }
        panelController.send(["version": 1, "type": "toggleFormat", "format": format])
    }

    @objc private func navigateLatestFromMenu() { navigate(.latest) }
    @objc private func navigateBackFromMenu() { navigate(.back) }
    @objc private func navigateForwardFromMenu() { navigate(.forward) }

    @objc private func revealCurrentJot() {
        guard let path = session.activeJot?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openJotsFolder() {
        guard let rootURL else {
            chooseRoot()
            return
        }
        NSWorkspace.shared.open(rootURL)
    }

    @objc private func chooseRoot() { chooseNotebook(storage: .local) }
    @objc private func chooseICloud() { chooseNotebook(storage: .iCloud) }

    private func chooseNotebook(storage: NotebookStorage) {
        guard !isOpeningNote, !isImportingImage,
              (voiceDictation.state == .idle || voiceDictation.state == .error) else { return }
        guard let choice = rootAccess.chooseRoot(storage: storage) else { return }
        let oldRoot = rootURL
        if let oldRoot, oldRoot.standardizedFileURL != choice.url.standardizedFileURL {
            let alert = NSAlert()
            alert.messageText = "Transfer your notebook?"
            alert.informativeText = "All jots and images will be copied to the selected folder. The original notebook is kept as a backup. New changes will save in the selected folder."
            alert.addButton(withTitle: "Transfer Notebook")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if oldRoot == nil, let active = session.activeJot,
           !active.path.hasPrefix(choice.url.path + "/") {
            let alert = NSAlert()
            alert.messageText = "Restore your notebook first"
            alert.informativeText = "Choose the original Jots folder to restore access before transferring it. Your recovery writing is kept safe."
            alert.runModal()
            return
        }
        isOpeningNote = true
        panelController.send(["version": 1, "type": "setEditingEnabled", "enabled": false])
        sendActionState()
        Task {
            let accessing = choice.url.startAccessingSecurityScopedResource()
            defer {
                if accessing { choice.url.stopAccessingSecurityScopedResource() }
                isOpeningNote = false
                panelController.send(["version": 1, "type": "setEditingEnabled", "enabled": true])
                sendActionState()
            }
            do {
                if oldRoot != nil {
                    guard await writer.flush(through: latestRevision) else { throw PersistenceError.writeFailed("Save the current jot before transferring the notebook.") }
                }
                let current = await writer.currentJot()
                if let oldRoot {
                    try await Task.detached { try NotebookTransfer.copy(from: oldRoot, to: choice.url) }.value
                }
                var nextSession = session
                if let current, let oldRoot {
                    let prefix = oldRoot.resolvingSymlinksInPath().path + "/"
                    let path = URL(fileURLWithPath: current.path).resolvingSymlinksInPath().path
                    guard path.hasPrefix(prefix) else { throw PersistenceError.rootUnavailable }
                    nextSession.activeJot = ActiveJot(id: current.id,
                        path: choice.url.appendingPathComponent(String(path.dropFirst(prefix.count))).path,
                        acknowledgedRevision: current.acknowledgedRevision)
                }
                var replacementWriter: JotWriter?
                if oldRoot != nil {
                    let candidate = JotWriter(rootURL: choice.url) { [weak self] event in self?.handle(event) }
                    let restored = try await candidate.restore(nextSession.activeJot)
                    nextSession.recoveryText = restored
                    nextSession.recoveryRevision = nextSession.activeJot?.acknowledgedRevision
                    replacementWriter = candidate
                }
                nextSession.rootBookmark = choice.bookmark
                nextSession.storage = storage
                sessionGeneration += 1
                try await sessionStore.save(nextSession, generation: sessionGeneration)
                _ = rootAccess.setRoot(choice.url)
                rootURL = choice.url
                session = nextSession
                if let replacementWriter { writer = replacementWriter }
                else { await writer.configureRoot(choice.url) }
                let flushed = await writer.flush(through: latestRevision)
                hasBlockingWriteError = !flushed
                panelController.configureAttachmentRoot(choice.url)
                railNoteIDs = []
                latestRailID = nil
                navigation.reset()
                hasBlankCapture = session.activeJot == nil
                await noteRailIndex.configure(root: choice.url)
                await noteSearchIndex.configure(root: choice.url)
                await tagIndex.configure(root: choice.url)
                await refreshRail()
                await refreshTags(force: true)
                await persistSessionNow()
                sendLoadSession(text: session.recoveryText ?? "")
            } catch {
                let alert = NSAlert()
                alert.messageText = "The notebook could not be transferred"
                alert.informativeText = "The source notebook is retained. \(error.localizedDescription)"
                alert.runModal()
            }
        }
    }

    @objc private func changeShortcut(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let choice = ShortcutChoice(rawValue: rawValue) else { return }
        do {
            try shortcut.register(choice)
            session.shortcut = choice
            updateShortcutChecks()
            persistSessionSoon()
        } catch {
            let alert = NSAlert()
            alert.messageText = "That shortcut is unavailable."
            alert.informativeText = "Another application may already be using it."
            alert.runModal()
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                session.launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                session.launchAtLogin = true
            }
            sender.state = session.launchAtLogin ? .on : .off
            persistSessionSoon()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Launch at Login could not be changed."
            alert.runModal()
        }
    }

    @objc private func selectAllFromMenu() { panelController.send(["version": 1, "type": "selectAll"]) }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(nil) }

    private func chooseRootIfNeeded() {
        guard rootURL == nil else { return }
        chooseRoot()
        if rootURL == nil {
            sendError(message: "Choose a Jots folder before writing can be saved.", actions: ["restoreRoot"])
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Jot")
        statusItem.button?.toolTip = "Jot"

        let menu = NSMenu()
        menu.addItem(item("Show Jot", action: #selector(showJot), key: ""))
        menu.addItem(item("Start / Stop Dictation", action: #selector(toggleDictationFromMenu), key: ""))
        menu.addItem(item("Finish & New", action: #selector(finishAndNewFromMenu), key: "\r"))
        menu.addItem(.separator())
        menu.addItem(item("Reveal Current Jot in Finder", action: #selector(revealCurrentJot), key: ""))
        menu.addItem(item("Open Jots Folder", action: #selector(openJotsFolder), key: ""))
        menu.addItem(item("Change Jots Folder…", action: #selector(chooseRoot), key: ""))
        menu.addItem(item("Use iCloud Notebook…", action: #selector(chooseICloud), key: ""))
        let shortcutMenu = NSMenu()
        for choice in ShortcutChoice.allCases {
            let menuItem = item(choice.displayName, action: #selector(changeShortcut(_:)), key: "")
            menuItem.representedObject = choice.rawValue
            menuItem.state = choice == session.shortcut ? .on : .off
            shortcutMenu.addItem(menuItem)
        }
        let shortcutItem = NSMenuItem(title: "Change Shortcut", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)

        let launchItem = item("Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), key: "")
        launchItem.state = session.launchAtLogin ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(item("About Jot", action: #selector(showAbout), key: ""))
        menu.addItem(appUpdater.menuItem())
        menu.addItem(item("Quit Jot", action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Jot")
        applicationMenu.addItem(item("About Jot", action: #selector(showAbout), key: ""))
        applicationMenu.addItem(appUpdater.menuItem())
        applicationMenu.addItem(.separator())
        let changeFolder = item("Change Jots Folder…", action: #selector(chooseRoot), key: "j")
        changeFolder.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(changeFolder)
        applicationMenu.addItem(item("Use iCloud Notebook…", action: #selector(chooseICloud), key: ""))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(item("Quit Jot", action: #selector(quit), key: "q"))
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(responderItem("Undo", action: Selector(("undo:")), key: "z"))
        let redo = responderItem("Redo", action: Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(responderItem("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(responderItem("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(responderItem("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(item("Select All", action: #selector(selectAllFromMenu), key: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Find in Note…", action: #selector(findInNoteFromMenu), key: "f"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let formatItem = NSMenuItem()
        let formatMenu = NSMenu(title: "Format")
        for (title, format, key) in [("Bold", "bold", "b"), ("Italic", "italic", "i")] {
            let formatAction = item(title, action: #selector(toggleInlineFormatFromMenu(_:)), key: key)
            formatAction.representedObject = format
            formatMenu.addItem(formatAction)
        }
        formatItem.submenu = formatMenu
        mainMenu.addItem(formatItem)

        let navigateItem = NSMenuItem()
        let navigateMenu = NSMenu(title: "Navigate")
        navigateMenu.addItem(item("Search Notes…", action: #selector(searchNotesFromMenu), key: "p"))
        navigateMenu.addItem(item("Actions…", action: #selector(showActionsFromMenu), key: "k"))
        navigateMenu.addItem(.separator())
        navigateMenu.addItem(item("Latest Jot", action: #selector(navigateLatestFromMenu), key: "l"))
        navigateMenu.addItem(.separator())
        navigateMenu.addItem(item("Back", action: #selector(navigateBackFromMenu), key: "["))
        navigateMenu.addItem(item("Forward", action: #selector(navigateForwardFromMenu), key: "]"))
        navigateItem.submenu = navigateMenu
        mainMenu.addItem(navigateItem)

        NSApp.mainMenu = mainMenu
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func responderItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    private func updateShortcutChecks() {
        guard let items = statusItem.menu?.items,
              let shortcutMenu = items.first(where: { $0.title == "Change Shortcut" })?.submenu else { return }
        for item in shortcutMenu.items {
            item.state = (item.representedObject as? String) == session.shortcut.rawValue ? .on : .off
        }
    }

    private func handle(_ event: WriterEvent) {
        defer { sendActionState() }
        switch event {
        case let .noteAllocated(id, path, revision):
            if session.activeJot == nil {
                navigation.replaceBlank(with: id)
                hasBlankCapture = false
                latestRailID = id
            }
            session.activeJot = ActiveJot(id: id, path: path, acknowledgedRevision: -1)
            panelController.send(["version": 1, "type": "noteAllocated", "noteID": id, "path": path, "revision": revision, "baseURL": imageBaseURL(for: path) ?? ""])
        case let .saving(revision):
            panelController.send(["version": 1, "type": "saving", "revision": revision])
        case let .writeSucceeded(id, revision):
            Task { await refreshTags() }
            if !railNoteIDs.contains(id) { Task { await refreshRail() } }
            else if session.recoveryRevision == revision, let text = session.recoveryText {
                panelController.send([
                    "version": 1,
                    "type": "notePreview",
                    "noteID": id,
                    "excerpt": String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(180)),
                ])
            }
            hasBlockingWriteError = false
            if var jot = session.activeJot, jot.id == id {
                jot.acknowledgedRevision = revision
                session.activeJot = jot
            }
            panelController.send(["version": 1, "type": "writeSucceeded", "noteID": id, "revision": revision])
            persistSessionSoon()
        case let .writeFailed(id, revision, error):
            hasBlockingWriteError = true
            let message: String
            let actions: [String]
            switch error {
            case .rootUnavailable:
                message = "The Jots folder is unavailable."
                actions = ["restoreRoot"]
            case .externalConflict, .activeFileMissing:
                message = "This jot changed outside the app."
                actions = ["saveCopy", "reloadExternal"]
            case let .writeFailed(detail):
                message = "Saving failed: \(detail)"
                actions = ["restoreRoot", "saveCopy"]
            }
            var payload: [String: Any] = [
                "version": 1,
                "type": "writeFailed",
                "revision": revision,
                "errorCode": error.code,
                "message": message,
                "actions": actions,
            ]
            if let id { payload["noteID"] = id }
            panelController.send(payload)
        case let .externalConflict(id, revision):
            hasBlockingWriteError = true
            panelController.send(["version": 1, "type": "externalConflict", "noteID": id, "revision": revision])
        }
    }

    private static func containsImageAttachment(_ text: String) -> Bool {
        text.range(of: #"!\[[^\n]*\]\([^\n]*attachments/"#, options: .regularExpression) != nil
    }

    private func sendLoadSession(text: String) {
        panelController.preservesFrameForImages = Self.containsImageAttachment(text)
        var payload: [String: Any] = [
            "version": 1,
            "type": "loadSession",
            "text": text,
            "revision": latestRevision,
            "selection": ["anchor": session.selection.anchor, "head": session.selection.head],
            "viewport": ["scrollTop": session.viewport.scrollTop],
        ]
        if let jot = session.activeJot {
            payload["noteID"] = jot.id
            payload["baseURL"] = imageBaseURL(for: jot.path)
        }
        panelController.send(payload)
        sendActionState()
        if voiceDictation.state == .recording || voiceDictation.state == .transcribing {
            panelController.send(["version": 1, "type": "dictationState", "status": voiceDictation.state.rawValue])
            panelController.send(["version": 1, "type": "dictationPartial", "text": voiceDictation.currentPartial])
        }
    }

    private func refreshTags(force: Bool = false) async {
        let changed = await tagIndex.refresh()
        var tags = changed
        if tags == nil && force { tags = await tagIndex.vocabulary }
        guard let tags, force || tags != sentTags else { return }
        sentTags = tags
        panelController.send(["version": 1, "type": "tagVocabulary", "tags": tags])
    }

    private func refreshRail() async {
        guard let entries = await noteRailIndex.refresh() else { return }
        railNoteIDs = Set(entries.map(\.id))
        latestRailID = entries.first?.id
        sendActionState()
        panelController.send([
            "version": 1,
            "type": "noteRail",
            "notes": entries.map { [
                "id": $0.id,
                "timestamp": Int($0.timestamp.timeIntervalSince1970 * 1_000),
                "excerpt": $0.excerpt,
            ] as [String: Any] },
        ])
    }

    private func sendError(message: String, actions: [String]) {
        panelController.send([
            "version": 1,
            "type": "writeFailed",
            "revision": latestRevision,
            "errorCode": "session_unavailable",
            "message": message,
            "actions": actions,
        ])
    }

    private func persistSessionSoon() {
        sessionGeneration += 1
        let generation = sessionGeneration
        let snapshot = session
        Task { try? await sessionStore.save(snapshot, generation: generation) }
    }

    @discardableResult
    private func persistSessionNow() async -> Bool {
        sessionGeneration += 1
        do {
            try await sessionStore.save(session, generation: sessionGeneration)
            return true
        } catch {
            return false
        }
    }
}
