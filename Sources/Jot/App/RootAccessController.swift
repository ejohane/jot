import AppKit
import Foundation

@MainActor
final class RootAccessController {
    private(set) var rootURL: URL?
    private var isAccessing = false

    deinit {
        if isAccessing { rootURL?.stopAccessingSecurityScopedResource() }
    }

    func restore(from bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else { return nil }
        return setRoot(url) ? url : nil
    }

    func chooseRoot() -> (url: URL, bookmark: Data)? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Jots Folder"
        panel.message = "Choose or create a local folder for your Markdown jots."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            _ = setRoot(url)
            return (url, bookmark)
        } catch {
            return nil
        }
    }

    @discardableResult
    private func setRoot(_ url: URL) -> Bool {
        if isAccessing { rootURL?.stopAccessingSecurityScopedResource() }
        rootURL = url
        isAccessing = url.startAccessingSecurityScopedResource()
        return isAccessing
    }
}
