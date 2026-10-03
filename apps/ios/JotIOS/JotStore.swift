import Foundation
import Observation
import WebKit
import UIKit

struct PhoneSession: Codable {
    var active: ActiveJot?
    var storage: NotebookStorage?
    var acknowledgedData: Data?
    var text = ""
    var revision = 0
    var selection = EditorSelection.start
    var viewport = EditorViewport.top
}

@MainActor @Observable
final class JotStore {
    var storage: NotebookStorage = .local
    var storageBusy = false
    var showSettings = false
    var configured = false
    var ready = false
    var openingNotebook = false
    var reconciling = false
    private var reconciliationQueued = false
    var error: String?
    var hasConflict = false
    let dictation = PhoneDictation()
    var notes: [NoteSearchResult] = []
    var query = ""
    var pendingCloudNotes = 0
    var showLibrary = false
    var importingImage = false
    var imagePreview: PhoneImagePreview?
    private var pickedImageData: Data?
    private var importedImagePath: String?
    var session = PhoneSession()
    var root: URL?
    weak var webView: WKWebView?
    let resources = LocalResourceSchemeHandler()
    private var pending: Task<Void, Never>?
    private var writer: JotWriter!
    private let cloudNotebook = PhoneCloudNotebook()
    private var cloudURLs: [URL] = []
    private var index = NoteSearchIndex(root: nil)
    private let sessionURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        sessionURL = support.appendingPathComponent("phone-session.json")
        if let data = try? Data(contentsOf: sessionURL), let saved = try? JSONDecoder().decode(PhoneSession.self, from: data) {
            session = saved
        }
        cloudNotebook.onChange = { [weak self] urls in
            guard let self else { return }
            self.cloudURLs = urls
            self.reconcileCloudNote()
            if self.showLibrary { Task { await self.refreshNotes() } }
        }
        dictation.onMessage = { [weak self] message in
            self?.send(message)
            if message["type"] as? String == "dictationState", message["status"] as? String == "idle" {
                self?.reconcileCloudNote()
            }
        }
        dictation.onError = { [weak self] message in self?.error = message }
        if let storage = session.storage ?? UserDefaults.standard.string(forKey: "storage").flatMap(NotebookStorage.init(rawValue:)) {
            if storage == .local { configureLocal() } else { configureCloud() }
        }
    }

    private var localRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Jots")
    }

    func configureLocal() {
        guard session.storage != .iCloud else {
            error = "Reconnect to your iCloud notebook before transferring it to this iPhone. Your saved writing is kept safe."
            return
        }
        configure(root: localRoot, storage: .local)
    }

    func configureCloud() {
        guard !storageBusy else { return }
        storageBusy = true
        Task {
            let root = await Task.detached { NotebookStorage.cloudRoot() }.value
            storageBusy = false
            guard let root else { error = "iCloud Drive isn’t available. Check that you’re signed in and iCloud Drive is enabled, then try again."; return }
            configure(root: root, storage: .iCloud)
        }
    }

    func transfer(to mode: NotebookStorage) {
        guard mode != storage, !storageBusy, !reconciling, !importingImage, !dictation.active, ready else { return }
        storageBusy = true
        webView?.endEditing(true)
        enqueue { [self] in
            defer { storageBusy = false }
            guard await writer.flush(through: session.revision), let oldRoot = root else {
                error = "Save your current jot before transferring the notebook."
                return
            }
            await updateActive()
            let destination: URL? = mode == .local ? localRoot : await Task.detached { NotebookStorage.cloudRoot() }.value
            guard let destination else { error = "iCloud Drive isn’t available. Check your iCloud settings and try again."; return }
            do {
                try await Task.detached { try NotebookTransfer.copy(from: oldRoot, to: destination) }.value
                if let active = session.active {
                    let sourcePath = URL(fileURLWithPath: active.path).resolvingSymlinksInPath().path
                    let prefix = oldRoot.resolvingSymlinksInPath().path + "/"
                    guard sourcePath.hasPrefix(prefix) else { throw PersistenceError.rootUnavailable }
                    let relative = String(sourcePath.dropFirst(prefix.count))
                    session.active = ActiveJot(id: active.id, path: destination.appendingPathComponent(relative).path,
                                              acknowledgedRevision: active.acknowledgedRevision)
                }
                session.storage = mode
                persist()
                configure(root: destination, storage: mode)
                showSettings = false
            } catch { self.error = "Your notebook couldn’t be transferred. The source is kept safe. \(error.localizedDescription)" }
        }
    }

    private func configure(root: URL, storage: NotebookStorage) {
        self.root = root
        self.storage = storage
        cloudURLs = []
        cloudNotebook.configure(root: storage == .iCloud ? root : nil)
        session.storage = storage
        persist()
        ready = false
        openingNotebook = true
        writer = JotWriter(rootURL: root) { [weak self] event in self?.handle(event) }
        configured = true
        UserDefaults.standard.set(storage.rawValue, forKey: "storage")
        enqueue { [self] in
            defer { openingNotebook = false }
            await index.configure(root: root)
            do {
                if storage == .iCloud, let active = session.active {
                    try await Task.detached { try await NotebookCloudFile.prepare(URL(fileURLWithPath: active.path)) }.value
                }
                let text = try await writer.restoreJournal(session.active, text: session.text, revision: session.revision, baseline: session.acknowledgedData)
                if session.active == nil, !session.text.isEmpty {
                    await writer.receive(snapshot, flushImmediately: true)
                    await updateActive()
                } else if session.active != nil {
                    // A locally journaled mutation can be newer than the canonical file.
                    if session.revision > (session.active?.acknowledgedRevision ?? 0) {
                        await writer.receive(snapshot, flushImmediately: true)
                    } else { session.text = text }
                }
                await updateActive()
                ready = true
                loadEditor()
                reconcileCloudNote()
            } catch { self.error = error.localizedDescription }
        }
    }

    func retryOpeningNotebook() {
        guard !openingNotebook, !ready, let root else { return }
        configure(root: root, storage: storage)
    }

    private var snapshot: EditorSnapshot {
        EditorSnapshot(revision: session.revision, text: session.text, selection: session.selection, viewport: session.viewport)
    }

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pending
        pending = Task { await previous?.value; await operation() }
    }

    func changed(_ body: [String: Any]) {
        guard ready, let text = body["text"] as? String, let revision = body["revision"] as? Int,
              revision > session.revision else { return }
        if let importedImagePath, text.contains(importedImagePath) {
            self.importedImagePath = nil
            importingImage = false
        }
        session.text = text
        session.revision = revision
        stateChanged(body)
        persist()
        let value = snapshot
        enqueue { [self] in await writer.receive(value, flushImmediately: true); await updateActive() }
    }

    func stateChanged(_ body: [String: Any]) {
        if let selection = body["selection"] as? [String: Int], let anchor = selection["anchor"], let head = selection["head"] {
            session.selection = EditorSelection(anchor: anchor, head: head)
        }
        if let viewport = body["viewport"] as? [String: Double], let top = viewport["scrollTop"] {
            session.viewport = EditorViewport(scrollTop: top)
        }
        persist()
    }

    func newJot() {
        guard !importingImage, !storageBusy, !reconciling, !dictation.active else { return }
        enqueue { [self] in
            guard await writer.finishAndNew(through: session.revision) else { error = "Your jot could not be saved. Try again before starting another."; return }
            session = PhoneSession(storage: storage)
            persist()
            loadEditor()
        }
    }

    func refreshNotes() async {
        await pending?.value
        notes = await index.search(query: query, refresh: true, currentID: session.active?.id, currentText: session.text, discoveredURLs: cloudURLs) ?? []
        pendingCloudNotes = await index.pendingDownloadCount()
    }

    func reconcileCloudNote() {
        guard storage == .iCloud, ready, !reconciliationQueued, !storageBusy, !importingImage, !dictation.active else { return }
        reconciliationQueued = true
        enqueue { [self] in
            defer { reconciliationQueued = false }
            guard storage == .iCloud, ready, !storageBusy, !reconciling, !importingImage, !dictation.active else { return }
            // Metadata also reports our own saves. Avoid disturbing the editor for those.
            do { guard try await writer.hasExternalChange() else { return } }
            catch { return }
            reconciling = true
            defer {
                reconciling = false
                send(["version": 1, "type": "setEditingEnabled", "enabled": true])
            }
            // Read the exact editor document in the same JavaScript turn that locks it.
            // This does not depend on the order of WebKit content-message delivery.
            guard let webView else { return }
            do {
                guard let captured = try await webView.evaluateJavaScript("window.JotNative?.lockAndSnapshot()") as? [String: Any] else { return }
                changed(captured)
                stateChanged(captured)
            } catch { return }
            do {
                if let active = session.active {
                    try await Task.detached { try await NotebookCloudFile.prepare(URL(fileURLWithPath: active.path)) }.value
                }
                // Native content messages may have queued a save behind this operation.
                // Give the writer that latest snapshot before it decides whether adopting is safe.
                await writer.receive(snapshot, flushImmediately: true)
                guard let external = try await writer.reconcileExternal() else { return }
                session.active = external.jot
                session.text = external.text
                session.revision = external.jot.acknowledgedRevision
                await updateActive()
                loadEditor()
            } catch { self.error = "This jot couldn’t be refreshed from iCloud. Your current writing is kept safe." }
        }
    }

    func retryCloudDownloads() {
        let urls = cloudURLs
        Task.detached(priority: .utility) {
            for url in urls { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        }
    }

    func open(_ result: NoteSearchResult) {
        guard !importingImage, !storageBusy, !reconciling, !dictation.active else { return }
        enqueue { [self] in
            if result.id == session.active?.id { showLibrary = false; focus(); return }
            guard let entry = await index.entry(id: result.id) else { return }
            do {
                if storage == .iCloud {
                    try await Task.detached { try await NotebookCloudFile.prepare(URL(fileURLWithPath: entry.path)) }.value
                }
                let opened = try await writer.openExisting(id: result.id, path: entry.path, through: session.revision)
                session = PhoneSession(active: opened.jot, storage: storage, acknowledgedData: await writer.acknowledgedData(), text: opened.text)
                persist()
                showLibrary = false
                loadEditor()
            } catch { self.error = error.localizedDescription }
        }
    }

    func insertPickedImage(_ data: Data) {
        guard ready, !storageBusy, !reconciling, !importingImage, !dictation.active else { return }
        pickedImageData = data
        importingImage = true
        send(["version": 1, "type": "beginImagePaste"])
    }

    func importImage(requestID: String, data: Data? = nil) {
        let source = data ?? pickedImageData ?? UIPasteboard.general.image?.pngData()
        pickedImageData = nil
        importingImage = true
        enqueue { [self] in
            do {
                guard let source, let image = UIImage(data: source), let png = image.pngData() else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let imported = try await writer.importAttachment(png, fileExtension: "png")
                session.active = imported.jot
                importedImagePath = imported.relativePath
                send(["version": 1, "type": "noteAllocated", "noteID": imported.jot.id,
                      "path": imported.jot.path, "revision": session.revision, "baseURL": baseURL(imported.jot)])
                send(["version": 1, "type": "imageImported", "requestID": requestID,
                      "path": imported.relativePath, "baseURL": baseURL(imported.jot)])
                focus()
            } catch {
                importingImage = false
                send(["version": 1, "type": "imageImportFailed", "requestID": requestID,
                      "message": "This image couldn’t be added. Please choose or copy it again."])
            }
        }
    }

    func previewImage(path: String) {
        guard let root, let url = LocalResourceSchemeHandler.attachmentURL(path: path, root: root),
              let image = UIImage(contentsOfFile: url.path) else { return }
        imagePreview = PhoneImagePreview(image: image)
    }

    func preserveBothVersions() {
        enqueue { [self] in
            guard let copy = await writer.saveCurrentVersionAsCopy() else {
                error = "Your version couldn’t be saved as a separate jot. Your recovery copy is still protected. Please try again."
                return
            }
            session.active = copy
            await updateActive()
            hasConflict = false
            error = nil
            persist()
            loadEditor()
        }
    }

    func toggleDictation() {
        guard ready, !storageBusy, !reconciling, !importingImage else { return }
        if dictation.state == .recording { dictation.finish() }
        else if !dictation.active { dictation.start() }
    }

    func flush() { enqueue { [self] in _ = await writer?.flush(); await updateActive() } }
    func focus() { webView?.evaluateJavaScript("document.querySelector('.cm-content')?.focus()") }
    func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.JotNative?.receive(\(json))")
    }
    func loadEditor() {
        guard ready else { return }
        resources.configureAttachmentRoot(root)
        var value: [String: Any] = ["version": 1, "type": "loadSession", "text": session.text, "revision": session.revision,
            "selection": ["anchor": session.selection.anchor, "head": session.selection.head], "viewport": ["scrollTop": session.viewport.scrollTop]]
        if let active = session.active { value["noteID"] = active.id; value["baseURL"] = baseURL(active) }
        send(value)
    }
    private func baseURL(_ jot: ActiveJot) -> String {
        guard let root else { return "" }
        let directory = URL(fileURLWithPath: jot.path).deletingLastPathComponent().path
        let relative = String(directory.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "jot://attachment/" + relative + "/"
    }
    private func updateActive() async {
        session.active = await writer?.currentJot()
        if let data = await writer?.acknowledgedData() { session.acknowledgedData = data }
        persist()
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: sessionURL, options: .atomic)
        } catch { self.error = "Jot couldn’t save its recovery copy: \(error.localizedDescription)" }
    }
    private func handle(_ event: WriterEvent) {
        switch event {
        case let .noteAllocated(id, path, revision):
            let jot = ActiveJot(id: id, path: path, acknowledgedRevision: revision)
            send(["version": 1, "type": "noteAllocated", "noteID": id, "path": path, "revision": revision, "baseURL": baseURL(jot)])
        case let .writeSucceeded(id, revision): send(["version": 1, "type": "writeSucceeded", "noteID": id, "revision": revision])
        case .externalConflict: hasConflict = true; error = "This jot changed elsewhere. Your writing is kept in the recovery copy."
        case let .writeFailed(_, _, failure): error = "Your writing couldn’t be saved (\(failure.code)). It remains in the recovery copy."
        default: break
        }
    }
}

struct PhoneImagePreview: Identifiable {
    let id = UUID()
    let image: UIImage
}
