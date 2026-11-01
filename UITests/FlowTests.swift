import XCTest

/// Drives the real app like a person would, on a simulator with a stand-in camera and a fake Claude.
final class FlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(scan: String = "centered", hasKey: Bool = true, arguments: [String] = []) throws {
        let photo = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "sample", ofType: "jpg"))
        app = XCUIApplication()
        app.launchArguments = (hasKey ? ["-stagedKey"] : []) + arguments
        app.launchEnvironment = ["STAGED_PHOTO": photo, "STAGED_SCAN": scan]
        app.launch()
        XCTAssertTrue(app.buttons["Take photo"].waitForExistence(timeout: 10))
    }

    private func shoot(_ name: String) {
        let directory = URL(fileURLWithPath: "/tmp/shotfinder-screens")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func expectText(_ text: String, timeout: TimeInterval = 5) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: timeout), "Missing text: \(text)")
    }

    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' AND NOT label CONTAINS[c] 'Don'")).firstMatch
            if allow.exists { allow.tap() }
        }
    }

    func testLargeTextLayouts() throws {
        try launch(scan: "off-center", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["Scan for a shot"].tap()
        XCTAssertTrue(app.buttons["Stop guiding"].waitForExistence(timeout: 8))
        sleep(1)
        shoot("large-text-guiding")
        app.buttons["Take photo"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        sleep(3)
        shoot("large-text-develop")
    }

    /// A switch only flips when its own right side is tapped, not the middle of its row.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    func testTopRowAndSettings() throws {
        try launch()
        XCTAssertTrue(app.buttons["Zoom .5x"].exists)
        XCTAssertFalse(app.staticTexts["Tap to find a shot"].exists)
        shoot("e2e-01-idle")

        app.buttons["Flash, Off"].tap()
        XCTAssertTrue(app.buttons["Flash, Auto"].waitForExistence(timeout: 2))
        app.buttons["Flash, Auto"].tap()
        app.buttons["Flash, On"].tap()
        XCTAssertTrue(app.buttons["Flash, Off"].waitForExistence(timeout: 2))

        for ratio in ["4:5", "1:1", "9:16", "3:4"] {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Aspect'")).firstMatch.tap()
            XCTAssertTrue(app.buttons["Aspect, \(ratio)"].waitForExistence(timeout: 2))
            if ratio == "1:1" {
                sleep(1)
                shoot("e2e-03-square")
            }
        }

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        let night = app.switches["Night"]
        XCTAssertTrue(night.waitForExistence(timeout: 2))
        flip(night)
        sleep(1)
        XCTAssertEqual(night.value as? String, "1")
        flip(night)
        let grid = app.switches["Grid"]
        XCTAssertTrue(grid.exists)
        XCTAssertTrue(app.switches["Level"].exists)
        flip(grid)
        sleep(1)
        shoot("e2e-05-settings")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Take photo"].waitForExistence(timeout: 3))
        sleep(1)
        shoot("e2e-06-grid")

        app.buttons["Settings"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 3))
        flip(grid)
        app.buttons["Done"].tap()
    }

    func testTapDragAndHoldOnTheViewfinder() throws {
        try launch()
        let viewfinder = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))

        viewfinder.tap()
        sleep(1)
        shoot("e2e-07-focus")

        viewfinder.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        shoot("e2e-08-brighter")

        viewfinder.press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["AE/AF LOCK"].waitForExistence(timeout: 3))
        shoot("e2e-09-locked")

        viewfinder.tap()
        XCTAssertFalse(app.staticTexts["AE/AF LOCK"].waitForExistence(timeout: 1))
    }

    func testTimerCountsDownThenShoots() throws {
        try launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["3s"].waitForExistence(timeout: 3))
        app.buttons["3s"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Take photo"].waitForExistence(timeout: 3))

        app.buttons["Take photo"].tap()
        shoot("e2e-19-timer")
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 8))

        app.buttons["Delete"].tap()
        app.buttons["Delete Photo"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 4))

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Off"].waitForExistence(timeout: 3))
        app.buttons["Off"].tap()
        app.buttons["Done"].tap()
    }

    func testFullFlowFromScanToSave() throws {
        try launch()

        app.buttons["Scan for a shot"].tap()
        expectText("distant church spires")
        shoot("e2e-10-guided")
        XCTAssertTrue(app.buttons["Scan again"].waitForExistence(timeout: 5))
        shoot("e2e-11-ready")

        app.buttons["Scan again"].tap()
        XCTAssertTrue(app.buttons["Scan again"].waitForExistence(timeout: 8))

        app.buttons["Take photo"].tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForEnabled(save))
        sleep(2)
        shoot("e2e-12-develop-look")

        app.buttons["Lantern"].tap()
        sleep(1)
        shoot("e2e-13-look")

        app.buttons["Grain, No Grain"].tap()
        XCTAssertTrue(app.buttons["Grain, Fine Grain"].waitForExistence(timeout: 2))

        app.buttons["Frame, No Frame"].tap()
        XCTAssertTrue(app.buttons["Frame, Print"].waitForExistence(timeout: 2))
        sleep(1)
        shoot("e2e-17-frames")

        let photo = app.images["Photo with Lantern look"]
        XCTAssertTrue(photo.exists)
        photo.press(forDuration: 1.0)

        save.tap()
        allowPhotosIfAsked()
        XCTAssertTrue(app.buttons["Scan for a shot"].waitForExistence(timeout: 10), "The guide should clear after saving")
        shoot("e2e-18-back-to-camera")
    }

    private func waitForEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
    }

    func testDiscardReturnsToCameraAndStaysGone() throws {
        try launch()
        app.buttons["Take photo"].tap()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(app.buttons["Delete Photo"].waitForExistence(timeout: 3))
        sleep(1)
        shoot("e2e-20-delete-dialog")
        app.buttons["Delete Photo"].tap()
        XCTAssertTrue(app.buttons["Scan for a shot"].waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertFalse(app.buttons["Save"].exists, "A discarded photo came back")
    }

    func testGuideWhileOffCenterAndStop() throws {
        try launch(scan: "off-center")
        app.buttons["Scan for a shot"].tap()
        expectText("Keep the horizon low.")
        sleep(1)
        shoot("e2e-30-off-center")
        XCTAssertFalse(app.buttons["Scan again"].exists)
        app.buttons["Stop guiding"].tap()
        XCTAssertTrue(app.buttons["Scan for a shot"].waitForExistence(timeout: 3))
    }

    func testMissingKeyOpensSettingsWithReason() throws {
        try launch(hasKey: false)
        app.buttons["Scan for a shot"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        sleep(1)
        shoot("e2e-40-settings-no-key")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Add your Claude API key'")).firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Scan for a shot"].waitForExistence(timeout: 3))
    }

    func testEveryScanErrorShowsAPlainMessage() throws {
        let cases = [
            ("offline", "No internet. Scanning needs a connection."),
            ("bad-key", "Claude didn't accept this API key."),
            ("no-credits", "Your Claude API credits have run out."),
            ("busy", "Claude is busy. Try again in a moment."),
            ("refused", "Claude declined to scan this scene."),
            ("garbled", "The scan failed. Try again.")
        ]
        for (scan, message) in cases {
            try launch(scan: scan)
            app.buttons["Scan for a shot"].tap()
            expectText(message)
            shoot("e2e-50-error-\(scan)")
            XCTAssertTrue(app.buttons["Scan for a shot"].exists, "Couldn't scan again after \(scan)")
            app.terminate()
        }
    }
}
