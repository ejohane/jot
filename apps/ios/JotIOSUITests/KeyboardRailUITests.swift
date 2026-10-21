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
        for identifier in ["italic", "strikethrough", "code"] {
            let remove = app.buttons["rail.remove.\(identifier)"]
            if remove.exists { remove.tap() }
        }
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
    func testEqualSlotsAndFourActionScrolling() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-storage", "local"]
        app.launch()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        app.buttons["rail.action.format"].press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["rail.done"].waitForExistence(timeout: 3))
        let removable = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'rail.remove.' AND identifier != 'rail.remove.format'"))
        while removable.firstMatch.exists { removable.firstMatch.tap() }
        app.buttons["rail.add"].tap()
        for title in ["Checklist", "Bold", "Italic", "Strikethrough", "Monospace"] {
            let action = app.buttons["Add \(title)"]
            if !action.isHittable { app.swipeUp() }
            action.tap()
        }
        app.navigationBars.buttons["Done"].tap()
        app.buttons["rail.done"].tap()

        let rail = app.collectionViews["keyboardRail"]
        let dismiss = app.buttons["rail.dismissKeyboard"]
        let slotWidth = dismiss.frame.width
        XCTAssertEqual(rail.frame.width, slotWidth * 4, accuracy: 1)
        let identifiers = ["format", "checklist", "bold", "italic"]
        for (index, identifier) in identifiers.enumerated() {
            let action = app.buttons["rail.action.\(identifier)"]
            XCTAssertEqual(action.frame.width, slotWidth, accuracy: 1)
            XCTAssertEqual(action.frame.midX, rail.frame.minX + slotWidth * (CGFloat(index) + 0.5), accuracy: 1)
        }
        XCTAssertEqual(dismiss.frame.midX - app.buttons["rail.action.italic"].frame.midX, slotWidth, accuracy: 1)
        attachScreenshot("Four evenly spaced actions and fixed keyboard dismissal")

        let dismissFrame = dismiss.frame
        rail.swipeLeft()
        let monospace = app.buttons["rail.action.code"]
        XCTAssertTrue(monospace.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(monospace.frame.minX, rail.frame.minX - 1)
        XCTAssertLessThanOrEqual(monospace.frame.maxX, rail.frame.maxX + 1)
        XCTAssertEqual(dismiss.frame, dismissFrame)
        attachScreenshot("Extra actions scroll while keyboard dismissal stays fixed")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
