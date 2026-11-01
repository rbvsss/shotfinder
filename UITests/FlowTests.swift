import XCTest

/// Drives the real app like a person would, on a simulator with a stand-in camera and a fake Claude.
final class FlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(scan: String = "centered", hasKey: Bool = true) throws {
        let photo = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "sample", ofType: "jpg"))
        app = XCUIApplication()
        app.launchArguments = ["-staged"] + (hasKey ? ["-stagedKey"] : [])
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

    func testIdleAndOptions() throws {
        try launch()
        XCTAssertTrue(app.buttons["Zoom .5x"].exists)
        shoot("e2e-01-idle")

        app.buttons["Options"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 3))
        shoot("e2e-02-menu")

        app.buttons["Aspect Ratio"].tap()
        XCTAssertTrue(app.buttons["1:1"].waitForExistence(timeout: 3))
        shoot("e2e-03-ratios")
        app.buttons["1:1"].tap()
        sleep(1)
        shoot("e2e-04-square")

        app.buttons["Options"].tap()
        app.buttons["Flash"].tap()
        XCTAssertTrue(app.buttons["On"].waitForExistence(timeout: 3))
        app.buttons["On"].tap()
        XCTAssertTrue(app.images["Flash on"].waitForExistence(timeout: 3) || app.otherElements["Flash on"].exists)
        shoot("e2e-05-flash-on")
    }

    func testFullFlowFromScanToSave() throws {
        try launch()

        app.buttons["Scan for a shot"].tap()
        expectText("Distant church spires")
        shoot("e2e-10-guided")
        expectText("Ready", timeout: 5)
        XCTAssertTrue(app.buttons["Scan again"].exists)
        shoot("e2e-11-ready")

        app.buttons["Scan again"].tap()
        expectText("Ready", timeout: 8)

        app.buttons["Take photo"].tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(NSPredicate(format: "isEnabled == true").evaluate(with: save) || waitForEnabled(save))
        sleep(2)
        shoot("e2e-12-develop-look")

        app.buttons["Cinder"].tap()
        sleep(1)
        shoot("e2e-13-cinder")

        app.buttons["Grain"].tap()
        app.sliders["Grain"].adjust(toNormalizedSliderPosition: 0.5)
        sleep(1)
        shoot("e2e-14-grain")

        app.buttons["Frame"].tap()
        app.buttons["Mat"].tap()
        sleep(1)
        shoot("e2e-15-frame")

        save.tap()
        allowPhotosIfAsked()
        XCTAssertTrue(app.buttons["Scan again"].waitForExistence(timeout: 10) || app.buttons["Stop guiding"].exists)
        shoot("e2e-16-back-to-camera")
    }

    private func waitForEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
    }

    func testDiscardReturnsToCameraAndStaysGone() throws {
        try launch()
        app.buttons["Take photo"].tap()
        let discard = app.buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        sleep(1)
        shoot("e2e-20-discard-dialog")
        let buttons = app.buttons.matching(identifier: "Discard").allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(buttons.count, 2)
        buttons.last?.tap()
        XCTAssertTrue(app.buttons["Scan for a shot"].waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertFalse(app.buttons["Save"].exists, "A discarded photo came back")
    }

    func testGuideWhileOffCenterAndStop() throws {
        try launch(scan: "off-center")
        app.buttons["Scan for a shot"].tap()
        expectText("Keep the horizon low")
        sleep(1)
        shoot("e2e-30-off-center")
        XCTAssertFalse(app.staticTexts["Ready"].exists)
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
        XCTAssertTrue(app.switches["Save RAW"].exists)
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
