import AppKit
import Sparkle

@MainActor
final class AppUpdater: NSObject {
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "JotUpdatesEnabled") as? Bool == true else { return }
        // Sparkle requests normal application termination. JotAppDelegate's
        // asynchronous save/recovery gate must succeed before the app exits.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        if let controller {
            item.target = controller
            item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        } else {
            item.target = self
            item.action = #selector(explainDevelopmentBuild)
        }
        return item
    }

    @objc private func explainDevelopmentBuild() {
        let alert = NSAlert()
        alert.messageText = "Updates are available in release builds"
        alert.informativeText = "This is a local development build. Install a published Jot release to receive updates."
        alert.runModal()
    }
}
