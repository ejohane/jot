import AppKit
import ServiceManagement

@MainActor
final class AppCoordinator: NSObject, EditorBridgeDelegate, ComposerPanelDelegate, NSMenuItemValidation {
    private let sessionStore: SessionStore
    private let rootAccess = RootAccessController()
    private let appUpdater = AppUpdater()
    private let voiceDictation = VoiceDictation()
    private var session: PersistedSession
    private var rootURL: URL?
    private var writer: JotWriter!
    private var panelController: ComposerPanelController!
    private var shortcut: GlobalShortcut!
    private var statusItem: NSStatusItem!
    private var latestRevision = 0
    private var sessionGeneration = 0
    private var shortcutRegistrationFailed = false
    private var hasBlockingWriteError = false

    init(session: PersistedSession, sessionStore: SessionStore) {
        self.session = session
        self.sessionStore = sessionStore
        super.init()

        rootURL = rootAccess.restore(from: session.rootBookmark)
        hasBlockingWriteError = session.activeJot != nil && rootURL == nil
        writer = JotWriter(rootURL: rootURL) { [weak self] event in self?.handle(event) }
        panelController = ComposerPanelController(
            savedFrame: session.panelPositionWasUserChosen == true ? session.panelFrame : nil
        )
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
        panelController.onEscape = { [weak self] in
            guard let self else { return }
            self.editorRequestedHide(revision: self.latestRevision)
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
    }

    func show() { panelController.showAndFocus() }

    func prepareToTerminate(completion: @escaping (Bool) -> Void) {
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

    func editorDidBecomeReady() {
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
        latestRevision = max(latestRevision, snapshot.revision)
        session.selection = snapshot.selection
        session.viewport = snapshot.viewport
        session.recoveryText = snapshot.text
        session.recoveryRevision = snapshot.revision
        Task { await writer.receive(snapshot) }
    }

    func editorStateChanged(selection: EditorSelection, viewport: EditorViewport) {
        session.selection = selection
        session.viewport = viewport
    }

    func editorPreferredHeightChanged(_ height: Double) {
        panelController.applyPreferredContentHeight(height)
    }

    func editorRequestedFinish(revision: Int) {
        Task {
            guard await writer.currentJot() != nil else { return }
            guard await writer.finishAndNew(through: revision) else { return }
            session.activeJot = nil
            session.selection = .start
            session.viewport = .top
            session.recoveryText = nil
            session.recoveryRevision = nil
            latestRevision = 0
            hasBlockingWriteError = false
            await persistSessionNow()
            sendLoadSession(text: "")
        }
    }

    func editorRequestedHide(revision: Int) {
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
            )
        case #selector(revealCurrentJot):
            return session.activeJot != nil
        default:
            return true
        }
    }

    static func finishAndNewIsEnabled(activeJot: ActiveJot?, hasBlockingWriteError: Bool) -> Bool {
        activeJot != nil && !hasBlockingWriteError
    }

    @objc private func showJot() { panelController.showAndFocus() }

    @objc private func toggleDictationFromMenu() {
        panelController.showAndFocus()
        voiceDictation.toggle()
    }

    @objc private func finishAndNewFromMenu() { editorRequestedFinish(revision: latestRevision) }

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

    @objc private func chooseRoot() {
        guard let choice = rootAccess.chooseRoot() else { return }
        rootURL = choice.url
        session.rootBookmark = choice.bookmark
        Task {
            await writer.configureRoot(choice.url)
            let flushed = await writer.flush(through: latestRevision)
            if flushed, let jot = await writer.currentJot() {
                hasBlockingWriteError = false
                panelController.send([
                    "version": 1,
                    "type": "writeSucceeded",
                    "noteID": jot.id,
                    "revision": latestRevision,
                ])
            } else if !flushed {
                hasBlockingWriteError = true
            }
            await persistSessionNow()
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
        editMenu.addItem(responderItem("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

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
        switch event {
        case let .noteAllocated(id, path, revision):
            session.activeJot = ActiveJot(id: id, path: path, acknowledgedRevision: -1)
            panelController.send(["version": 1, "type": "noteAllocated", "noteID": id, "path": path, "revision": revision])
        case let .saving(revision):
            panelController.send(["version": 1, "type": "saving", "revision": revision])
        case let .writeSucceeded(id, revision):
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

    private func sendLoadSession(text: String) {
        var payload: [String: Any] = [
            "version": 1,
            "type": "loadSession",
            "text": text,
            "revision": latestRevision,
            "selection": ["anchor": session.selection.anchor, "head": session.selection.head],
            "viewport": ["scrollTop": session.viewport.scrollTop],
        ]
        if let id = session.activeJot?.id { payload["noteID"] = id }
        panelController.send(payload)
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
