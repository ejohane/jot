import Foundation
import WebKit

@MainActor
final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private var attachmentTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var attachmentRoot: URL?

    func configureAttachmentRoot(_ root: URL?) {
        guard attachmentRoot != root else { return }
        attachmentTasks.values.forEach { $0.cancel() }
        attachmentTasks = [:]
        attachmentRoot = root
    }

    nonisolated static func attachmentURL(path: String, root: URL) -> URL? {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let file = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(candidate.lastPathComponent).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(resolvedRoot.path + "/"),
              file.pathComponents.contains("attachments"),
              ["png", "jpg", "jpeg", "tiff"].contains(file.pathExtension.lowercased()) else { return nil }
        return file
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme == "jot",
              ["local", "attachment"].contains(requestURL.host ?? "") else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        if requestURL.host == "attachment" {
            guard let root = attachmentRoot,
                  let file = Self.attachmentURL(path: String(requestURL.path.dropFirst()), root: root) else {
                urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
                return
            }
            let key = ObjectIdentifier(urlSchemeTask)
            attachmentTasks[key] = Task { [weak self] in
                let loading = Task.detached(priority: .userInitiated) { try await NotebookAttachment.load(file) }
                do {
                    let data = try await withTaskCancellationHandler(operation: { try await loading.value }, onCancel: { loading.cancel() })
                    guard !Task.isCancelled, let self, self.attachmentTasks[key] != nil else { return }
                    urlSchemeTask.didReceive(URLResponse(url: requestURL, mimeType: self.mimeType(for: file.pathExtension),
                                                        expectedContentLength: data.count, textEncodingName: nil))
                    guard self.attachmentTasks[key] != nil else { return }
                    urlSchemeTask.didReceive(data)
                    guard self.attachmentTasks[key] != nil else { return }
                    urlSchemeTask.didFinish()
                    self.attachmentTasks[key] = nil
                } catch {
                    guard !Task.isCancelled, let self, self.attachmentTasks[key] != nil else { return }
                    self.attachmentTasks[key] = nil
                    urlSchemeTask.didFailWithError(error)
                }
            }
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

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        attachmentTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    private static func editorResourceRoot() -> URL? {
        #if os(iOS)
        let editorDirectory = "dist"
        #else
        let editorDirectory = "Editor"
        #endif
        guard let appResources = Bundle.main.resourceURL?.appendingPathComponent(editorDirectory, isDirectory: true),
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
        case "jpg", "jpeg": "image/jpeg"
        case "tiff": "image/tiff"
        default: "application/octet-stream"
        }
    }
}
