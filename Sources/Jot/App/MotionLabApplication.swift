import AppKit
import WebKit

// This coordinator is reachable only from the separately packaged developer jig.
// It deliberately never creates AppCoordinator, SessionStore, or a JotWriter.
@MainActor
final class MotionLabApplication: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private let store = MotionLabStore()
    private let resourceHandler = LocalResourceSchemeHandler()
    private var window: NSWindow?
    private var webView: WKWebView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "motionLab")
        configuration.setURLSchemeHandler(resourceHandler, forURLScheme: "jot")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        self.webView = webView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1050, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Jot Motion Lab · Sample Notes"
        window.minSize = NSSize(width: 780, height: 520)
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: URL(string: "jot://local/lab.html")!))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "motionLab", let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            send(["type": "hydrate", "payload": store.payload()])
        case "save":
            guard let id = body["id"] as? String, let text = body["text"] as? String,
                  let anchor = body["anchor"] as? Int, let head = body["head"] as? Int,
                  let scrollTop = body["scrollTop"] as? Double else { return }
            let saved = store.save(id: id, text: text, anchor: anchor, head: head, scrollTop: scrollTop)
            send(["type": saved ? "saved" : "saveFailed", "id": id])
        case "select":
            guard let id = body["id"] as? String else { return }
            if store.select(id: id) {
                send(["type": "selected", "payload": store.payload()])
            } else {
                send(["type": "saveFailed", "id": id])
            }
        case "settings":
            if let settings = body["value"] as? [String: Double] { store.saveSettings(settings) }
        case "reset":
            store.reset()
            send(["type": "hydrate", "payload": store.payload()])
        case "export":
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(store.settingsJSON(), forType: .string)
            send(["type": "exported"])
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(scheme == "jot" || scheme == "about" ? .allow : .cancel)
    }

    private func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.MotionLabNative?.receive(\(json))")
    }
}
