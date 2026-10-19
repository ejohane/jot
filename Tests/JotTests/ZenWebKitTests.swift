import AppKit
import WebKit
import XCTest
@testable import Jot

/// Opt-in layout proof against the built production editor, using macOS WebKit.
/// Run after `npm --prefix Web run build` with JOT_ZEN_PROOF_DIR set.
final class ZenWebKitTests: XCTestCase {
    @MainActor
    func testZenDismissalCannotResizeFullScreenTransition() throws {
        let controller = ComposerPanelController(savedFrame: nil, documentURL: URL(fileURLWithPath: "/tmp/Zen.md"))
        let window = try XCTUnwrap(controller.window)
        controller.applyActionPanelVisibility(true)
        let frame = window.frame
        let notification = Notification(name: NSWindow.willEnterFullScreenNotification, object: window)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertTrue(controller.window(window, willUseFullScreenPresentationOptions: [.fullScreen, .autoHideMenuBar]).contains(.autoHideToolbar))
        controller.windowWillEnterFullScreen(notification)
        XCTAssertEqual(window.titleVisibility, .hidden)
        controller.applyActionPanelVisibility(false)
        XCTAssertEqual(window.frame, frame)
        controller.setZenFocus("sentence")
        XCTAssertEqual(controller.zenFocus, "sentence")
        controller.setZenFocus("invalid")
        XCTAssertEqual(controller.zenFocus, "sentence")
        controller.windowDidFailToEnterFullScreen(window)
        XCTAssertEqual(window.titleVisibility, .visible)
        controller.windowWillEnterFullScreen(notification)
        controller.windowDidEnterFullScreen(notification)
        controller.windowWillExitFullScreen(notification)
        controller.windowDidExitFullScreen(notification)
        XCTAssertEqual(window.titleVisibility, .visible)
    }

    @MainActor
    private func evaluate(_ web: WKWebView, _ script: String) async throws -> Any {
        do { return try await web.evaluateJavaScript(script) }
        catch { print("ZEN JS ERROR", (error as NSError).userInfo); throw error }
    }

    @MainActor
    func testProductionWebKitFocusAndCentering() async throws {
        guard let output = ProcessInfo.processInfo.environment["JOT_ZEN_PROOF_DIR"] else {
            throw XCTSkip("Set JOT_ZEN_PROOF_DIR to run production WebKit layout verification")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bridge = EditorBridge()
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "jot")
        let handler = BuiltEditorHandler(root: root.appendingPathComponent("Web/dist"))
        config.setURLSchemeHandler(handler, forURLScheme: "jot")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        bridge.webView = web
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "jot://local/index.html")!))
        defer { window.orderOut(nil) }
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!window.JotNative")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let ready = try await web.evaluateJavaScript("!!window.JotNative")
        XCTAssertEqual(ready as? Bool, true)
        let text = (0..<25).map { "Paragraph \($0). A second sentence for focused writing.\nA wrapped source line belongs to this paragraph." }.joined(separator: "\n\n")
        var results: [[String: Any]] = []
        for (label, position, mode) in [("first", 0, "paragraph"), ("middle", text.count / 2, "paragraph"), ("last", text.count, "sentence")] {
            bridge.send(["version": 1, "type": "loadSession", "documentWindow": true,
                "text": text, "revision": 1, "selection": ["anchor": position, "head": position], "viewport": ["scrollTop": 0]])
            bridge.send(["version": 1, "type": "zenMode", "mode": mode])
            try await Task.sleep(for: .milliseconds(350))
            let metrics = try await evaluate(web, """
                (() => {
                    const scroller = document.querySelector('.cm-scroller');
                    const box = scroller.getBoundingClientRect();
                    const view = document.querySelector(".cm-content").cmTile.root.view;
                    const caret = view.coordsAtPos(view.state.selection.main.head);
                    const dim = document.querySelector('.cm-zen-dim');
                    const content = document.querySelector('.cm-content');
                    return { centerError: Math.abs((caret.top + caret.bottom - box.top - box.bottom) / 2),
                        dimCount: document.querySelectorAll('.cm-zen-dim').length,
                        dimColor: dim ? getComputedStyle(dim).color : '',
                        activeColor: getComputedStyle(content).color,
                        railHidden: getComputedStyle(document.querySelector('.note-rail')).display === 'none',
                        zen: document.documentElement.classList.contains('zen-mode'),
                        snapshot: window.JotNative.lockAndSnapshot(true) };
                })()
                """)
            var row = try XCTUnwrap(metrics as? [String: Any]); row["case"] = label
            results.append(row)
            XCTAssertLessThan(try XCTUnwrap(row["centerError"] as? Double), 3, label)
            XCTAssertGreaterThan(try XCTUnwrap(row["dimCount"] as? Int), 0, label)
            XCTAssertNotEqual(row["dimColor"] as? String, row["activeColor"] as? String)
            XCTAssertEqual(row["railHidden"] as? Bool, true)
            let snapshot = try XCTUnwrap(row["snapshot"] as? [String: Any])
            XCTAssertEqual(snapshot["text"] as? String, text)
            XCTAssertEqual((snapshot["selection"] as? [String: Int])?["head"], position)
            bridge.send(["version": 1, "type": "setEditingEnabled", "enabled": true])
        }
        bridge.send(["version": 1, "type": "zenMode", "mode": "off"])
        try await Task.sleep(for: .milliseconds(150))
        let dimCount = try await web.evaluateJavaScript("document.querySelectorAll('.cm-zen-dim').length")
        XCTAssertEqual(dimCount as? Int, 0)
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("webkit-layout.json"))
    }
}

@MainActor
private final class BuiltEditorHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        let path = url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let file = root.appendingPathComponent(path)
        do {
            let data = try Data(contentsOf: file)
            let mime = file.pathExtension == "js" ? "text/javascript" : file.pathExtension == "css" ? "text/css" : "text/html"
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
