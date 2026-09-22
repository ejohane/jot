import Foundation
import WebKit

@MainActor
protocol EditorBridgeDelegate: AnyObject {
    func editorDidBecomeReady()
    func editorContentChanged(_ snapshot: EditorSnapshot, noteID: String?)
    func editorStateChanged(selection: EditorSelection, viewport: EditorViewport)
    func editorPreferredHeightChanged(_ height: Double)
    func editorRequestedFinish(revision: Int)
    func editorRequestedHide(revision: Int)
    func editorRequestedRecovery(_ action: String)
}

@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var delegate: (any EditorBridgeDelegate)?
    weak var webView: WKWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "jot" else { return }
        handle(message.body)
    }

    func handle(_ value: Any) {
        guard let body = value as? NSDictionary, integer(body["version"]) == 1,
              let type = body["type"] as? String else { return }

        switch type {
        case "editorReady":
            delegate?.editorDidBecomeReady()
        case "contentChanged":
            guard let revision = integer(body["revision"]),
                  let text = body["text"] as? String,
                  let selection = body["selection"] as? NSDictionary,
                  let anchor = integer(selection["anchor"]),
                  let head = integer(selection["head"]),
                  let viewport = body["viewport"] as? NSDictionary,
                  let scrollTop = double(viewport["scrollTop"]) else { return }
            delegate?.editorContentChanged(
                EditorSnapshot(
                    revision: revision,
                    text: text,
                    selection: EditorSelection(anchor: anchor, head: head),
                    viewport: EditorViewport(scrollTop: scrollTop)
                ),
                noteID: body["noteID"] as? String
            )
        case "editorStateChanged":
            guard let selection = body["selection"] as? NSDictionary,
                  let anchor = integer(selection["anchor"]),
                  let head = integer(selection["head"]),
                  let viewport = body["viewport"] as? NSDictionary,
                  let scrollTop = double(viewport["scrollTop"]) else { return }
            delegate?.editorStateChanged(
                selection: EditorSelection(anchor: anchor, head: head),
                viewport: EditorViewport(scrollTop: scrollTop)
            )
        case "preferredHeightChanged":
            if let height = double(body["height"]) { delegate?.editorPreferredHeightChanged(height) }
        case "finishAndNew":
            if let revision = integer(body["revision"]) { delegate?.editorRequestedFinish(revision: revision) }
        case "hide":
            if let revision = integer(body["revision"]) { delegate?.editorRequestedHide(revision: revision) }
        case "recover":
            if let action = body["action"] as? String { delegate?.editorRequestedRecovery(action) }
        default:
            break
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: URL(string: "jot://local/index.html")!))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(url.scheme == "jot" || url.scheme == "about" ? .allow : .cancel)
    }

    func send(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.JotNative && window.JotNative.receive(\(json))")
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        return (value as? NSNumber)?.doubleValue
    }
}
