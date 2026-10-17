import AppKit
import UniformTypeIdentifiers

@MainActor
final class DocumentWindows {
    private let store = DocumentWorkspaceStore.live()
    private(set) var windows: [String: DocumentWindowController] = [:]
    var capturePath: (() -> String?)?
    var focusCapture: (() -> Void)?
    var configure: ((DocumentWindowController) -> Void)?

    private weak var lastFocused: DocumentWindowController?
    var focused: DocumentWindowController? {
        windows.values.first { $0.panel.window?.isKeyWindow == true } ?? lastFocused
    }
    func captureDidBecomeKey() { lastFocused = nil }

    func focusExisting(_ url: URL) -> Bool {
        let path = MarkdownFile.canonicalURL(url).path
        if let capture = capturePath?(), MarkdownFile.canonicalURL(URL(fileURLWithPath: capture)).path == path {
            focusCapture?()
            return true
        }
        if let existing = windows[path] { existing.panel.showAndFocus(); return true }
        return false
    }

    func open(_ url: URL) {
        guard !focusExisting(url) else { return }
        do {
            let state = try MarkdownDocument.readState(url)
            let document = MarkdownDocument(state: state, store: store)
            let path = state.path
            let controller = DocumentWindowController(document: document, state: state)
            register(controller, path: path)
        } catch { NSAlert(error: error).runModal() }
    }

    private func register(_ controller: DocumentWindowController, path: String) {
        windows[path] = controller
        controller.panel.onBecomeKey = { [weak self, weak controller] in self?.lastFocused = controller }
        if controller.panel.window?.isKeyWindow == true { lastFocused = controller }
        if let window = controller.panel.window { NSApp.addWindowsItem(window, title: window.title, filename: false) }
        controller.onClose = { [weak self, weak controller] in
            if let window = controller?.panel.window { NSApp.removeWindowsItem(window) }
            if self?.lastFocused === controller { self?.lastFocused = nil }
            self?.windows.removeValue(forKey: path)
        }
        controller.openFile = { [weak self] in self?.open($0) }
        configure?(controller)
    }

    func restore() async {
        do {
            for state in try await store.load() {
                let url = URL(fileURLWithPath: state.path)
                if focusExisting(url) { continue }
                let document = MarkdownDocument(state: state, store: store)
                register(DocumentWindowController(document: document, state: state), path: state.path)
            }
        } catch { NSAlert(error: error).runModal() }
    }

    func chooseFile(directory: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Open Markdown File"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"),
                                     UTType(filenameExtension: "mdown"), UTType(filenameExtension: "mkd"), UTType(filenameExtension: "mkdn")].compactMap { $0 }
        panel.directoryURL = directory
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    func prepareToTerminate() async -> Bool {
        var safe = true
        for controller in Array(windows.values) {
            if !(await controller.prepareToTerminate()) { safe = false }
        }
        return safe
    }
}
