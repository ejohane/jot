import SwiftUI
import WebKit

struct PhoneEditor: UIViewRepresentable {
    let store: JotStore
    var reviewChromeHidden = false
    var onReviewScroll: () -> Void = {}
    var onReviewTap: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(store: store, onReviewScroll: onReviewScroll, onReviewTap: onReviewTap) }
    func makeUIView(context: Context) -> JotPagingSurface {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(store.resources, forURLScheme: "jot")
        configuration.userContentController.addUserScript(WKUserScript(source: "window.jotMobileEditor = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "jot")
        configuration.userContentController.add(context.coordinator, name: "reviewChrome")
        configuration.userContentController.addUserScript(WKUserScript(source: """
        (() => {
          let previousTop = 0;
          document.addEventListener('scroll', event => {
            const target = event.target;
            const top = target instanceof Element ? target.scrollTop : window.scrollY;
            if (top > previousTop + 2) window.webkit.messageHandlers.reviewChrome.postMessage('scroll');
            previousTop = top;
          }, true);
          let pointerStart = null;
          document.addEventListener('pointerdown', event => { pointerStart = [event.clientX, event.clientY]; if (window.jotReviewChromeHidden) event.preventDefault(); }, { capture: true, passive: false });
          document.addEventListener('pointerup', event => {
            if (pointerStart && Math.hypot(event.clientX - pointerStart[0], event.clientY - pointerStart[1]) < 8)
              window.webkit.messageHandlers.reviewChrome.postMessage('tap');
            pointerStart = null;
          });
          document.addEventListener('pointercancel', () => { pointerStart = null; });
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: """
            document.documentElement.classList.add('ios');
            document.querySelector('meta[name="viewport"]')?.setAttribute('content',
              'width=device-width, initial-scale=1.0, maximum-scale=1.0');
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = JotEditorWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        store.webView = view
        view.load(URLRequest(url: URL(string: "jot://local/index.html")!))
        return JotPagingSurface(editor: view, store: store)
    }
    func updateUIView(_ surface: JotPagingSurface, context: Context) {
        let uiView = surface.editor
        surface.refreshNeighbors()
        uiView.evaluateJavaScript("window.jotReviewChromeHidden = \(reviewChromeHidden ? "true" : "false")")
        context.coordinator.onReviewScroll = onReviewScroll
        context.coordinator.onReviewTap = onReviewTap
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
        var onReviewScroll: () -> Void
        var onReviewTap: () -> Void
        init(store: JotStore, onReviewScroll: @escaping () -> Void, onReviewTap: @escaping () -> Void) {
            self.store = store
            self.onReviewScroll = onReviewScroll
            self.onReviewTap = onReviewTap
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "reviewChrome" {
                guard message.webView === store.webView else { return }
                if message.body as? String == "scroll" { onReviewScroll() }
                else if message.body as? String == "tap" { onReviewTap() }
                return
            }
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
