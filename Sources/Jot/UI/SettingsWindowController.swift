import AppKit
import SwiftUI

@MainActor
final class JotSettingsModel: ObservableObject {
    @Published var folder: URL?
    @Published var storage: NotebookStorage = .local
    @Published var shortcut: ShortcutChoice = .optionSpace
    @Published var launchAtLogin = false
    @Published var canChooseFolder = true
    @Published var loginNeedsApproval = false
    var chooseFolder: () -> Void = {}
    var revealFolder: () -> Void = {}
    var changeShortcut: (ShortcutChoice) -> Void = { _ in }
    var changeLaunchAtLogin: (Bool) -> Void = { _ in }
    var checkForUpdates: () -> Void = {}
}

/// Jot has an AppKit application lifecycle. Keep window ownership here and
/// use native SwiftUI forms inside the standard macOS preferences toolbar.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: JotSettingsModel) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let general = NSTabViewItem(viewController: NSHostingController(rootView: GeneralSettingsView(model: model)))
        general.viewController?.title = "Jot Settings"
        general.label = "General"
        general.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        let about = NSTabViewItem(viewController: NSHostingController(rootView: AboutSettingsView(model: model)))
        about.viewController?.title = "Jot Settings"
        about.label = "About"
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About")
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(about)
        let window = NSWindow(contentViewController: tabs)
        window.title = "Jot Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 540, height: 390))
        window.toolbarStyle = .preference
        // The composer floats; keep its settings reachable above the editor.
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: JotSettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Notebook location") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(model.folder?.lastPathComponent ?? "No folder selected")
                        if let folder = model.folder {
                            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(model.storage == .iCloud ? "iCloud Drive" : "On this Mac")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Show in Finder", action: model.revealFolder)
                        .disabled(model.folder == nil)
                    Spacer()
                    Button("Choose Folder…", action: model.chooseFolder)
                        .disabled(!model.canChooseFolder)
                }
            } footer: {
                Text("Choosing a folder opens its notebook. Existing notes stay where they are. To share with iPhone, choose the same Jots folder inside Jot in iCloud Drive.")
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.changeLaunchAtLogin))
                if model.loginNeedsApproval {
                    Text("Allow Jot in System Settings → General → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Open Jot shortcut", selection: Binding(get: { model.shortcut }, set: model.changeShortcut)) {
                    ForEach(ShortcutChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 390)
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var model: JotSettingsModel
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 48, weight: .light)).foregroundStyle(.secondary)
            Text("Jot").font(.largeTitle.bold())
            Text("Version \(version) (\(build))").foregroundStyle(.secondary)
            if Bundle.main.object(forInfoDictionaryKey: "JotUpdatesEnabled") as? Bool != true {
                Text("Development build").font(.caption).foregroundStyle(.secondary)
            }
            Text("A quiet place for your thoughts.").foregroundStyle(.secondary)
            Button("Check for Updates…", action: model.checkForUpdates)
                .padding(.top, 6)
        }
        .frame(width: 540, height: 390)
    }
}
