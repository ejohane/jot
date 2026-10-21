import XCTest

final class KeyboardRailUITests: XCTestCase {
    @MainActor
    func testLongPressCustomizeAddRemoveReorderAndRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-storage", "local"]
        app.launch()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        let format = app.buttons["rail.action.format"]
        XCTAssertTrue(format.waitForExistence(timeout: 5), app.debugDescription)
        format.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["rail.done"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["rail.remove.format"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Customizing must keep the keyboard visible")
        // Set up through the actual UI: AppStorage retains preferences between test runs.
        if app.buttons["rail.remove.bold"].exists { app.buttons["rail.remove.bold"].tap() }
        if !app.buttons["rail.remove.image"].exists {
            app.buttons["rail.add"].tap()
            let image = app.buttons["Add Add image"]
            XCTAssertTrue(image.waitForExistence(timeout: 3))
            image.tap()
            app.navigationBars.buttons["Done"].tap()
            XCTAssertTrue(app.buttons["rail.remove.image"].waitForExistence(timeout: 3))
        }
        attachScreenshot("Customization")

        app.buttons["rail.remove.image"].tap()
        XCTAssertFalse(app.buttons["rail.action.image"].exists)
        app.buttons["rail.add"].tap()
        let bold = app.buttons["Add Bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 3), app.debugDescription)
        bold.tap()
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["rail.action.bold"].waitForExistence(timeout: 3))
        let first = app.buttons["rail.action.format"]
        let last = app.buttons["rail.action.bold"]
        last.press(forDuration: 0.1, thenDragTo: first)
        XCTAssertLessThan(last.frame.midX, first.frame.midX)
        app.buttons["rail.done"].tap()
        XCTAssertFalse(app.buttons["rail.remove.format"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.buttons["rail.action.bold"].exists)
        attachScreenshot("Customized rail")

        // Relaunch without the preference override to prove Done persisted the order.
        app.terminate()
        app.launchArguments = ["-storage", "local"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        XCTAssertTrue(app.buttons["rail.action.bold"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["rail.action.image"].exists)
        XCTAssertLessThan(app.buttons["rail.action.bold"].frame.midX, app.buttons["rail.action.format"].frame.midX)
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
