import UIKit
import WebKit

/// A single live editor with read-only neighbors. Only a completed page turn opens a note.
@MainActor final class JotPagingSurface: UIView, UIGestureRecognizerDelegate {
    let editor: WKWebView
    private let store: JotStore
    private var neighbors: [Int: JotPagePreview] = [:]
    private var neighborIDs: [Int: String] = [:]
    private var generation = UUID()
    private var notebookRoot: URL?
    private var target: JotPagePreview?
    private var direction = 0
    private var settling = false
    private var writing = false
    private var draftTimestamp = Date()
    private let feedback = UISelectionFeedbackGenerator()

    init(editor: WKWebView, store: JotStore) {
        self.editor = editor
        self.store = store
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .systemBackground
        addSubview(editor)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pagePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        editor.bounds = bounds
        editor.center = CGPoint(x: bounds.midX, y: bounds.midY)
        for preview in neighbors.values {
            preview.bounds = bounds
            preview.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    func refreshNeighbors() {
        guard !settling, target == nil else { return }
        let notes = store.pagingNotes
        let current = notes.firstIndex { $0.id == store.session.active?.id }
        var desired: [Int: NoteSearchResult] = [:]
        if let current {
            if current > 0 { desired[1] = notes[current - 1] }
            else { desired[1] = NoteSearchResult(id: "paging-new-draft", timestamp: Date(), title: "", excerpt: "", titleMatches: [], excerptMatches: []) }
            if current + 1 < notes.count { desired[-1] = notes[current + 1] }
        } else if store.session.active == nil, let newest = notes.first { desired[-1] = newest }
        let ids = desired.mapValues(\.id)
        guard ids != neighborIDs || notebookRoot != store.root else { return }
        notebookRoot = store.root
        generation = UUID()
        let token = generation
        neighbors.values.forEach { $0.removeFromSuperview() }
        neighbors = [:]
        neighborIDs = ids
        for (side, note) in desired {
            let preview = JotPagePreview(note: note, store: store, isNewDraft: side == 1 && current == 0)
            neighbors[side] = preview
            preview.frame = bounds
            preview.isHidden = true
            insertSubview(preview, belowSubview: editor)
            Task { [weak self, weak preview, store] in
                let content = preview?.isNewDraft == true ? ("", "") : await store.pagingPreview(note)
                guard let self, self.generation == token, let preview else { return }
                preview.setContent(content)
            }
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              !settling, store.canEdit, !store.showLibrary, !store.showSettings,
              !store.storageBusy, !store.reconciling, !store.importingImage, !store.dictation.active,
              store.session.selection.anchor == store.session.selection.head else { return false }
        let velocity = pan.velocity(in: self)
        guard abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
        let side = velocity.x < 0 ? 1 : -1
        return neighbors[side]?.ready == true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // WebKit has its own content gestures. The velocity gate above chooses the horizontal axis.
        otherGestureRecognizer.view?.isDescendant(of: editor) == true
    }

    @objc private func pagePan(_ pan: UIPanGestureRecognizer) {
        let width = bounds.width
        guard width > 0 else { return }
        switch pan.state {
        case .began:
            direction = pan.velocity(in: self).x < 0 ? 1 : -1
            target = neighbors[direction]
            target?.isHidden = false
            draftTimestamp = Date()
            if let target { store.pageTitleView?.begin(from: store.noteTitleDate, to: target.isNewDraft ? draftTimestamp : target.note.timestamp, direction: direction) }
            writing = editor.isFirstResponder || editor.findFirstResponder() != nil
            feedback.prepare()
        case .changed:
            let raw = pan.translation(in: self).x
            let offset = direction == 1 ? min(0, max(-width, raw)) : max(0, min(width, raw))
            store.pageTitleView?.setProgress(offset / width)
            editor.transform = CGAffineTransform(translationX: offset, y: 0)
            target?.transform = CGAffineTransform(translationX: offset + CGFloat(direction) * width, y: 0)
        case .ended, .cancelled, .failed:
            guard let target else { return }
            let distance = -CGFloat(direction) * pan.translation(in: self).x
            let velocity = -CGFloat(direction) * pan.velocity(in: self).x
            let commit = pan.state == .ended && (distance > width * 0.3 || (distance > 20 && velocity > 500))
            settling = true
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.12 : 0.25,
                           delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.store.pageTitleView?.setProgress(commit ? -CGFloat(self.direction) : 0)
                self.editor.transform = CGAffineTransform(translationX: commit ? -CGFloat(self.direction) * width : 0, y: 0)
                target.transform = CGAffineTransform(translationX: commit ? 0 : CGFloat(self.direction) * width, y: 0)
            } completion: { _ in
                if commit {
                    let completed: (Bool) -> Void = { success in
                        if success {
                            self.editor.callAsyncJavaScript("await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame)", arguments: [:], in: nil, in: .page) { result in
                                self.resetPaging()
                                if case .success = result { self.feedback.selectionChanged() }
                            }
                        } else {
                            UIView.animate(withDuration: 0.2, animations: {
                                self.store.pageTitleView?.setProgress(0)
                                self.editor.transform = .identity
                                target.transform = CGAffineTransform(translationX: CGFloat(self.direction) * width, y: 0)
                            }, completion: { _ in self.resetPaging() })
                        }
                    }
                    if target.isNewDraft {
                        self.store.newJot(focus: self.writing, createdAt: self.draftTimestamp, completion: completed)
                    } else { self.store.open(target.note, focus: self.writing, completion: completed) }
                } else { self.resetPaging() }
            }
        default: break
        }
    }

    private func resetPaging() {
        store.pageTitleView?.finish(date: store.noteTitleDate)
        editor.transform = .identity
        target?.isHidden = true
        target?.transform = .identity
        target = nil
        settling = false
        refreshNeighbors()
    }
}

@MainActor private final class JotPagePreview: UIView, WKScriptMessageHandler {
    let note: NoteSearchResult
    let isNewDraft: Bool
    private let web: WKWebView
    private let resources = LocalResourceSchemeHandler()
    private var content: (String, String)?
    private var loaded = false
    private(set) var ready = false
    init(note: NoteSearchResult, store: JotStore, isNewDraft: Bool) {
        self.note = note
        self.isNewDraft = isNewDraft
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(resources, forURLScheme: "jot")
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        resources.configureAttachmentRoot(store.root)
        backgroundColor = .systemBackground
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        configuration.userContentController.add(WeakPageMessageHandler(self), name: "jot")
        configuration.userContentController.addUserScript(WKUserScript(source: "document.documentElement.classList.add('ios');", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        addSubview(web)
        web.load(URLRequest(url: URL(string: "jot://local/index.html")!))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); web.frame = bounds }
    func setContent(_ content: (String, String)?) { self.content = content; render() }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "editorReady" else { return }
        loaded = true
        render()
    }
    private func render() {
        guard loaded, let content else { return }
        let payload: [String: Any] = ["version": 1, "type": "loadSession", "focus": false,
            "text": content.0, "baseURL": content.1, "noteID": note.id, "revision": 0,
            "selection": ["anchor": 0, "head": 0], "viewport": ["scrollTop": 0]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        let size = UIFont.preferredFont(forTextStyle: .body).pointSize
        web.callAsyncJavaScript("""
            document.documentElement.style.setProperty('--editor-size', '\(size)px');
            window.JotNative.receive(\(json));
            window.JotNative.receive({version:1,type:'setEditingEnabled',enabled:false});
            await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
            """, arguments: [:], in: nil, in: .page) { [weak self] result in
                if case .success = result { self?.ready = true }
            }
    }
}

private extension UIView {
    func findFirstResponder() -> UIView? {
        if isFirstResponder { return self }
        return subviews.lazy.compactMap { $0.findFirstResponder() }.first
    }
}

@MainActor private final class WeakPageMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: JotPagePreview?
    init(_ target: JotPagePreview) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
