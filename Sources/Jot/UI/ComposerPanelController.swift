import AppKit
import WebKit

@MainActor
protocol ComposerPanelDelegate: AnyObject {
    func composerDidResignKey()
    func composerFrameDidChange(_ frame: NSRect)
}

final class ComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WindowDragContainerView: NSView {
    static let dragHeight: CGFloat = 44
    static let trafficLightClearance: CGFloat = 76

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        window.performDrag(with: event)
    }
}

@MainActor
final class ComposerPanelController: NSWindowController, NSWindowDelegate {
    let bridge = EditorBridge()
    private let resourceHandler = LocalResourceSchemeHandler()
    private let webView: WKWebView
    private let motionLabMode: Bool
    private var isProgrammaticFrameChange = false
    private var userHasResized = false
    private var userPlacedPanel = false
    private var hasShown = false
    private var escapeMonitor: Any?
    weak var panelDelegate: (any ComposerPanelDelegate)?
    var onEscape: (() -> Void)?

    init(savedFrame: String?, motionLabMode: Bool = false) {
        self.motionLabMode = motionLabMode
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.setValue(false, forKey: "developerExtrasEnabled")
        configuration.userContentController.add(bridge, name: "jot")
        configuration.setURLSchemeHandler(resourceHandler, forURLScheme: "jot")

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        let initialFrame = NSRect(x: 0, y: 0, width: motionLabMode ? 1050 : 560, height: motionLabMode ? 700 : 260)
        let panel = ComposerPanel(
            contentRect: initialFrame,
            styleMask: motionLabMode ? [.titled, .closable, .resizable, .miniaturizable] : [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = motionLabMode ? "Jot · Motion Lab" : "Jot"
        panel.titleVisibility = motionLabMode ? .visible : .hidden
        panel.titlebarAppearsTransparent = !motionLabMode
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = !motionLabMode
        panel.level = motionLabMode ? .normal : .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = motionLabMode ? NSSize(width: 780, height: 520) : NSSize(width: 360, height: 180)
        panel.maxSize = motionLabMode ? NSSize(width: 1400, height: 1000) : NSSize(width: 900, height: 900)
        let contentView = NSView(frame: initialFrame)
        let dragView = WindowDragContainerView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        dragView.translatesAutoresizingMaskIntoConstraints = false
        contentView.setAccessibilityElement(false)
        dragView.setAccessibilityElement(false)
        contentView.addSubview(webView)
        if !motionLabMode { contentView.addSubview(dragView) }
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

        ])
        if !motionLabMode {
            NSLayoutConstraint.activate([
                dragView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: WindowDragContainerView.trafficLightClearance),
                dragView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                dragView.topAnchor.constraint(equalTo: contentView.topAnchor),
                dragView.heightAnchor.constraint(equalToConstant: WindowDragContainerView.dragHeight),
            ])
        }
        panel.contentView = contentView
        panel.isReleasedWhenClosed = false

        super.init(window: panel)
        panel.delegate = self
        bridge.webView = webView
        webView.navigationDelegate = bridge
        if let savedFrame {
            let frame = NSRectFromString(savedFrame)
            if frame.width > 0, frame.height > 0 {
                panel.setFrame(frame, display: false)
                userPlacedPanel = true
            }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53,
                  let self,
                  self.window?.isVisible == true,
                  self.window?.isKeyWindow == true else { return event }
            self.onEscape?()
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func loadEditor() {
        webView.load(URLRequest(url: URL(string: motionLabMode ? "jot://local/index.html?motionLab=1" : "jot://local/index.html")!))
    }

    func showAndFocus() {
        guard let panel = window else { return }
        isProgrammaticFrameChange = true
        if userPlacedPanel {
            restoreVisiblePosition(panel)
        } else if let visibleFrame = activeVisibleFrame() {
            panel.setFrame(Self.centeredFrame(panel.frame, in: visibleFrame), display: true)
        }
        panel.orderFrontRegardless()
        isProgrammaticFrameChange = false
        hasShown = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        webView.focusRingType = .none
        webView.evaluateJavaScript("document.querySelector('.cm-content')?.focus()")
    }

    func hide() { window?.orderOut(nil) }

    func send(_ payload: [String: Any]) { bridge.send(payload) }

    func applyPreferredContentHeight(_ requestedHeight: CGFloat) {
        guard !motionLabMode, !userHasResized, let panel = window else { return }
        let contentHeight = min(max(requestedHeight, 180), 700)
        let frameHeight = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: panel.contentLayoutRect.width, height: contentHeight)).height
        guard abs(panel.frame.height - frameHeight) > 1 else { return }
        var frame = panel.frame
        frame.size.height = frameHeight
        if userPlacedPanel {
            frame.origin.y = panel.frame.maxY - frameHeight
        } else if let visibleFrame = activeVisibleFrame() {
            frame = Self.centeredFrame(frame, in: visibleFrame)
        }
        isProgrammaticFrameChange = true
        panel.setFrame(frame, display: true, animate: false)
        if userPlacedPanel { restoreVisiblePosition(panel) }
        isProgrammaticFrameChange = false
    }

    func windowDidResignKey(_ notification: Notification) {
        panelDelegate?.composerDidResignKey()
    }

    func windowDidMove(_ notification: Notification) {
        guard hasShown, !isProgrammaticFrameChange else { return }
        userPlacedPanel = true
        recordFrame()
    }
    func windowDidResize(_ notification: Notification) {
        guard hasShown, !isProgrammaticFrameChange else { return }
        userHasResized = true
        userPlacedPanel = true
        recordFrame()
    }

    private func recordFrame() {
        guard let frame = window?.frame else { return }
        panelDelegate?.composerFrameDidChange(frame)
    }

    private func activeVisibleFrame() -> NSRect? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame
    }

    private func restoreVisiblePosition(_ panel: NSWindow) {
        guard let visibleFrame = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) })?.visibleFrame
            ?? activeVisibleFrame() else { return }
        let frame = Self.clampedFrame(panel.frame, to: visibleFrame)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    static func centeredFrame(_ proposedFrame: NSRect, in visibleFrame: NSRect) -> NSRect {
        var frame = proposedFrame
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = visibleFrame.midX - frame.width / 2
        frame.origin.y = visibleFrame.midY - frame.height / 2
        return frame
    }

    static func clampedFrame(_ proposedFrame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var frame = proposedFrame
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        return frame
    }
}
