import AppKit
import XCTest
@testable import Jot

final class QuickCaptureWindowTests: XCTestCase {
    @MainActor
    func testCaptureStaysBelowIconAndInsideScreenEdges() {
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 875)
        for x: CGFloat in [-1430, -720, -10] {
            let anchor = NSRect(x: x, y: 875, width: 24, height: 25)
            let frame = ComposerPanelController.anchoredFrame(size: NSSize(width: 560, height: 320), anchor: anchor, visibleFrame: screen)
            XCTAssertEqual(frame.maxY, 875)
            XCTAssertGreaterThanOrEqual(frame.minX, screen.minX + 8)
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - 8)
        }
    }

    @MainActor
    func testPopOutKeepsEditorAndRestoresNativeWindowBehavior() throws {
        let controller = ComposerPanelController(savedFrame: nil)
        let window = try XCTUnwrap(controller.window)
        let content = window.contentView
        controller.captureAnchor = { NSRect(x: 400, y: 900, width: 24, height: 24) }
        controller.showQuickCapture()
        XCTAssertTrue(controller.isAnchored)
        XCTAssertFalse(window.isMovable)
        XCTAssertFalse(window.styleMask.contains(.titled))
        controller.popOut()
        XCTAssertFalse(controller.isAnchored)
        XCTAssertTrue(window.contentView === content)
        XCTAssertTrue(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        XCTAssertEqual(window.level, .normal)
        XCTAssertTrue(window.isMovable)
        XCTAssertFalse((window as! NSPanel).isFloatingPanel)
        window.orderOut(nil)
    }
    @MainActor
    func testFirstPopOutRestoresSavedDetachedFrame() throws {
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let saved = NSRect(x: visible.midX - 280, y: visible.midY - 180, width: 560, height: 360)
        let controller = ComposerPanelController(savedFrame: NSStringFromRect(saved))
        controller.captureAnchor = { NSRect(x: visible.midX, y: visible.maxY, width: 24, height: 24) }
        controller.showQuickCapture()
        controller.popOut()
        XCTAssertEqual(controller.window?.frame, saved)
        controller.window?.orderOut(nil)
    }

}
