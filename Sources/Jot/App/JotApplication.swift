import AppKit

@MainActor
final class JotAppDelegate: NSObject, NSApplicationDelegate {
    private let sessionStore = SessionStore.live()
    private var coordinator: AppCoordinator?
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task {
            let session = await sessionStore.load()
            let coordinator = AppCoordinator(session: session, sessionStore: sessionStore)
            self.coordinator = coordinator
            coordinator.start()
            for url in pendingFiles { coordinator.documentWindows.open(url) }
            pendingFiles = []
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let coordinator else { pendingFiles.append(contentsOf: urls); return }
        for url in urls { coordinator.documentWindows.open(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        coordinator.prepareToTerminate { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.show()
        return true
    }
}

@main
@MainActor
enum JotApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = JotAppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
