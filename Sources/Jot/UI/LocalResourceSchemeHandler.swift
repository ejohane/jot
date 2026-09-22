import Foundation
import WebKit

final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme == "jot",
              requestURL.host == "local" else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let relativePath = requestURL.path == "/" ? "index.html" : String(requestURL.path.dropFirst())
        guard !relativePath.components(separatedBy: "/").contains(".."),
              let resourceRoot = Self.editorResourceRoot() else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        let fileURL = resourceRoot.appendingPathComponent(relativePath)
        guard fileURL.standardizedFileURL.path.hasPrefix(resourceRoot.standardizedFileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType(for: fileURL.pathExtension),
                "Cache-Control": "no-store",
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private static func editorResourceRoot() -> URL? {
        guard let appResources = Bundle.main.resourceURL?.appendingPathComponent("Editor", isDirectory: true),
              FileManager.default.fileExists(atPath: appResources.appendingPathComponent("index.html").path)
        else { return nil }
        return appResources
    }

    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }
}
