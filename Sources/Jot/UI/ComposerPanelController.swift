import AppKit
import WebKit

@MainActor
protocol ComposerPanelDelegate: AnyObject {
    func composerDidResignKey()
    func composerFrameDidChange(_ frame: NSRect)
}

final class ComposerPanel: NSPanel, NSDraggingDestination {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { !isFloatingPanel }
    var onImageFileDrop: (([URL], NSPoint) -> Void)?

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        AttachmentWebView.imageFiles(in: sender).isEmpty ? [] : .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        AttachmentWebView.imageFiles(in: sender).isEmpty ? [] : .copy
    }

    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !AttachmentWebView.imageFiles(in: sender).isEmpty
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = AttachmentWebView.imageFiles(in: sender)
        guard !files.isEmpty else { return false }
        onImageFileDrop?(files, sender.draggingLocation)
        return true
    }
}

final class WindowDragContainerView: NSView {
    static let dragHeight: CGFloat = 44
    static let trafficLightClearance: CGFloat = 76
    var formattingToolbarRect: NSRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let formattingToolbarRect, formattingToolbarRect.contains(convert(point, from: superview)) { return nil }
        return super.hitTest(point)
    }

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

/// A single editor surface; only its window chrome changes when detached.
final class CaptureBubbleView: NSView {
    var anchored = false { didSet { needsLayout = true } }
    var pointerX: CGFloat = 280 { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        wantsLayer = true
        guard anchored else { layer?.mask = nil; return }
        let top = bounds.height - 12
        let width = bounds.width
        let radius: CGFloat = 24
        let x = min(max(pointerX, 48), width - 48)
        // One outline: the shoulders flow directly into the editor's top edge.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: width, y: radius), control: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: width, y: top - radius))
        path.addQuadCurve(to: CGPoint(x: width - radius, y: top), control: CGPoint(x: width, y: top))
        path.addLine(to: CGPoint(x: x + 24, y: top))
        path.addCurve(to: CGPoint(x: x, y: bounds.height),
                      control1: CGPoint(x: x + 10, y: top), control2: CGPoint(x: x + 6, y: bounds.height))
        path.addCurve(to: CGPoint(x: x - 24, y: top),
                      control1: CGPoint(x: x - 6, y: bounds.height), control2: CGPoint(x: x - 10, y: top))
        path.addLine(to: CGPoint(x: radius, y: top))
        path.addQuadCurve(to: CGPoint(x: 0, y: top - radius), control: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.closeSubpath()
        let mask = CAShapeLayer()
        mask.path = path
        layer?.mask = mask
        updateSurfaceColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceColor()
    }

    private func updateSurfaceColor() {
        // Match the editor surface, including the area above the WKWebView.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.black : NSColor(calibratedRed: 248 / 255, green: 248 / 255, blue: 247 / 255, alpha: 1)).cgColor
    }
}

@MainActor
final class AttachmentWebView: WKWebView {
    var onImagePaste: (() -> Void)?
    var onImageFileDrop: (([URL], NSPoint) -> Void)?

    static func imageFiles(on pasteboard: NSPasteboard) -> [URL] {
        let files = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp", "bmp"]
        return files.isEmpty || files.contains(where: { !extensions.contains($0.pathExtension.lowercased()) }) ? [] : files
    }

