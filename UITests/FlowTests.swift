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

    /// A tap away from a popover closes it.
    private func closeMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        sleep(1)
    }

    /// A switch only flips when its own right side is tapped, not the middle of its row.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    func testTopBarAndItsMenus() throws {
        try launch()
        XCTAssertTrue(app.buttons["Zoom .5x"].exists)
        XCTAssertFalse(app.buttons["Options"].exists, "The old menu should be gone")
        shoot("e2e-01-idle")

        app.buttons["Flash, Off"].tap()
        XCTAssertTrue(app.buttons["Flash, Auto"].waitForExistence(timeout: 2))
        app.buttons["Flash, Auto"].tap()
        app.buttons["Flash, On"].tap()
        XCTAssertTrue(app.buttons["Flash, Off"].waitForExistence(timeout: 2))

        app.buttons["Aspect, 3:4"].tap()
        XCTAssertTrue(app.buttons["1:1"].waitForExistence(timeout: 2))
        sleep(1)
        shoot("e2e-02-ratio-menu")
        app.buttons["1:1"].tap()
        XCTAssertTrue(app.buttons["Aspect, 1:1"].waitForExistence(timeout: 2))
        sleep(1)
        shoot("e2e-03-square")
        app.buttons["Aspect, 1:1"].tap()
        XCTAssertTrue(app.buttons["3:4"].waitForExistence(timeout: 2))
        app.buttons["3:4"].tap()
        XCTAssertTrue(app.buttons["Aspect, 3:4"].waitForExistence(timeout: 2))

        app.buttons["Camera options"].tap()
        let night = app.switches["Night"]
        XCTAssertTrue(night.waitForExistence(timeout: 2))
        XCTAssertTrue(app.sliders["Exposure"].exists)
        flip(night)
        sleep(1)
        XCTAssertEqual(night.value as? String, "1")
        shoot("e2e-04-camera-menu")
        flip(night)
        closeMenu()

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        shoot("e2e-05-settings")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Take photo"].waitForExistence(timeout: 3))
    }

    func testTimerCountsDownThenShoots() throws {
        try launch()
        app.buttons["Camera options"].tap()
        XCTAssertTrue(app.buttons["3s"].waitForExistence(timeout: 2))
        app.buttons["3s"].tap()
        closeMenu()

        app.buttons["Take photo"].tap()
        shoot("e2e-06-timer")
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 8))
    }

    func testScanningShowsWhatItIsDoing() throws {
        try launch(scan: "slow")
        app.buttons["Scan for a shot"].tap()
        expectText("Finding your shot…")
        shoot("e2e-09-scanning")
    }

    func testFullFlowFromScanToSave() throws {
        try launch()

        app.buttons["Scan for a shot"].tap()
        expectText("distant church spires")
        shoot("e2e-10-guided")
        XCTAssertTrue(app.buttons["Scan again"].waitForExistence(timeout: 5))
        sleep(1)
        shoot("e2e-11-ready")

        app.buttons["Scan again"].tap()
        XCTAssertTrue(app.buttons["Scan again"].waitForExistence(timeout: 8))

        app.buttons["Take photo"].tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForEnabled(save))
        sleep(2)
        shoot("e2e-12-develop-look")

        app.buttons["Cinder"].tap()
        sleep(1)
        shoot("e2e-13-cinder")

        app.buttons["Adjust"].tap()
        app.buttons["Vignette"].tap()
        app.sliders["Vignette"].adjust(toNormalizedSliderPosition: 0.8)
        shoot("e2e-13b-adjust")

        app.buttons["Finish"].tap()
        app.buttons["Grain, No Grain"].tap()
        XCTAssertTrue(app.buttons["Grain, Fine Grain"].waitForExistence(timeout: 3))
        sleep(1)
        shoot("e2e-14-grain")

        app.buttons["Frame, No Frame"].tap()
        app.buttons["Frame, Border"].tap()
        XCTAssertTrue(app.buttons["Frame, Mat"].waitForExistence(timeout: 3))
        sleep(1)
        shoot("e2e-15-frame")

        let photo = app.images["Photo with Cinder look"]
        XCTAssertTrue(photo.exists)
        photo.press(forDuration: 1.0)

        save.tap()
        allowPhotosIfAsked()
        XCTAssertTrue(app.buttons["Scan for a shot"].waitForExistence(timeout: 10), "The guide should clear after saving")
        shoot("e2e-16-back-to-camera")
    }

    private func waitForEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
    }

    func testDiscardReturnsToCameraAndStaysGone() throws {
        try launch()
        app.buttons["Take photo"].tap()
        let retake = app.buttons["Retake"]
        XCTAssertTrue(retake.waitForExistence(timeout: 5))
        retake.tap()
        XCTAssertTrue(app.buttons["Discard Photo"].waitForExistence(timeout: 3))
        sleep(1)
        shoot("e2e-20-discard-dialog")
        app.buttons["Discard Photo"].tap()
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
