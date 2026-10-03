import SwiftUI
import WebKit

struct PhoneEditor: UIViewRepresentable {
    let store: JotStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(store.resources, forURLScheme: "jot")
        configuration.userContentController.add(context.coordinator, name: "jot")
        configuration.userContentController.addUserScript(WKUserScript(source: "document.documentElement.classList.add('ios')", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        store.webView = view
        view.load(URLRequest(url: URL(string: "jot://local/index.html")!))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let store: JotStore
        init(store: JotStore) { self.store = store }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "editorReady": store.loadEditor()
            case "importClipboardImage":
                if let requestID = body["requestID"] as? String { store.importImage(requestID: requestID) }
            case "importDroppedImage":
                if let requestID = body["requestID"] as? String, let encoded = body["data"] as? String,
                   let data = Data(base64Encoded: encoded) { store.importImage(requestID: requestID, data: data) }
            case "previewImage":
                if let path = body["path"] as? String { store.previewImage(path: path) }
            case "contentChanged": store.changed(body)
            case "editorStateChanged": store.stateChanged(body)
            case "finishAndNew": store.newJot()
            case "hide": store.webView?.endEditing(true)
            case "openBrowserURL": if let value = body["url"] as? String, let url = URL(string: value), ["https", "http"].contains(url.scheme) { UIApplication.shared.open(url) }
            default: break
            }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(["jot", "about"].contains(navigationAction.request.url?.scheme) ? .allow : .cancel)
        }
    }
}
