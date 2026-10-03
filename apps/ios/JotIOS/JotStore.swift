import Foundation
import Observation
import WebKit

struct PhoneSession: Codable {
    var active: ActiveJot?
    var text = ""
    var revision = 0
    var selection = EditorSelection.start
    var viewport = EditorViewport.top
}

@MainActor @Observable
final class JotStore {
    var configured = false
    var ready = false
    var error: String?
    var notes: [NoteSearchResult] = []
    var query = ""
    var showLibrary = false
    var session = PhoneSession()
    var root: URL?
    weak var webView: WKWebView?
    let resources = LocalResourceSchemeHandler()
    private var pending: Task<Void, Never>?
    private var writer: JotWriter!
    private var index = NoteSearchIndex(root: nil)
    private let sessionURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        sessionURL = support.appendingPathComponent("phone-session.json")
        if let data = try? Data(contentsOf: sessionURL), let saved = try? JSONDecoder().decode(PhoneSession.self, from: data) {
            session = saved
        }
        if UserDefaults.standard.string(forKey: "storage") == "local" {
            configureLocal()
        }
    }

    func configureLocal() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Jots")
        writer = JotWriter(rootURL: root) { [weak self] event in self?.handle(event) }
        configured = true
        UserDefaults.standard.set("local", forKey: "storage")
        enqueue { [self] in
            await index.configure(root: root)
            do {
                let text = try await writer.restore(session.active, recoveryText: session.text, recoveryRevision: session.revision)
                if session.active == nil, !session.text.isEmpty {
                    await writer.receive(snapshot, flushImmediately: true)
                    await updateActive()
                } else if session.active != nil {
                    // A locally journaled mutation can be newer than the canonical file.
                    if session.revision > (session.active?.acknowledgedRevision ?? 0) {
                        await writer.receive(snapshot, flushImmediately: true)
                    } else { session.text = text }
                }
                ready = true
                loadEditor()
            } catch { self.error = error.localizedDescription }
        }
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
        enqueue { [self] in
            guard await writer.finishAndNew(through: session.revision) else { error = "Your jot could not be saved. Try again before starting another."; return }
            session = PhoneSession()
            persist()
            loadEditor()
        }
    }

    func refreshNotes() async {
        await pending?.value
        notes = await index.search(query: query, refresh: true, currentID: session.active?.id, currentText: session.text) ?? []
    }

    func open(_ result: NoteSearchResult) {
        enqueue { [self] in
            if result.id == session.active?.id { showLibrary = false; focus(); return }
            guard let entry = await index.entry(id: result.id) else { return }
            do {
                let opened = try await writer.openExisting(id: result.id, path: entry.path, through: session.revision)
                session = PhoneSession(active: opened.jot, text: opened.text)
                persist()
                showLibrary = false
                loadEditor()
            } catch { self.error = error.localizedDescription }
        }
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
    private func updateActive() async { session.active = await writer?.currentJot(); persist() }
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
        case .externalConflict: error = "This jot changed elsewhere. Your writing is kept in the recovery copy."
        case let .writeFailed(_, _, failure): error = "Your writing couldn’t be saved (\(failure.code)). It remains in the recovery copy."
        default: break
        }
    }
}
