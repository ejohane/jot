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
        let view = JotEditorWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        store.webView = view
        view.load(URLRequest(url: URL(string: "jot://local/index.html")!))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let category: UIContentSizeCategory
        switch context.environment.dynamicTypeSize {
        case .xSmall: category = .extraSmall
        case .small: category = .small
        case .medium: category = .medium
        case .large: category = .large
        case .xLarge: category = .extraLarge
        case .xxLarge: category = .extraExtraLarge
        case .xxxLarge: category = .extraExtraExtraLarge
        case .accessibility1: category = .accessibilityMedium
        case .accessibility2: category = .accessibilityLarge
        case .accessibility3: category = .accessibilityExtraLarge
        case .accessibility4: category = .accessibilityExtraExtraLarge
        case .accessibility5: category = .accessibilityExtraExtraExtraLarge
        @unknown default: category = .large
        }
        let size = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).pointSize
        guard context.coordinator.textSize != size else { return }
        context.coordinator.textSize = size
        context.coordinator.applyTextSize(to: uiView)
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let store: JotStore
        var textSize: CGFloat = 17
        func applyTextSize(to view: WKWebView) {
            view.evaluateJavaScript("document.documentElement.style.setProperty('--editor-size', '\(textSize)px')")
        }
        init(store: JotStore) { self.store = store }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            guard type == "editorReady" || store.acceptsEditorMessage(body) else { return }
            switch type {
            case "editorReady":
                if let view = store.webView { applyTextSize(to: view) }
                store.editorDidBecomeReady()
            case "showLibrary": store.openLibrary()
            case "importClipboardImage":
                if let requestID = body["requestID"] as? String { store.importImage(requestID: requestID) }
            case "importDroppedImage":
                if let requestID = body["requestID"] as? String, let encoded = body["data"] as? String,
                   let data = Data(base64Encoded: encoded) { store.importImage(requestID: requestID, data: data) }
            case "previewImage":
                if let path = body["path"] as? String { store.previewImage(path: path) }
            case "toggleDictation": store.toggleDictation()
            case "finishDictation": store.dictation.finish()
            case "cancelDictation": store.dictation.cancel()
            case "contentChanged": store.changed(body)
            case "editorStateChanged": store.stateChanged(body)
            case "finishAndNew": store.newJot()
            case "hide": store.webView?.endEditing(true)
            case "openBrowserURL": if let value = body["url"] as? String, let url = URL(string: value), ["https", "http"].contains(url.scheme) { UIApplication.shared.open(url) }
            default: break
            }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { store.editorWillReload(); webView.reload() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { store.editorDidFail() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { store.editorDidFail() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(["jot", "about"].contains(navigationAction.request.url?.scheme) ? .allow : .cancel)
        }
    }
}

/// Use Jot's unified editing bar rather than WebKit's form-navigation accessory.
private final class JotEditorWebView: WKWebView {
    override var inputAccessoryView: UIView? { nil }
}
