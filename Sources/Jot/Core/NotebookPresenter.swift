import Foundation

/// File-coordination notifications cover changes delivered by iCloud as well as other editors.
final class NotebookPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: @MainActor @Sendable () -> Void

    init(root: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        presentedItemURL = root
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() { NSFileCoordinator.removeFilePresenter(self) }
    func presentedItemDidChange() { notify() }
    func presentedSubitemDidAppear(at url: URL) { notify() }
    func presentedSubitemDidChange(at url: URL) { notify() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { notify() }
    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { notify() }

    private func notify() { Task { @MainActor [onChange] in onChange() } }
}