    static func imageFiles(in sender: any NSDraggingInfo) -> [URL] {
        imageFiles(on: sender.draggingPasteboard)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.imageFiles(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.imageFiles(in: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Self.imageFiles(in: sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = Self.imageFiles(in: sender)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        onImageFileDrop?(files, NSPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v", Self.clipboardHasImage {
            onImagePaste?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static var clipboardHasImage: Bool {
        NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
    }
}

@MainActor
final class ComposerPanelController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let bridge = EditorBridge()
    private let resourceHandler = LocalResourceSchemeHandler()
    private let webView: AttachmentWebView
    private let dragView = WindowDragContainerView(frame: .zero)
    private var isProgrammaticFrameChange = false
    private var userHasResized = false
    private var isFullScreenTransition = false
    private var userPlacedPanel = false
    private var hasShown = false
    private var keyMonitor: Any?
    private var menuObservers: [any NSObjectProtocol] = []
    private var menuIsTracking = false
    private var actionPanelVisible = false
    private var frameBeforeActions: NSRect?
    private var imagePreview: NSWindowController?
    var preservesFrameForImages = false
    weak var panelDelegate: (any ComposerPanelDelegate)?
    var onEscape: (() -> Void)?
    var onCloseRequested: (() -> Bool)?
    var onBecomeKey: (() -> Void)?
    private let isDocument: Bool
    private(set) var isAnchored = false
    var captureAnchor: (() -> NSRect?)?
    private var detachedFrame: NSRect?
    private var editorTop: NSLayoutConstraint!
    private let popOutButton = NSButton()
    private var nativeToolbar: NSToolbar?
    var onImageFileDrop: (([URL], NSPoint) -> Void)?

    init(savedFrame: String?, documentURL: URL? = nil) {
        isDocument = documentURL != nil
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.setValue(false, forKey: "developerExtrasEnabled")
        configuration.userContentController.add(bridge, name: "jot")
        configuration.setURLSchemeHandler(resourceHandler, forURLScheme: "jot")

        webView = AttachmentWebView(frame: .zero, configuration: configuration)
        webView.registerForDraggedTypes([.fileURL])
        webView.setValue(false, forKey: "drawsBackground")
        let initialFrame = NSRect(x: 0, y: 0, width: 560, height: 260)
        let panel = ComposerPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        if let documentURL {
            panel.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            panel.title = documentURL.lastPathComponent
            panel.representedURL = documentURL
        } else { panel.title = "Jot" }
        panel.titleVisibility = documentURL == nil ? .hidden : .visible
        panel.titlebarAppearsTransparent = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = documentURL == nil
        panel.level = documentURL == nil ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = documentURL == nil ? [.canJoinAllSpaces, .fullScreenPrimary] : [.fullScreenPrimary]
        panel.minSize = NSSize(width: 360, height: 180)
        let contentView = CaptureBubbleView(frame: initialFrame)
        webView.translatesAutoresizingMaskIntoConstraints = false
        dragView.translatesAutoresizingMaskIntoConstraints = false
        contentView.setAccessibilityElement(false)
        dragView.setAccessibilityElement(false)
        contentView.addSubview(webView)
        contentView.addSubview(dragView)
        editorTop = webView.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            editorTop,
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dragView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: WindowDragContainerView.trafficLightClearance),
            dragView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dragView.topAnchor.constraint(equalTo: contentView.topAnchor),
            dragView.heightAnchor.constraint(equalToConstant: WindowDragContainerView.dragHeight),
        ])
        panel.contentView = contentView
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = documentURL == nil
        panel.registerForDraggedTypes([.fileURL])

        super.init(window: panel)
        panel.delegate = self
        let toolbar = NSToolbar(identifier: "JotTitlebar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        panel.toolbarStyle = .unifiedCompact
        panel.toolbar = toolbar
        nativeToolbar = toolbar
        if !isDocument {
            popOutButton.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Pop Out Note")
            popOutButton.bezelStyle = .inline
            popOutButton.isBordered = false
            popOutButton.toolTip = "Pop Out Note into a Mac window"
            popOutButton.setAccessibilityLabel("Pop Out Note")
            popOutButton.target = self
            popOutButton.action = #selector(popOut)
            popOutButton.translatesAutoresizingMaskIntoConstraints = false
            popOutButton.isHidden = true
            contentView.addSubview(popOutButton)
            NSLayoutConstraint.activate([
                popOutButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                popOutButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
                popOutButton.widthAnchor.constraint(equalToConstant: 28),
                popOutButton.heightAnchor.constraint(equalToConstant: 28),
            ])
        }
        bridge.webView = webView
        webView.navigationDelegate = bridge
        webView.onImagePaste = { [weak self] in self?.send(["version": 1, "type": "beginImagePaste"]) }
        webView.onImageFileDrop = { [weak self] files, point in self?.onImageFileDrop?(files, point) }
        panel.onImageFileDrop = { [weak self] files, location in
            guard let self else { return }
            let point = self.webView.convert(location, from: nil)
            self.onImageFileDrop?(files, NSPoint(x: point.x, y: self.webView.isFlipped ? point.y : self.webView.bounds.height - point.y))
        }
        if let savedFrame {
            let frame = NSRectFromString(savedFrame)
            if frame.width > 0, frame.height > 0 {
                panel.setFrame(frame, display: false)
                userPlacedPanel = true
                detachedFrame = frame
            }
        }
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuIsTracking = true }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuIsTracking = false }
            },
        ]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.menuIsTracking, let panel = self.window,
                  panel.isVisible, panel.isKeyWindow else { return event }
            // Handle this before WebKit's editor interprets Command-F as Find.
            if (self.keyboardBindings?[ShortcutAction.fullScreen.rawValue] ?? ShortcutAction.fullScreen.defaultChord).matches(event) {
                if self.isAnchored { self.popOut() }
                panel.toggleFullScreen(nil)
                return nil
            }
            guard event.keyCode == 53 else { return event }
            self.handleEscape()
            return nil
        }
    }

    isolated deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func loadEditor() {
        applyFormattingToolbarBounds(nil)
        webView.load(URLRequest(url: URL(string: "jot://local/index.html")!))
    }

    func applyFormattingToolbarBounds(_ bounds: CGRect?) {
        let rect = bounds.map { bounds in
            NSRect(x: bounds.minX, y: webView.isFlipped ? bounds.minY : webView.bounds.height - bounds.maxY,
                   width: bounds.width, height: bounds.height)
        }
        dragView.formattingToolbarRect = rect.map { dragView.convert($0, from: webView) }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window?.standardWindowButton($0) }
        let overlaps = rect.map { rect in
            buttons.contains { rect.intersects($0.convert($0.bounds, to: webView)) }
        } ?? false
        for button in buttons { button.isHidden = overlaps }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    func showQuickCapture() {
        guard !isDocument, let panel = window, !isFullScreenTransition else { return }
        if panel.styleMask.contains(.fullScreen) { showAndFocus(); return }
        if !isAnchored && hasShown { detachedFrame = panel.frame }
        isProgrammaticFrameChange = true
        isAnchored = true
        frameBeforeActions = nil
        panel.toolbar = nil
        panel.styleMask = [.borderless]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        (panel as? NSPanel)?.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        (panel.contentView as? CaptureBubbleView)?.anchored = true
        editorTop.constant = 12
        dragView.isHidden = true
        popOutButton.isHidden = false
        userHasResized = false
        positionCapture()
        isProgrammaticFrameChange = false
        let animate = !panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        showAndFocus()
        if animate {
            let final = panel.frame
            panel.setFrame(final.insetBy(dx: 8, dy: 4).offsetBy(dx: 0, dy: 4), display: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(final, display: true)
            }
        }
    }

    private func positionCapture() {
        guard let panel = window, let anchor = captureAnchor?(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) else { return }
        let frame = Self.anchoredFrame(size: NSSize(width: 560, height: panel.frame.height), anchor: anchor, visibleFrame: screen.visibleFrame)
        panel.setFrame(frame, display: true)
        (panel.contentView as? CaptureBubbleView)?.pointerX = anchor.midX - frame.minX
    }

    static func anchoredFrame(size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let proposed = NSRect(x: anchor.midX - size.width / 2, y: min(anchor.minY, visibleFrame.maxY) - size.height,
                              width: size.width, height: size.height)
        return clampedFrame(proposed, to: visibleFrame.insetBy(dx: 8, dy: 0))
    }

    @objc func popOut() {
        guard isAnchored, let panel = window else { return }
        isProgrammaticFrameChange = true
        isAnchored = false
        frameBeforeActions = nil
        panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = false
        panel.title = "Jot"
        panel.toolbar = nativeToolbar
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        (panel as? NSPanel)?.isFloatingPanel = false
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenPrimary]
        panel.isExcludedFromWindowsMenu = false
        (panel.contentView as? CaptureBubbleView)?.anchored = false
        editorTop.constant = 0
        popOutButton.isHidden = true
        // The system title bar owns window dragging in the detached presentation.
        dragView.isHidden = true
        if let detachedFrame { panel.setFrame(detachedFrame, display: true) }
        else { panel.center() }
        userPlacedPanel = true
        userHasResized = true
        isProgrammaticFrameChange = false
        showAndFocus()
        panel.makeMain()
    }

    func showAndFocus() {
        guard let panel = window else { return }
        isProgrammaticFrameChange = true
        if isAnchored {
            positionCapture()
        } else if panel.styleMask.contains(.fullScreen) || isFullScreenTransition {
            // AppKit owns the frame while the window occupies its full screen space.
        } else if userPlacedPanel {
            restoreVisiblePosition(panel)
        } else if let visibleFrame = activeVisibleFrame() {
            panel.setFrame(Self.centeredFrame(panel.frame, in: visibleFrame), display: true)
        }
        panel.orderFrontRegardless()
        isProgrammaticFrameChange = false
        hasShown = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        if isDocument { panel.makeMain() }
        webView.focusRingType = .none
        webView.evaluateJavaScript("document.querySelector('.cm-content')?.focus()")
    }

    func handleEscape() {
        guard !isFullScreenTransition, let panel = window else { return }
        if panel.styleMask.contains(.fullScreen) {
            panel.toggleFullScreen(nil)
        } else {
            onEscape?()
        }
    }

    func hide() {
        guard !isFullScreenTransition, let panel = window else { return }
        // Hiding a full screen window leaves its Space empty. Exit it instead,
        // including when a hide request was already queued by the editor.
        if panel.styleMask.contains(.fullScreen) {
            panel.toggleFullScreen(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    func applyActionPanelVisibility(_ visible: Bool) {
        guard let panel = window, visible != actionPanelVisible else { return }
        actionPanelVisible = visible
        // Zen dismisses the palette on entry; AppKit owns the full-screen frame.
        guard !isFullScreenTransition, !panel.styleMask.contains(.fullScreen) else {
            frameBeforeActions = nil
            return
        }
        isProgrammaticFrameChange = true
        defer { isProgrammaticFrameChange = false }
        if visible, panel.frame.height < 430 {
            frameBeforeActions = panel.frame
            var frame = panel.frame
            frame.origin.y = frame.maxY - 430
            frame.size.height = 430
            if let screen = panel.screen { frame = Self.clampedFrame(frame, to: screen.visibleFrame) }
            panel.setFrame(frame, display: true)
        } else if !visible, let frame = frameBeforeActions {
            panel.setFrame(frame, display: true)
            frameBeforeActions = nil
        }
    }

    func lockAndSnapshot() async throws -> EditorSnapshot {
        guard let value = try await webView.evaluateJavaScript("window.JotNative?.lockAndSnapshot()") as? [String: Any],
              let text = value["text"] as? String, let revision = value["revision"] as? Int,
              let selection = value["selection"] as? [String: Int], let anchor = selection["anchor"], let head = selection["head"],
              let viewport = value["viewport"] as? [String: Double], let top = viewport["scrollTop"] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return EditorSnapshot(revision: revision, text: text, selection: EditorSelection(anchor: anchor, head: head), viewport: EditorViewport(scrollTop: top))
    }

    func unlockEditor(restoringFocus: Bool) {
        send(["version": 1, "type": "setEditingEnabled", "enabled": true])
        if restoringFocus { webView.evaluateJavaScript("document.querySelector('.cm-content')?.focus()") }
    }

    private(set) var zenFocus = "paragraph"

    func setZenFocus(_ focus: String) {
        guard ["sentence", "paragraph"].contains(focus) else { return }
        zenFocus = focus
        syncZenMode()
    }

    private func syncZenMode() {
        bridge.send(["version": 1, "type": "zenMode",
                     "mode": window?.styleMask.contains(.fullScreen) == true ? zenFocus : "off"])
    }

    var keyboardBindings: [String: KeyChord]? {
        didSet { sendKeyboardBindings() }
    }

    private func sendKeyboardBindings() {
        guard let keyboardBindings else { return }
        bridge.send(["version": 1, "type": "keyboardShortcuts",
                     "labels": keyboardBindings.mapValues { $0.displayName }])
    }

    func send(_ payload: [String: Any]) {
        if payload["type"] as? String == "loadSession" { sendKeyboardBindings() }
        var payload = payload
        if payload["type"] as? String == "escape", payload["dismissOnly"] == nil {
            payload["dismissOnly"] = keyboardBindings?[ShortcutAction.hideJot.rawValue] != nil
                && keyboardBindings?[ShortcutAction.hideJot.rawValue] != ShortcutAction.hideJot.defaultChord
        }
        bridge.send(payload)
        // Also restore presentation after a WebKit process reload/session load.
        if payload["type"] as? String == "loadSession" { syncZenMode() }
    }

    func configureAttachmentRoot(_ root: URL?, documentImages: Bool = false) { resourceHandler.configureAttachmentRoot(root, documentImages: documentImages) }

    func previewImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Image Preview"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 300, height: 240)
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.setAccessibilityLabel("Attached image")
        panel.contentView = imageView
        panel.center()
        imagePreview?.close()
        imagePreview = NSWindowController(window: panel)
        imagePreview?.showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    func applyPreferredContentHeight(_ requestedHeight: CGFloat) {
        guard !isDocument, !actionPanelVisible, !preservesFrameForImages, !userHasResized,
              !isFullScreenTransition, let panel = window,
              !panel.styleMask.contains(.fullScreen) else { return }
        let contentHeight = min(max(requestedHeight + (isAnchored ? 12 : 0), isAnchored ? 260 : 180), 700)
        let frameHeight = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: panel.contentLayoutRect.width, height: contentHeight)).height
        guard abs(panel.frame.height - frameHeight) > 1 else { return }
        var frame = panel.frame
        frame.size.height = frameHeight
        if isAnchored || userPlacedPanel {
            frame.origin.y = panel.frame.maxY - frameHeight
        } else if let visibleFrame = activeVisibleFrame() {
            frame = Self.centeredFrame(frame, in: visibleFrame)
        }
        isProgrammaticFrameChange = true
        panel.setFrame(frame, display: true, animate: false)
        if isAnchored { positionCapture() }
        else if userPlacedPanel { restoreVisiblePosition(panel) }
        isProgrammaticFrameChange = false
    }

    func windowDidBecomeKey(_ notification: Notification) { onBecomeKey?() }

    func windowShouldClose(_ sender: NSWindow) -> Bool { onCloseRequested?() ?? true }

    func windowDidResignKey(_ notification: Notification) {
        if isAnchored && !menuIsTracking { hide() }
        panelDelegate?.composerDidResignKey()
    }

    func windowDidMove(_ notification: Notification) {
        guard hasShown, !isAnchored, !isProgrammaticFrameChange, !isFullScreenTransition,
              window?.styleMask.contains(.fullScreen) != true else { return }
        frameBeforeActions = nil
        userPlacedPanel = true
        recordFrame()
    }
    func windowDidResize(_ notification: Notification) {
        guard hasShown, !isAnchored, !isProgrammaticFrameChange, !isFullScreenTransition,
              window?.styleMask.contains(.fullScreen) != true else { return }
        frameBeforeActions = nil
        userHasResized = true
        userPlacedPanel = true
        recordFrame()
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreenTransition = true
        window?.level = .normal
        window?.titleVisibility = .hidden
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreenTransition = false
        syncZenMode()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isFullScreenTransition = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreenTransition = false
        syncZenMode()
        window?.level = (window as? NSPanel)?.isFloatingPanel == true ? .floating : .normal
        window?.titleVisibility = isDocument || (window as? NSPanel)?.isFloatingPanel == false ? .visible : .hidden
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isFullScreenTransition = false
        syncZenMode()
        window.level = (window as? NSPanel)?.isFloatingPanel == true ? .floating : .normal
        window.titleVisibility = isDocument || (window as? NSPanel)?.isFloatingPanel == false ? .visible : .hidden
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        isFullScreenTransition = false
        syncZenMode()
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
