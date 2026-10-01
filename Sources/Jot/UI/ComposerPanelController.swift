import AppKit
import WebKit

@MainActor
protocol ComposerPanelDelegate: AnyObject {
    func composerDidResignKey()
    func composerFrameDidChange(_ frame: NSRect)
}

final class ComposerPanel: NSPanel, NSDraggingDestination {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    private var userPlacedPanel = false
    private var hasShown = false
    private var escapeMonitor: Any?
    private var actionPanelVisible = false
    private var frameBeforeActions: NSRect?
    private var imagePreview: NSWindowController?
    var preservesFrameForImages = false
    weak var panelDelegate: (any ComposerPanelDelegate)?
    var onEscape: (() -> Void)?
    var onImageFileDrop: (([URL], NSPoint) -> Void)?

    init(savedFrame: String?) {
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
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Jot"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 180)
        panel.maxSize = NSSize(width: 900, height: 900)
        let contentView = NSView(frame: initialFrame)
        webView.translatesAutoresizingMaskIntoConstraints = false
        dragView.translatesAutoresizingMaskIntoConstraints = false
        contentView.setAccessibilityElement(false)
        dragView.setAccessibilityElement(false)
        contentView.addSubview(webView)
        contentView.addSubview(dragView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dragView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: WindowDragContainerView.trafficLightClearance),
            dragView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dragView.topAnchor.constraint(equalTo: contentView.topAnchor),
            dragView.heightAnchor.constraint(equalToConstant: WindowDragContainerView.dragHeight),
        ])
        panel.contentView = contentView
        panel.isReleasedWhenClosed = false
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

    func applyActionPanelVisibility(_ visible: Bool) {
        guard let panel = window, visible != actionPanelVisible else { return }
        actionPanelVisible = visible
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

    func send(_ payload: [String: Any]) { bridge.send(payload) }

    func configureAttachmentRoot(_ root: URL?) { resourceHandler.configureAttachmentRoot(root) }

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
        guard !actionPanelVisible, !preservesFrameForImages, !userHasResized, let panel = window else { return }
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
        frameBeforeActions = nil
        userPlacedPanel = true
        recordFrame()
    }
    func windowDidResize(_ notification: Notification) {
        guard hasShown, !isProgrammaticFrameChange else { return }
        frameBeforeActions = nil
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
